import Darwin
import Foundation
import LocalAuthentication
import os
import RxCocoa
import Security
//
//  UserDefaultsRelay.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/8.
//
import RxSwift

enum CredentialStore {
    // Use a fresh namespace so the first stable Developer ID build cannot be
    // blocked by ACLs created by earlier ad-hoc development builds.
    private static let service = "dev.innei.ProcessReporter.credentials.v2"
    private static let legacyService = "dev.innei.ProcessReporter.credentials"
    private static let queue = DispatchQueue(
        label: "dev.innei.ProcessReporter.credential-store",
        qos: .userInitiated
    )
    private static let keychainBackedAccounts = OSAllocatedUnfairLock(
        initialState: Set<String>()
    )
    private static let pendingRecoveryUnavailable = OSAllocatedUnfairLock(
        initialState: false
    )
    private static let legacyCredentialStatesKey = "credentialStates.v1"
    private static let journalFileName = "credential-journal.v1.json"
    private static let fallbackBundleIdentifier = "dev.innei.ProcessReporterV2"
    private static let maximumJournalSize = 16 * 1024 * 1024
    private static let legacyDispositionPrefix = "credentialMigration.v2."

    /// Generic-password ACLs rely on a stable signing requirement. Ad-hoc
    /// signatures have no team identifier and change identity on every build,
    /// so those distributions retain credentials in the protected local journal
    /// until a Developer ID build can migrate them safely.
    static let usesKeychainStorage: Bool = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            return false
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode
        else {
            return false
        }

        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        ) == errSecSuccess,
            let information = signingInformation as? [String: Any],
            let teamIdentifier = information[kSecCodeInfoTeamIdentifier as String] as? String
        else {
            return false
        }
        return !teamIdentifier.isEmpty
    }()

    private static let didDisableLegacyKeychainUI: Bool = {
        // kSecUseAuthenticationContext does not suppress the legacy macOS
        // keychain ACL dialog. Disable process-level interaction so a stale ACL
        // fails promptly instead of blocking the credential queue indefinitely.
        let status = SecKeychainSetUserInteractionAllowed(false)
        if status != errSecSuccess {
            NSLog("Could not disable legacy Keychain interaction (status %d)", status)
        }
        return status == errSecSuccess
    }()

    private struct CredentialState: Codable, Equatable, Sendable {
        enum Storage: String, Codable, Sendable {
            case keychain
            case local
            case cleared
        }

        let storage: Storage
        let localValue: String?
        /// An older or inaccessible Keychain item may remain in addition to the
        /// authority represented by `storage`. Older journal schemas did not
        /// record this provenance, so local/cleared states decode conservatively.
        let mayRetainKeychainCopy: Bool

        private enum CodingKeys: String, CodingKey {
            case storage
            case localValue
            case mayRetainKeychainCopy
        }

        init(
            storage: Storage,
            localValue: String?,
            mayRetainKeychainCopy: Bool
        ) {
            self.storage = storage
            self.localValue = localValue
            self.mayRetainKeychainCopy = mayRetainKeychainCopy
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            storage = try container.decode(Storage.self, forKey: .storage)
            localValue = try container.decodeIfPresent(String.self, forKey: .localValue)
            mayRetainKeychainCopy = try container.decodeIfPresent(
                Bool.self,
                forKey: .mayRetainKeychainCopy
            ) ?? (storage != .keychain)
        }

        static let keychain = CredentialState(
            storage: .keychain,
            localValue: nil,
            mayRetainKeychainCopy: false
        )
        static let cleared = CredentialState(
            storage: .cleared,
            localValue: nil,
            mayRetainKeychainCopy: false
        )

        static func keychainState(retainingCopy: Bool) -> CredentialState {
            CredentialState(
                storage: .keychain,
                localValue: nil,
                mayRetainKeychainCopy: retainingCopy
            )
        }

        static func clearedState(retainingCopy: Bool) -> CredentialState {
            CredentialState(
                storage: .cleared,
                localValue: nil,
                mayRetainKeychainCopy: retainingCopy
            )
        }

        static func local(
            _ value: String,
            retainingCopy: Bool = false
        ) -> CredentialState {
            CredentialState(
                storage: .local,
                localValue: value,
                mayRetainKeychainCopy: retainingCopy
            )
        }

        var couldHaveKeychainCopy: Bool {
            storage == .keychain || mayRetainKeychainCopy
        }
    }

    private struct CredentialJournal: Codable, Equatable, Sendable {
        var states: [String: CredentialState]
        var pendingPreferences: [String: String]

        static let empty = CredentialJournal(
            states: [:],
            pendingPreferences: [:]
        )
    }

    struct Change: Sendable {
        let account: String
        let previousValue: String
        let newValue: String
    }

    struct PendingPreference: Sendable {
        let key: String
        let value: String
    }

    struct ApplyResult: Sendable {
        let succeeded: Bool
        let usedLocalFallback: Bool
        let retainedClearedKeychainValue: Bool

        static let persisted = ApplyResult(
            succeeded: true,
            usedLocalFallback: false,
            retainedClearedKeychainValue: false
        )
        static let failed = ApplyResult(
            succeeded: false,
            usedLocalFallback: false,
            retainedClearedKeychainValue: false
        )
    }

    enum JournalRecoveryResult: Sendable {
        case recovered(backupFileName: String)
        case notRequired
        case failed
    }

    struct Resolution: Sendable {
        /// The value that should be exposed to the running application.
        let runtimeValue: String
        /// Managed credential fields are redacted after the protected authority
        /// is readable. A legacy value is preserved only when journal I/O fails,
        /// preventing a transient migration failure from becoming data loss.
        let persistedValue: String
        /// A legacy item exists or may exist but could not be read without
        /// interactive Keychain access.
        let requiresUserAttention: Bool
        /// The protected journal itself could not be inspected. Callers must
        /// pause reporting and offer an explicit, backup-preserving recovery path.
        let journalUnavailable: Bool

        init(
            runtimeValue: String,
            persistedValue: String,
            requiresUserAttention: Bool,
            journalUnavailable: Bool = false
        ) {
            self.runtimeValue = runtimeValue
            self.persistedValue = persistedValue
            self.requiresUserAttention = requiresUserAttention
            self.journalUnavailable = journalUnavailable
        }
    }

    private enum Lookup {
        case value(String)
        case missing
        case failure(OSStatus)
    }

    private struct JournalFileIdentity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t

        init(_ status: stat) {
            device = status.st_dev
            inode = status.st_ino
        }
    }

    private struct CredentialJournalAssessment: Sendable {
        let journal: CredentialJournal?
        /// Identity of the exact protected file used to produce this assessment.
        /// A nil value means the assessment came from a missing/legacy source.
        let fileIdentity: JournalFileIdentity?
    }

    private enum JournalReadResult {
        case value(CredentialJournal, identity: JournalFileIdentity)
        case missing
        case failure(identity: JournalFileIdentity?)
    }

    private static func isKnownKeychainBacked(_ account: String) -> Bool {
        guard usesKeychainStorage else { return false }
        return keychainBackedAccounts.withLock { $0.contains(account) }
    }

    private static func setKeychainBacked(_ isBacked: Bool, for account: String) {
        keychainBackedAccounts.withLock { accounts in
            if isBacked {
                accounts.insert(account)
            } else {
                accounts.remove(account)
            }
        }
    }

    private static func sanitizedPendingPreferenceValue(
        _ value: String,
        forKey key: String
    ) -> String? {
        let credentialFields: [String]
        switch key {
        case "mixSpaceIntegration", "slackIntegration":
            credentialFields = ["apiToken"]
        case "s3Integration":
            credentialFields = ["accessKey", "secretKey"]
        default:
            return value
        }

        guard let data = value.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        for field in credentialFields {
            object[field] = ""
        }
        guard JSONSerialization.isValidJSONObject(object),
              let sanitizedData = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.sortedKeys]
              )
        else {
            return nil
        }
        return String(data: sanitizedData, encoding: .utf8)
    }

    private static func sanitizingPendingPreferences(
        in journal: CredentialJournal
    ) -> CredentialJournal? {
        var sanitized = journal
        for (key, value) in journal.pendingPreferences {
            guard let safeValue = sanitizedPendingPreferenceValue(value, forKey: key) else {
                NSLog("Invalid pending preference payload for key %@", key)
                return nil
            }
            sanitized.pendingPreferences[key] = safeValue
        }
        return sanitized
    }

    private static func logPOSIXFailure(_ operation: String, code: Int32) {
        NSLog(
            "%@ failed (%d: %@)",
            operation,
            code,
            String(cString: strerror(code))
        )
    }

    /// Opens the bundle-specific Application Support directory after creating it
    /// with owner-only permissions. The parent directory is synchronized so the
    /// first journal write cannot outlive an uncommitted directory entry.
    private static func openJournalDirectory() -> Int32? {
        let fileManager = FileManager.default
        guard let applicationSupportURL = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            NSLog("Could not locate Application Support for credential journal")
            return nil
        }

        let parentDescriptor = applicationSupportURL.withUnsafeFileSystemRepresentation {
            path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard parentDescriptor >= 0 else {
            logPOSIXFailure("Opening Application Support", code: errno)
            return nil
        }
        defer { _ = close(parentDescriptor) }

        let directoryName = Bundle.main.bundleIdentifier ?? fallbackBundleIdentifier
        guard !directoryName.isEmpty,
              directoryName != ".",
              directoryName != "..",
              !directoryName.contains("/")
        else {
            NSLog("Invalid bundle identifier for credential journal directory")
            return nil
        }

        let creationStatus = directoryName.withCString {
            mkdirat(parentDescriptor, $0, mode_t(0o700))
        }
        if creationStatus != 0, errno != EEXIST {
            logPOSIXFailure("Creating credential journal directory", code: errno)
            return nil
        }

        let directoryDescriptor = directoryName.withCString {
            openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard directoryDescriptor >= 0 else {
            logPOSIXFailure("Opening credential journal directory", code: errno)
            return nil
        }

        var directoryStatus = stat()
        guard fstat(directoryDescriptor, &directoryStatus) == 0,
              (directoryStatus.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              directoryStatus.st_uid == geteuid()
        else {
            let code = errno
            _ = close(directoryDescriptor)
            logPOSIXFailure("Validating credential journal directory", code: code)
            return nil
        }
        guard fchmod(directoryDescriptor, mode_t(0o700)) == 0 else {
            let code = errno
            _ = close(directoryDescriptor)
            logPOSIXFailure("Securing credential journal directory", code: code)
            return nil
        }
        guard fsync(parentDescriptor) == 0 else {
            let code = errno
            _ = close(directoryDescriptor)
            logPOSIXFailure("Synchronizing Application Support", code: code)
            return nil
        }
        return directoryDescriptor
    }

    private static func readData(from descriptor: Int32, count: Int) -> Data? {
        var data = Data(count: count)
        let didReadAll = data.withUnsafeMutableBytes { buffer -> Bool in
            guard count > 0, let baseAddress = buffer.baseAddress else { return count == 0 }
            var offset = 0
            while offset < count {
                let result = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    count - offset
                )
                if result > 0 {
                    offset += result
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    if result < 0 {
                        logPOSIXFailure("Reading credential journal", code: errno)
                    } else {
                        NSLog("Credential journal ended before its recorded size")
                    }
                    return false
                }
            }
            return true
        }
        return didReadAll ? data : nil
    }

    private static func readCredentialJournalFile() -> JournalReadResult {
        guard let directoryDescriptor = openJournalDirectory() else {
            return .failure(identity: nil)
        }
        defer { _ = close(directoryDescriptor) }

        let fileDescriptor = journalFileName.withCString {
            openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard fileDescriptor >= 0 else {
            let code = errno
            if code == ENOENT { return .missing }
            logPOSIXFailure("Opening credential journal", code: code)
            var pathStatus = stat()
            let identity = journalFileName.withCString {
                fstatat(
                    directoryDescriptor,
                    $0,
                    &pathStatus,
                    AT_SYMLINK_NOFOLLOW
                ) == 0 ? JournalFileIdentity(pathStatus) : nil
            }
            return .failure(identity: identity)
        }
        defer { _ = close(fileDescriptor) }

        var fileStatus = stat()
        guard fstat(fileDescriptor, &fileStatus) == 0 else {
            logPOSIXFailure("Inspecting credential journal", code: errno)
            return .failure(identity: nil)
        }
        let identity = JournalFileIdentity(fileStatus)
        guard (fileStatus.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              fileStatus.st_uid == geteuid(),
              fileStatus.st_size >= 0,
              fileStatus.st_size <= maximumJournalSize
        else {
            logPOSIXFailure("Validating credential journal", code: errno)
            return .failure(identity: identity)
        }
        guard fchmod(fileDescriptor, mode_t(0o600)) == 0 else {
            logPOSIXFailure("Securing credential journal", code: errno)
            return .failure(identity: identity)
        }
        guard let data = readData(from: fileDescriptor, count: Int(fileStatus.st_size)),
              let journal = try? JSONDecoder().decode(CredentialJournal.self, from: data)
        else {
            NSLog("Credential journal could not be decoded")
            return .failure(identity: identity)
        }
        return .value(journal, identity: identity)
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress else { return buffer.isEmpty }
            var offset = 0
            while offset < buffer.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if result > 0 {
                    offset += result
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    logPOSIXFailure("Writing credential journal", code: errno)
                    return false
                }
            }
            return true
        }
    }

    private static func persistBackupData(
        _ data: Data,
        named fileName: String,
        in directoryDescriptor: Int32
    ) -> Bool {
        var descriptor = fileName.withCString {
            openat(
                directoryDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            logPOSIXFailure("Creating credential journal backup", code: errno)
            return false
        }

        var shouldRemoveBackup = true
        defer {
            if descriptor >= 0 {
                _ = close(descriptor)
            }
            if shouldRemoveBackup {
                fileName.withCString {
                    _ = unlinkat(directoryDescriptor, $0, 0)
                }
                _ = fsync(directoryDescriptor)
            }
        }

        guard fchmod(descriptor, mode_t(0o600)) == 0,
              writeAll(data, to: descriptor),
              fsync(descriptor) == 0
        else {
            logPOSIXFailure("Writing credential journal backup", code: errno)
            return false
        }
        guard close(descriptor) == 0 else {
            descriptor = -1
            logPOSIXFailure("Closing credential journal backup", code: errno)
            return false
        }
        descriptor = -1
        guard fsync(directoryDescriptor) == 0 else {
            logPOSIXFailure("Synchronizing credential journal backup", code: errno)
            return false
        }
        shouldRemoveBackup = false
        return true
    }

    private static func legacyJournalBackupData(from object: Any) -> Data? {
        if let data = object as? Data {
            return data
        }
        guard PropertyListSerialization.propertyList(
            object,
            isValidFor: .binary
        ) else {
            return nil
        }
        return try? PropertyListSerialization.data(
            fromPropertyList: object,
            format: .binary,
            options: 0
        )
    }

    private enum JournalPersistenceCondition {
        case replace
        case missing
        case identity(JournalFileIdentity)
    }

    @discardableResult
    private static func persistCredentialJournal(
        _ journal: CredentialJournal,
        condition: JournalPersistenceCondition = .replace
    ) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(journal) else {
            return false
        }
        guard data.count <= maximumJournalSize else {
            NSLog("Refusing credential journal larger than %d bytes", maximumJournalSize)
            return false
        }
        guard let directoryDescriptor = openJournalDirectory() else { return false }
        defer { _ = close(directoryDescriptor) }

        let temporaryName = ".credential-journal.\(UUID().uuidString).tmp"
        var temporaryDescriptor = temporaryName.withCString {
            openat(
                directoryDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard temporaryDescriptor >= 0 else {
            logPOSIXFailure("Creating temporary credential journal", code: errno)
            return false
        }

        var shouldRemoveTemporaryFile = true
        defer {
            if temporaryDescriptor >= 0 {
                _ = close(temporaryDescriptor)
            }
            if shouldRemoveTemporaryFile {
                temporaryName.withCString {
                    _ = unlinkat(directoryDescriptor, $0, 0)
                }
            }
        }

        guard fchmod(temporaryDescriptor, mode_t(0o600)) == 0,
              writeAll(data, to: temporaryDescriptor),
              fsync(temporaryDescriptor) == 0
        else {
            logPOSIXFailure("Synchronizing temporary credential journal", code: errno)
            return false
        }
        guard close(temporaryDescriptor) == 0 else {
            temporaryDescriptor = -1
            logPOSIXFailure("Closing temporary credential journal", code: errno)
            return false
        }
        temporaryDescriptor = -1

        switch condition {
        case .replace, .missing:
            let renameStatus = temporaryName.withCString { temporaryPath in
                journalFileName.withCString { journalPath in
                    switch condition {
                    case .replace:
                        return renameat(
                            directoryDescriptor,
                            temporaryPath,
                            directoryDescriptor,
                            journalPath
                        )
                    case .missing:
                        return renameatx_np(
                            directoryDescriptor,
                            temporaryPath,
                            directoryDescriptor,
                            journalPath,
                            UInt32(RENAME_EXCL)
                        )
                    case .identity:
                        return -1
                    }
                }
            }
            guard renameStatus == 0 else {
                logPOSIXFailure("Replacing credential journal", code: errno)
                return false
            }
            shouldRemoveTemporaryFile = false
            guard fsync(directoryDescriptor) == 0 else {
                logPOSIXFailure("Synchronizing credential journal directory", code: errno)
                return false
            }
            return true

        case let .identity(expectedIdentity):
            // Swap keeps both versions present while the old inode is verified.
            // If another process replaced the canonical file after our read, swap
            // back atomically instead of overwriting that newer authority.
            let swapStatus = temporaryName.withCString { temporaryPath in
                journalFileName.withCString { journalPath in
                    renameatx_np(
                        directoryDescriptor,
                        temporaryPath,
                        directoryDescriptor,
                        journalPath,
                        UInt32(RENAME_SWAP)
                    )
                }
            }
            guard swapStatus == 0 else {
                logPOSIXFailure("Conditionally replacing credential journal", code: errno)
                return false
            }

            func swapBack() -> Bool {
                let result = temporaryName.withCString { temporaryPath in
                    journalFileName.withCString { journalPath in
                        renameatx_np(
                            directoryDescriptor,
                            temporaryPath,
                            directoryDescriptor,
                            journalPath,
                            UInt32(RENAME_SWAP)
                        )
                    }
                }
                guard result == 0 else {
                    // Preserve both paths if rollback cannot be completed.
                    shouldRemoveTemporaryFile = false
                    logPOSIXFailure("Rolling back credential journal replacement", code: errno)
                    return false
                }
                _ = fsync(directoryDescriptor)
                return true
            }

            var replacedStatus = stat()
            let replacedStatusResult = temporaryName.withCString {
                fstatat(
                    directoryDescriptor,
                    $0,
                    &replacedStatus,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard replacedStatusResult == 0,
                  JournalFileIdentity(replacedStatus) == expectedIdentity
            else {
                NSLog("Credential journal changed before conditional persistence")
                _ = swapBack()
                return false
            }

            guard fsync(directoryDescriptor) == 0 else {
                logPOSIXFailure("Synchronizing conditional journal replacement", code: errno)
                _ = swapBack()
                return false
            }

            // The canonical replacement is now durable. Removing the swapped-out
            // inode is cleanup only; retain it under the hidden temporary name if
            // unlink fails rather than risking the verified canonical file.
            let unlinkStatus = temporaryName.withCString {
                unlinkat(directoryDescriptor, $0, 0)
            }
            if unlinkStatus != 0 {
                shouldRemoveTemporaryFile = false
                logPOSIXFailure("Removing replaced credential journal", code: errno)
                return true
            }
            shouldRemoveTemporaryFile = false
            if fsync(directoryDescriptor) != 0 {
                logPOSIXFailure("Synchronizing replaced journal cleanup", code: errno)
            }
            return true
        }
    }

    private static func legacyCredentialJournal() -> CredentialJournal? {
        guard let data = UserDefaults.standard.data(forKey: legacyCredentialStatesKey) else {
            return nil
        }
        if let journal = try? JSONDecoder().decode(CredentialJournal.self, from: data) {
            return journal
        }
        // The first transactional schema encoded only the state dictionary.
        if let states = try? JSONDecoder().decode(
            [String: CredentialState].self,
            from: data
        ) {
            return CredentialJournal(states: states, pendingPreferences: [:])
        }
        NSLog("Legacy credential journal could not be decoded")
        return nil
    }

    private static func removeLegacyCredentialJournal() {
        guard UserDefaults.standard.object(forKey: legacyCredentialStatesKey) != nil else {
            return
        }
        UserDefaults.standard.removeObject(forKey: legacyCredentialStatesKey)
        if !UserDefaults.standard.synchronize() {
            NSLog("Legacy credential journal removal was deferred")
        }
    }

    private static func setPendingRecoveryUnavailable(_ isUnavailable: Bool) {
        pendingRecoveryUnavailable.withLock { $0 = isUnavailable }
    }

    private static func assessCredentialJournal(
        ignoringPendingRecoveryFailure: Bool = false
    ) -> CredentialJournalAssessment {
        guard ignoringPendingRecoveryFailure
            || !pendingRecoveryUnavailable.withLock({ $0 })
        else {
            return CredentialJournalAssessment(journal: nil, fileIdentity: nil)
        }
        switch readCredentialJournalFile() {
        case let .value(storedJournal, identity):
            guard let sanitizedJournal = sanitizingPendingPreferences(in: storedJournal) else {
                return CredentialJournalAssessment(
                    journal: nil,
                    fileIdentity: identity
                )
            }
            if sanitizedJournal.pendingPreferences != storedJournal.pendingPreferences {
                guard persistCredentialJournal(
                    sanitizedJournal,
                    condition: .identity(identity)
                ) else {
                    NSLog("Sanitized credential journal could not be persisted")
                    return CredentialJournalAssessment(
                        journal: nil,
                        fileIdentity: identity
                    )
                }
                // Atomic persistence replaces the inode. Bind any later recovery
                // action to a second full decode of exactly the replacement file.
                guard case let .value(reloadedJournal, reloadedIdentity) =
                    readCredentialJournalFile(),
                    reloadedJournal == sanitizedJournal
                else {
                    NSLog("Credential journal changed after sanitization")
                    return CredentialJournalAssessment(journal: nil, fileIdentity: nil)
                }
                removeLegacyCredentialJournal()
                return CredentialJournalAssessment(
                    journal: sanitizedJournal,
                    fileIdentity: reloadedIdentity
                )
            }
            removeLegacyCredentialJournal()
            return CredentialJournalAssessment(
                journal: sanitizedJournal,
                fileIdentity: identity
            )

        case .missing:
            guard UserDefaults.standard.object(forKey: legacyCredentialStatesKey) != nil else {
                return CredentialJournalAssessment(journal: .empty, fileIdentity: nil)
            }
            guard let legacyJournal = legacyCredentialJournal(),
                  let sanitizedJournal = sanitizingPendingPreferences(in: legacyJournal)
            else {
                return CredentialJournalAssessment(journal: nil, fileIdentity: nil)
            }
            guard persistCredentialJournal(
                sanitizedJournal,
                condition: .missing
            ) else {
                NSLog("Legacy credential journal migration could not be persisted")
                return CredentialJournalAssessment(journal: nil, fileIdentity: nil)
            }
            guard case let .value(reloadedJournal, reloadedIdentity) =
                readCredentialJournalFile(),
                reloadedJournal == sanitizedJournal
            else {
                NSLog("Credential journal changed after legacy migration")
                return CredentialJournalAssessment(journal: nil, fileIdentity: nil)
            }
            removeLegacyCredentialJournal()
            return CredentialJournalAssessment(
                journal: sanitizedJournal,
                fileIdentity: reloadedIdentity
            )

        case let .failure(identity):
            // Never reinterpret an unreadable protected journal as an empty one:
            // doing so could let stale preferences or Keychain data replace the
            // local authority. Callers fail closed until the journal is readable.
            return CredentialJournalAssessment(
                journal: nil,
                fileIdentity: identity
            )
        }
    }

    private static func credentialJournal(
        ignoringPendingRecoveryFailure: Bool = false
    ) -> CredentialJournal? {
        assessCredentialJournal(
            ignoringPendingRecoveryFailure: ignoringPendingRecoveryFailure
        ).journal
    }

    /// Completes a configuration write that was journaled before a prior
    /// process stopped. This must run before preference wrappers read defaults.
    static func recoverPendingPreferenceTransactions() {
        setPendingRecoveryUnavailable(false)
        let assessment = assessCredentialJournal(
            ignoringPendingRecoveryFailure: true
        )
        guard var journal = assessment.journal else {
            setPendingRecoveryUnavailable(true)
            NSLog("Pending preference recovery deferred because the journal is unavailable")
            return
        }
        guard !journal.pendingPreferences.isEmpty else {
            setPendingRecoveryUnavailable(false)
            return
        }
        for (key, value) in journal.pendingPreferences {
            guard let safeValue = sanitizedPendingPreferenceValue(value, forKey: key) else {
                setPendingRecoveryUnavailable(true)
                NSLog("Pending preference recovery was retained for key %@", key)
                return
            }
            UserDefaults.standard.set(safeValue, forKey: key)
        }
        guard UserDefaults.standard.synchronize() else {
            setPendingRecoveryUnavailable(true)
            NSLog("Pending preference recovery synchronization was deferred")
            return
        }
        journal.pendingPreferences.removeAll()
        guard let fileIdentity = assessment.fileIdentity,
              persistCredentialJournal(
                  journal,
                  condition: .identity(fileIdentity)
              )
        else {
            setPendingRecoveryUnavailable(true)
            NSLog("Recovered pending preferences could not be cleared from the journal")
            return
        }
        setPendingRecoveryUnavailable(false)
    }

    /// Moves an unreadable journal aside without deleting it. This operation is
    /// intentionally user-initiated: automatic replacement could destroy the only
    /// recoverable copy of a local credential after a transient filesystem error.
    static func quarantineUnavailableJournal() async -> JournalRecoveryResult {
        await perform {
            // Availability includes semantic validation of pending preference
            // payloads and the legacy UserDefaults source, not only JSON decoding.
            let unavailableAssessment = assessCredentialJournal(
                ignoringPendingRecoveryFailure: true
            )
            if let journal = unavailableAssessment.journal,
               journal.pendingPreferences.isEmpty
            {
                setPendingRecoveryUnavailable(false)
                return .notRequired
            }
            guard credentialJournal() == nil else { return .notRequired }

            guard let directoryDescriptor = openJournalDirectory() else {
                return .failed
            }
            defer { _ = close(directoryDescriptor) }

            var backupFileNames: [String] = []
            var protectedJournalBackupName: String?

            func restoreOriginalJournal() {
                guard let protectedJournalBackupName else { return }
                let restoreStatus = protectedJournalBackupName.withCString { backupPath in
                    journalFileName.withCString { journalPath in
                        renameatx_np(
                            directoryDescriptor,
                            backupPath,
                            directoryDescriptor,
                            journalPath,
                            UInt32(RENAME_EXCL)
                        )
                    }
                }
                if restoreStatus != 0 {
                    // Never replace a journal created by another process. The
                    // quarantined source remains preserved under its backup name.
                    logPOSIXFailure("Restoring credential journal without replacement", code: errno)
                }
                _ = fsync(directoryDescriptor)
            }

            func changedSourceResult() -> JournalRecoveryResult {
                let latestAssessment = assessCredentialJournal(
                    ignoringPendingRecoveryFailure: true
                )
                if let latestJournal = latestAssessment.journal,
                   latestJournal.pendingPreferences.isEmpty
                {
                    setPendingRecoveryUnavailable(false)
                    return .notRequired
                }
                NSLog("Credential journal changed after its unavailable assessment")
                return .failed
            }

            var sourceStatus = stat()
            let sourceStatusResult = journalFileName.withCString {
                fstatat(
                    directoryDescriptor,
                    $0,
                    &sourceStatus,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            if sourceStatusResult == 0 {
                let currentIdentity = JournalFileIdentity(sourceStatus)
                guard let assessedIdentity = unavailableAssessment.fileIdentity,
                      assessedIdentity == currentIdentity
                else {
                    return changedSourceResult()
                }

                let backupFileName = journalFileName
                    + ".unreadable-"
                    + UUID().uuidString.lowercased()
                    + ".backup"
                let renameStatus = journalFileName.withCString { journalPath in
                    backupFileName.withCString { backupPath in
                        renameatx_np(
                            directoryDescriptor,
                            journalPath,
                            directoryDescriptor,
                            backupPath,
                            UInt32(RENAME_EXCL)
                        )
                    }
                }
                if renameStatus != 0 {
                    if errno == ENOENT { return changedSourceResult() }
                    logPOSIXFailure("Quarantining credential journal", code: errno)
                    return .failed
                }

                protectedJournalBackupName = backupFileName
                var backupStatus = stat()
                let backupStatusResult = backupFileName.withCString {
                    fstatat(
                        directoryDescriptor,
                        $0,
                        &backupStatus,
                        AT_SYMLINK_NOFOLLOW
                    )
                }
                guard backupStatusResult == 0,
                      JournalFileIdentity(backupStatus) == assessedIdentity
                else {
                    NSLog("Credential journal changed while quarantine was starting")
                    restoreOriginalJournal()
                    return .failed
                }
                backupFileNames.append(backupFileName)
                guard fsync(directoryDescriptor) == 0 else {
                    logPOSIXFailure(
                        "Synchronizing quarantined credential journal",
                        code: errno
                    )
                    restoreOriginalJournal()
                    return .failed
                }
            } else {
                if errno != ENOENT {
                    logPOSIXFailure("Inspecting credential journal before quarantine", code: errno)
                    return .failed
                }
                // A file was part of the unavailable assessment but disappeared
                // before quarantine. Re-assess instead of resetting a different
                // legacy source under the same user action.
                if unavailableAssessment.fileIdentity != nil {
                    return changedSourceResult()
                }
            }

            // A valid legacy source may now migrate into a fresh protected file.
            if credentialJournal(ignoringPendingRecoveryFailure: true) != nil {
                setPendingRecoveryUnavailable(false)
                guard !backupFileNames.isEmpty else { return .notRequired }
                return .recovered(backupFileName: backupFileNames.joined(separator: ", "))
            }

            // A malformed legacy UserDefaults record is a separate unavailable
            // source. Preserve its exact property-list representation in the same
            // owner-only directory before removing it from the active defaults.
            guard let legacyObject = UserDefaults.standard.object(
                forKey: legacyCredentialStatesKey
            ), let legacyBackupData = legacyJournalBackupData(from: legacyObject)
            else {
                restoreOriginalJournal()
                return .failed
            }
            let legacyBackupFileName = "credential-states.v1.unreadable-"
                + UUID().uuidString.lowercased()
                + ".backup"
            guard persistBackupData(
                legacyBackupData,
                named: legacyBackupFileName,
                in: directoryDescriptor
            ) else {
                restoreOriginalJournal()
                return .failed
            }
            backupFileNames.append(legacyBackupFileName)

            UserDefaults.standard.removeObject(forKey: legacyCredentialStatesKey)
            guard UserDefaults.standard.synchronize(),
                  UserDefaults.standard.object(forKey: legacyCredentialStatesKey) == nil
            else {
                UserDefaults.standard.set(legacyObject, forKey: legacyCredentialStatesKey)
                _ = UserDefaults.standard.synchronize()
                restoreOriginalJournal()
                return .failed
            }

            guard credentialJournal(ignoringPendingRecoveryFailure: true) != nil else {
                UserDefaults.standard.set(legacyObject, forKey: legacyCredentialStatesKey)
                _ = UserDefaults.standard.synchronize()
                restoreOriginalJournal()
                return .failed
            }
            setPendingRecoveryUnavailable(false)
            return .recovered(backupFileName: backupFileNames.joined(separator: ", "))
        }
    }

    private static func credentialState(
        for account: String,
        journal: CredentialJournal
    ) -> CredentialState? {
        if let state = journal.states[account] {
            return state
        }

        // Compatibility for development builds that wrote the first migration
        // marker before credential authority became transactional.
        guard UserDefaults.standard.string(
            forKey: legacyDispositionPrefix + account
        ) == "cleared"
        else {
            return nil
        }
        let migratedState = CredentialState.clearedState(retainingCopy: true)
        var migratedJournal = journal
        migratedJournal.states[account] = migratedState
        if persistCredentialJournal(migratedJournal) {
            UserDefaults.standard.removeObject(
                forKey: legacyDispositionPrefix + account
            )
        }
        return migratedState
    }

    private static func hasLegacySupersededMarker(for account: String) -> Bool {
        UserDefaults.standard.string(forKey: legacyDispositionPrefix + account)
            == "superseded"
    }

    private static func legacyMarkerMayRetainKeychainCopy(for account: String) -> Bool {
        switch UserDefaults.standard.string(forKey: legacyDispositionPrefix + account) {
        case "superseded", "cleared":
            return true
        default:
            return false
        }
    }

    @discardableResult
    private static func setCredentialState(
        _ state: CredentialState,
        for account: String
    ) -> Bool {
        guard var journal = credentialJournal() else { return false }
        journal.states[account] = state
        guard persistCredentialJournal(journal) else { return false }
        UserDefaults.standard.removeObject(forKey: legacyDispositionPrefix + account)
        return true
    }

    static func resolve(_ currentValue: String, for account: String) async -> Resolution {
        return await perform {
            guard let journal = credentialJournal() else {
                setKeychainBacked(false, for: account)
                // Preserve a legacy plaintext value in place when the protected
                // journal cannot be inspected. Replacing it with an apparent
                // empty state would make a transient I/O failure destructive.
                return Resolution(
                    runtimeValue: currentValue,
                    persistedValue: currentValue,
                    requiresUserAttention: true,
                    journalUnavailable: true
                )
            }
            if let state = credentialState(for: account, journal: journal) {
                switch state.storage {
                case .cleared:
                    // A clear transaction is authoritative even when the model's
                    // older plaintext field survived a crash. A stable build may
                    // only attempt best-effort physical Keychain cleanup.
                    if usesKeychainStorage, state.mayRetainKeychainCopy {
                        let removedCurrent = remove(for: account)
                        let removedLegacy = remove(for: account, serviceName: legacyService)
                        if removedCurrent, removedLegacy {
                            _ = setCredentialState(.cleared, for: account)
                        }
                    }
                    setKeychainBacked(false, for: account)
                    return Resolution(
                        runtimeValue: "",
                        persistedValue: "",
                        requiresUserAttention: false
                    )

                case .local:
                    guard let value = state.localValue, !value.isEmpty else {
                        setKeychainBacked(false, for: account)
                        return Resolution(
                            runtimeValue: "",
                            persistedValue: "",
                            requiresUserAttention: true
                        )
                    }
                    guard usesKeychainStorage else {
                        setKeychainBacked(false, for: account)
                        return Resolution(
                            runtimeValue: value,
                            persistedValue: "",
                            requiresUserAttention: false
                        )
                    }

                    let didMigrate = store(value, for: account)
                    setKeychainBacked(didMigrate, for: account)
                    if didMigrate {
                        let retainedCopy = state.mayRetainKeychainCopy
                            && !remove(for: account, serviceName: legacyService)
                        _ = setCredentialState(
                            .keychainState(retainingCopy: retainedCopy),
                            for: account
                        )
                    }
                    return Resolution(
                        runtimeValue: value,
                        persistedValue: "",
                        requiresUserAttention: !didMigrate
                    )

                case .keychain:
                    switch lookup(for: account) {
                    case let .value(value):
                        if usesKeychainStorage {
                            setKeychainBacked(true, for: account)
                            return Resolution(
                                runtimeValue: value,
                                persistedValue: "",
                                requiresUserAttention: false
                            )
                        }
                        // An ad-hoc build cannot rely on a stable Keychain ACL.
                        // Move the recovered value into the single-record local
                        // authority before exposing it to the running model.
                        _ = setCredentialState(
                            .local(value, retainingCopy: true),
                            for: account
                        )
                        setKeychainBacked(false, for: account)
                        return Resolution(
                            runtimeValue: value,
                            persistedValue: "",
                            requiresUserAttention: false
                        )
                    case .missing, .failure:
                        // `currentValue` may be the stale pre-transaction value.
                        // Never let it override a newer Keychain-authoritative
                        // credential merely because the Keychain is unavailable.
                        setKeychainBacked(false, for: account)
                        return Resolution(
                            runtimeValue: "",
                            persistedValue: "",
                            requiresUserAttention: true
                        )
                    }
                }
            }

            // Compatibility for a short-lived development marker that did not
            // record whether local preferences or v2 was authoritative. A
            // nonempty model value was written by the local-fallback path and is
            // therefore the strongest recoverable signal. Prefer it over a
            // possibly stale v2 item, then migrate it when stable signing allows.
            if hasLegacySupersededMarker(for: account) {
                if !currentValue.isEmpty {
                    if usesKeychainStorage {
                        let didMigrate = store(currentValue, for: account)
                        setKeychainBacked(didMigrate, for: account)
                        let didPersistState = setCredentialState(
                            didMigrate
                                ? .keychain
                                : .local(currentValue, retainingCopy: true),
                            for: account
                        )
                        let hasProtectedCopy = didMigrate || didPersistState
                        return Resolution(
                            runtimeValue: currentValue,
                            persistedValue: hasProtectedCopy ? "" : currentValue,
                            requiresUserAttention: !didMigrate || !didPersistState
                        )
                    }

                    let didPersistState = setCredentialState(
                        .local(currentValue, retainingCopy: true),
                        for: account
                    )
                    setKeychainBacked(false, for: account)
                    return Resolution(
                        runtimeValue: currentValue,
                        persistedValue: didPersistState ? "" : currentValue,
                        requiresUserAttention: !didPersistState
                    )
                }

                switch lookup(for: account) {
                case let .value(value):
                    if usesKeychainStorage {
                        _ = setCredentialState(.keychain, for: account)
                        setKeychainBacked(true, for: account)
                        return Resolution(
                            runtimeValue: value,
                            persistedValue: "",
                            requiresUserAttention: false
                        )
                    }
                    let didPersistState = setCredentialState(
                        .local(value, retainingCopy: true),
                        for: account
                    )
                    setKeychainBacked(false, for: account)
                    return Resolution(
                        runtimeValue: value,
                        persistedValue: didPersistState ? "" : value,
                        requiresUserAttention: !didPersistState
                    )
                case .missing, .failure:
                    setKeychainBacked(false, for: account)
                    return Resolution(
                        runtimeValue: "",
                        persistedValue: "",
                        requiresUserAttention: true
                    )
                }
            }

            if !currentValue.isEmpty {
                if usesKeychainStorage {
                    let didMigrate = store(currentValue, for: account)
                    setKeychainBacked(didMigrate, for: account)
                    let didPersistState = setCredentialState(
                        didMigrate
                            ? .keychain
                            : .local(currentValue, retainingCopy: true),
                        for: account
                    )
                    let hasProtectedCopy = didMigrate || didPersistState
                    return Resolution(
                        runtimeValue: currentValue,
                        persistedValue: hasProtectedCopy ? "" : currentValue,
                        requiresUserAttention: !didMigrate || !didPersistState
                    )
                }

                let didPersistState = setCredentialState(.local(currentValue), for: account)
                setKeychainBacked(false, for: account)
                return Resolution(
                    runtimeValue: currentValue,
                    persistedValue: didPersistState ? "" : currentValue,
                    requiresUserAttention: !didPersistState
                )
            }

            // A stable build may have already redacted the model after writing
            // v2. Always inspect the current service before the legacy namespace.
            switch lookup(for: account) {
            case let .value(value):
                if usesKeychainStorage {
                    _ = setCredentialState(.keychain, for: account)
                    setKeychainBacked(true, for: account)
                    return Resolution(
                        runtimeValue: value,
                        persistedValue: "",
                        requiresUserAttention: false
                    )
                }
                let didPersistState = setCredentialState(
                    .local(value, retainingCopy: true),
                    for: account
                )
                setKeychainBacked(false, for: account)
                return Resolution(
                    runtimeValue: value,
                    persistedValue: didPersistState ? "" : value,
                    requiresUserAttention: !didPersistState
                )
            case .failure:
                setKeychainBacked(false, for: account)
                return Resolution(
                    runtimeValue: "",
                    persistedValue: "",
                    requiresUserAttention: true
                )
            case .missing:
                break
            }

            // Migrate a readable item created by the pre-versioned implementation.
            switch lookup(for: account, serviceName: legacyService) {
            case let .value(value):
                if usesKeychainStorage {
                    let didMigrate = store(value, for: account)
                    setKeychainBacked(didMigrate, for: account)
                    let retainedLegacyCopy = didMigrate
                        && !remove(for: account, serviceName: legacyService)
                    _ = setCredentialState(
                        didMigrate
                            ? .keychainState(retainingCopy: retainedLegacyCopy)
                            : .local(value, retainingCopy: true),
                        for: account
                    )
                    return Resolution(
                        runtimeValue: value,
                        persistedValue: "",
                        requiresUserAttention: !didMigrate
                    )
                }

                let didPersistState = setCredentialState(
                    .local(value, retainingCopy: true),
                    for: account
                )
                setKeychainBacked(false, for: account)
                return Resolution(
                    runtimeValue: value,
                    persistedValue: didPersistState ? "" : value,
                    requiresUserAttention: !didPersistState
                )
            case .missing:
                setKeychainBacked(false, for: account)
                return Resolution(
                    runtimeValue: "",
                    persistedValue: "",
                    requiresUserAttention: false
                )
            case .failure:
                setKeychainBacked(false, for: account)
                return Resolution(
                    runtimeValue: "",
                    persistedValue: "",
                    requiresUserAttention: true
                )
            }
        }
    }

    /// Applies a group of credential changes.
    ///
    /// Unchanged credential fields are excluded so an unrelated metadata edit
    /// remains possible while Keychain is unavailable. A changed value falls
    /// back to the protected journal when a non-interactive Keychain operation fails.
    /// All requested values are staged in one authoritative state record before
    /// the first Keychain mutation, closing the save-to-model crash window.
    static func apply(
        _ changes: [Change],
        pendingPreferences: [PendingPreference] = []
    ) async -> ApplyResult {
        return await perform {
            applySynchronously(
                changes,
                pendingPreferences: pendingPreferences
            )
        }
    }

    private static func applySynchronously(
        _ changes: [Change],
        pendingPreferences: [PendingPreference]
    ) -> ApplyResult {
        let relevantChanges = changes.filter { $0.previousValue != $0.newValue }
        guard !relevantChanges.isEmpty || !pendingPreferences.isEmpty else {
            return .persisted
        }
        guard Set(relevantChanges.map(\.account)).count == relevantChanges.count else {
            NSLog("Refusing duplicate Keychain credential changes")
            return .failed
        }
        guard Set(pendingPreferences.map(\.key)).count == pendingPreferences.count else {
            NSLog("Refusing duplicate pending preference changes")
            return .failed
        }

        var safePendingPreferences: [PendingPreference] = []
        safePendingPreferences.reserveCapacity(pendingPreferences.count)
        for preference in pendingPreferences {
            guard let safeValue = sanitizedPendingPreferenceValue(
                preference.value,
                forKey: preference.key
            ) else {
                NSLog("Refusing invalid pending preference for key %@", preference.key)
                return .failed
            }
            safePendingPreferences.append(
                PendingPreference(key: preference.key, value: safeValue)
            )
        }

        guard let originalJournal = credentialJournal() else {
            NSLog("Refusing credential update because the journal is unavailable")
            return .failed
        }
        let originalStates = originalJournal.states
        var stagedJournal = originalJournal
        for change in relevantChanges {
            let mayRetainKeychainCopy = originalStates[change.account]?.couldHaveKeychainCopy
                ?? legacyMarkerMayRetainKeychainCopy(for: change.account)
            stagedJournal.states[change.account] = change.newValue.isEmpty
                ? .clearedState(retainingCopy: mayRetainKeychainCopy)
                : .local(
                    change.newValue,
                    retainingCopy: mayRetainKeychainCopy
                )
        }
        for preference in safePendingPreferences {
            stagedJournal.pendingPreferences[preference.key] = preference.value
        }

        guard usesKeychainStorage else {
            guard persistCredentialJournal(stagedJournal) else { return .failed }
            for change in relevantChanges {
                UserDefaults.standard.removeObject(
                    forKey: legacyDispositionPrefix + change.account
                )
                setKeychainBacked(false, for: change.account)
            }
            commitPendingPreferences(
                safePendingPreferences,
                journal: &stagedJournal
            )
            return ApplyResult(
                succeeded: true,
                usedLocalFallback: false,
                retainedClearedKeychainValue: relevantChanges.contains {
                    $0.newValue.isEmpty
                        && stagedJournal.states[$0.account]?.mayRetainKeychainCopy == true
                }
            )
        }

        guard didDisableLegacyKeychainUI else {
            // Security.framework could not guarantee a non-interactive call.
            // Commit the complete local transaction without touching Keychain.
            guard persistCredentialJournal(stagedJournal) else { return .failed }
            var usedLocalFallback = false
            var retainedClearedKeychainValue = false
            for change in relevantChanges {
                setKeychainBacked(false, for: change.account)
                usedLocalFallback = usedLocalFallback || !change.newValue.isEmpty
                retainedClearedKeychainValue =
                    retainedClearedKeychainValue
                    || (change.newValue.isEmpty
                        && stagedJournal.states[change.account]?.mayRetainKeychainCopy == true)
            }
            commitPendingPreferences(
                safePendingPreferences,
                journal: &stagedJournal
            )
            return ApplyResult(
                succeeded: true,
                usedLocalFallback: usedLocalFallback,
                retainedClearedKeychainValue: retainedClearedKeychainValue
            )
        }

        var snapshots: [(change: Change, lookup: Lookup)] = []
        for change in relevantChanges {
            let current = lookup(for: change.account)
            let originalState = originalStates[change.account]

            let matchesExpectedValue: Bool
            switch current {
            case let .value(value):
                switch originalState?.storage {
                case .local:
                    matchesExpectedValue = originalState?.localValue
                        == change.previousValue
                case .cleared:
                    matchesExpectedValue = change.previousValue.isEmpty
                case .keychain, nil:
                    matchesExpectedValue = value == change.previousValue
                }
            case .missing:
                if originalState?.storage == .local {
                    matchesExpectedValue = originalState?.localValue
                        == change.previousValue
                } else {
                    matchesExpectedValue = change.previousValue.isEmpty
                        || !isKnownKeychainBacked(change.account)
                }
            case let .failure(status):
                NSLog(
                    "Keychain preflight failed for %@ (status %d); using local fallback",
                    change.account,
                    status
                )
                matchesExpectedValue = true
            }
            guard matchesExpectedValue else {
                NSLog("Keychain credential changed during update for %@", change.account)
                return .failed
            }
            snapshots.append((change, current))
        }

        // Persist all desired values together before mutating Keychain. If the
        // process stops below this point, the next launch replays these staged
        // local values rather than accepting stale model or Keychain data.
        guard persistCredentialJournal(stagedJournal) else { return .failed }
        for change in relevantChanges {
            UserDefaults.standard.removeObject(
                forKey: legacyDispositionPrefix + change.account
            )
        }

        var finalJournal = stagedJournal
        var usedLocalFallback = false
        var retainedClearedKeychainValue = false
        for snapshot in snapshots {
            if snapshot.change.newValue.isEmpty {
                var removedFromKeychain: Bool
                if case .failure = snapshot.lookup {
                    removedFromKeychain = false
                } else {
                    removedFromKeychain = remove(for: snapshot.change.account)
                }
                if removedFromKeychain,
                   stagedJournal.states[
                       snapshot.change.account
                   ]?.mayRetainKeychainCopy == true
                {
                    removedFromKeychain = remove(
                        for: snapshot.change.account,
                        serviceName: legacyService
                    )
                }
                retainedClearedKeychainValue =
                    retainedClearedKeychainValue || !removedFromKeychain
                finalJournal.states[snapshot.change.account] = .clearedState(
                    retainingCopy: !removedFromKeychain
                )
                continue
            }

            let storedInKeychain: Bool
            switch snapshot.lookup {
            case let .value(currentValue)
                where currentValue == snapshot.change.newValue:
                storedInKeychain = true
            case .failure:
                storedInKeychain = false
            default:
                storedInKeychain = store(
                    snapshot.change.newValue,
                    for: snapshot.change.account
                )
            }
            if storedInKeychain {
                var retainedAdditionalCopy = originalStates[
                    snapshot.change.account
                ]?.mayRetainKeychainCopy == true
                if retainedAdditionalCopy {
                    retainedAdditionalCopy = !remove(
                        for: snapshot.change.account,
                        serviceName: legacyService
                    )
                }
                finalJournal.states[snapshot.change.account] = .keychainState(
                    retainingCopy: retainedAdditionalCopy
                )
            } else {
                let mayRetainKeychainCopy: Bool
                switch snapshot.lookup {
                case .value, .failure:
                    mayRetainKeychainCopy = true
                case .missing:
                    mayRetainKeychainCopy = originalStates[
                        snapshot.change.account
                    ]?.mayRetainKeychainCopy == true
                }
                finalJournal.states[snapshot.change.account] = .local(
                    snapshot.change.newValue,
                    retainingCopy: mayRetainKeychainCopy
                )
                usedLocalFallback = true
            }
        }

        if !persistCredentialJournal(finalJournal) {
            // The staging record is already durable and contains every desired
            // value. Restore it as the runtime authority if the compact final
            // state could not be synchronized.
            _ = persistCredentialJournal(stagedJournal)
            usedLocalFallback = relevantChanges.contains {
                !$0.newValue.isEmpty
            }
            retainedClearedKeychainValue =
                retainedClearedKeychainValue || relevantChanges.contains {
                    $0.newValue.isEmpty
                        && stagedJournal.states[$0.account]?.mayRetainKeychainCopy == true
                }
            for change in relevantChanges {
                setKeychainBacked(false, for: change.account)
            }
        } else {
            for change in relevantChanges {
                let isBacked = finalJournal.states[change.account]?.storage == .keychain
                    && !change.newValue.isEmpty
                setKeychainBacked(isBacked, for: change.account)
            }
        }

        commitPendingPreferences(
            safePendingPreferences,
            journal: &finalJournal
        )

        return ApplyResult(
            succeeded: true,
            usedLocalFallback: usedLocalFallback,
            retainedClearedKeychainValue: retainedClearedKeychainValue
        )
    }

    /// Commits the configuration values only after the authoritative credential
    /// state is durable. The pending entries remain in the journal until the
    /// preferences have been written, so startup recovery can complete either
    /// side of a process interruption without mixing old metadata and new secrets.
    private static func commitPendingPreferences(
        _ pendingPreferences: [PendingPreference],
        journal: inout CredentialJournal
    ) {
        guard !pendingPreferences.isEmpty else { return }
        for preference in pendingPreferences {
            UserDefaults.standard.set(preference.value, forKey: preference.key)
        }
        guard UserDefaults.standard.synchronize() else {
            NSLog("Pending preference synchronization was deferred")
            return
        }
        for preference in pendingPreferences {
            journal.pendingPreferences.removeValue(forKey: preference.key)
        }
        if !persistCredentialJournal(journal) {
            // The previously persisted journal still contains these entries, so
            // startup recovery will replay the already-visible values idempotently.
            NSLog("Could not clear committed pending preference entries")
        }
    }

    private static func lookup(
        for account: String,
        serviceName: String = service
    ) -> Lookup {
        guard didDisableLegacyKeychainUI else {
            return .failure(errSecInteractionNotAllowed)
        }
        var query = baseQuery(for: account, serviceName: serviceName)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            NSLog("Keychain read failed for %@ (status %d)", account, status)
            return .failure(status == errSecSuccess ? errSecDecode : status)
        }
        return .value(value)
    }

    @discardableResult
    private static func store(_ value: String, for account: String) -> Bool {
        // Deletion is intentionally a separate operation. A transient Keychain
        // read failure must never turn an empty in-memory value into a request to
        // delete a credential that may still exist.
        guard !value.isEmpty, didDisableLegacyKeychainUI else { return false }

        let query = baseQuery(for: account, serviceName: service)
        guard let data = value.data(using: .utf8) else { return false }
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else {
            NSLog("Keychain update failed for %@ (status %d)", account, updateStatus)
            return false
        }

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            NSLog("Keychain add failed for %@ (status %d)", account, addStatus)
            return false
        }
        return true
    }

    @discardableResult
    private static func remove(
        for account: String,
        serviceName: String = service
    ) -> Bool {
        guard didDisableLegacyKeychainUI else { return false }
        let status = SecItemDelete(
            baseQuery(for: account, serviceName: serviceName) as CFDictionary
        )
        if status == errSecSuccess || status == errSecItemNotFound { return true }
        NSLog("Keychain delete failed for %@ (status %d)", account, status)
        return false
    }

    private static func baseQuery(
        for account: String,
        serviceName: String
    ) -> [String: Any] {
        let authenticationContext = LAContext()
        // ProcessReporter is also distributed with ad-hoc signing while the
        // Developer ID certificate is unavailable. Never let an inaccessible
        // Keychain item stall application bootstrap behind an authentication UI.
        authenticationContext.interactionNotAllowed = true

        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: authenticationContext,
        ]
    }

    private static func perform<T: Sendable>(
        _ operation: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: operation())
            }
        }
    }
}

protocol UserDefaultsStorable {
    func toStorable() -> Any?
    static func fromStorable(_ value: Any?) -> Self?
}

@propertyWrapper
struct UserDefaultsRelay<T> {
    private let key: String
    private let defaultValue: T
    private let relay: BehaviorRelay<T>
    private let disposeBag = DisposeBag()

    init(_ key: String, defaultValue: T) {
        self.key = key
        self.defaultValue = defaultValue

        // 从 UserDefaults 读取值，如果不存在则使用默认值
        let savedValue: T

        if let storable = defaultValue as? (any UserDefaultsStorable) {
            // 使用类型擦除方式访问协议实例
            let valueType = type(of: storable)
            let storageValue = UserDefaults.standard.object(forKey: key)
            if let value = valueType.fromStorable(storageValue) as? T {
                savedValue = value

            } else {
                savedValue = defaultValue
            }
        } else {
            // 标准类型直接使用
            savedValue = UserDefaults.standard.object(forKey: key) as? T ?? defaultValue
        }

        relay = BehaviorRelay<T>(value: savedValue)

        // 观察变化并保存到 UserDefaults
        relay
            .skip(1)  // 跳过初始值
            .subscribe(onNext: { value in
                if let storable = value as? any UserDefaultsStorable {
                    // 使用协议方法转换为可存储类型
                    if let storedValue = storable.toStorable() {
                        UserDefaults.standard.set(storedValue, forKey: key)
                    } else {
                        NSLog("UserDefaults encoding failed for key %@", key)
                    }
                } else {
                    // 标准类型直接存储
                    UserDefaults.standard.set(value, forKey: key)
                }
            })
            .disposed(by: disposeBag)

        #if DEBUG
            relay.skip(1)
                .subscribe(onNext: { _ in
                    // Integration values may contain API tokens or object-storage
                    // credentials. Record the changed key without leaking its value
                    // into Console or collected diagnostic logs.
                    debugPrint("UserDefaultsRelay: \(key) changed")
                })
                .disposed(by: disposeBag)
        #endif
    }

    var wrappedValue: BehaviorRelay<T> {
        return relay
    }
}

protocol UserDefaultsJSONStorable: UserDefaultsStorable, Codable {}

extension UserDefaultsJSONStorable {
    func toStorable() -> Any? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        if let jsonData = try? encoder.encode(self) {
            let jsonString = String(data: jsonData, encoding: .utf8)
            return jsonString ?? ""
        }
        return nil
    }

    static func fromStorable(_ value: Any?) -> Self? {
        guard let value = value as? String else {
            return nil
        }
        let decoder = JSONDecoder()
        if let jsonData = value.data(using: .utf8) {
            return try? decoder.decode(Self.self, from: jsonData)
        }
        return nil
    }
}
