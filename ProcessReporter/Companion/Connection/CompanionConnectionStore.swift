import Foundation

enum CompanionConnectionStoreError: Error, Equatable, Sendable {
    case invalidMetadata
    case invalidDeviceIdentifier
    case invalidNextSequence
    case missingCredential
    case credentialStorageUnavailable
    case credentialPersistenceFailed
}

enum CompanionDeviceScope: String, Codable, CaseIterable, Hashable, Sendable {
    case presenceWrite = "companion:presence:write"
    case momentWrite = "companion:moment:write"
    case readingRead = "companion:reading:read"
    case readingWrite = "companion:reading:write"
}

/// Non-secret connection state. This value is safe to persist in UserDefaults;
/// the Device Token is deliberately absent from both the model and its CodingKeys.
struct CompanionConnectionMetadata: Codable, Equatable, Sendable {
    private static let currentStorageVersion = 1

    let storageVersion: Int
    let baseURL: URL
    let deviceID: String
    let scopes: [CompanionDeviceScope]
    let pairingNextSequence: Int
    let isLiveDeskEnabled: Bool

    init(
        baseURL: URL,
        deviceID: String,
        scopes: [CompanionDeviceScope] = [.presenceWrite],
        pairingNextSequence: Int,
        isLiveDeskEnabled: Bool
    ) throws {
        guard CompanionIdentifier.isValid(deviceID) else {
            throw CompanionConnectionStoreError.invalidDeviceIdentifier
        }
        guard pairingNextSequence >= 0,
              pairingNextSequence <= CompanionProtocolV2.maximumSafeInteger
        else {
            throw CompanionConnectionStoreError.invalidNextSequence
        }
        let normalizedScopes = Array(Set(scopes)).sorted { $0.rawValue < $1.rawValue }
        guard !normalizedScopes.isEmpty else {
            throw CompanionConnectionStoreError.invalidMetadata
        }
        _ = try CompanionServerConfiguration(baseURL: baseURL)

        storageVersion = Self.currentStorageVersion
        self.baseURL = baseURL
        self.deviceID = deviceID
        self.scopes = normalizedScopes
        self.pairingNextSequence = pairingNextSequence
        self.isLiveDeskEnabled = isLiveDeskEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case storageVersion
        case baseURL
        case deviceID
        case scopes
        case pairingNextSequence
        case isLiveDeskEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storageVersion = try container.decode(Int.self, forKey: .storageVersion)
        guard storageVersion == Self.currentStorageVersion else {
            throw CompanionConnectionStoreError.invalidMetadata
        }
        try self.init(
            baseURL: container.decode(URL.self, forKey: .baseURL),
            deviceID: container.decode(String.self, forKey: .deviceID),
            scopes: container.decode([CompanionDeviceScope].self, forKey: .scopes),
            pairingNextSequence: container.decode(Int.self, forKey: .pairingNextSequence),
            isLiveDeskEnabled: container.decode(Bool.self, forKey: .isLiveDeskEnabled)
        )
    }

    func settingLiveDeskEnabled(_ isEnabled: Bool) throws -> CompanionConnectionMetadata {
        try CompanionConnectionMetadata(
            baseURL: baseURL,
            deviceID: deviceID,
            scopes: scopes,
            pairingNextSequence: pairingNextSequence,
            isLiveDeskEnabled: isEnabled
        )
    }
}

struct CompanionPairingClaim: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let baseURL: URL
    let deviceID: String
    let deviceToken: String
    let scopes: [CompanionDeviceScope]
    let nextSequence: Int

    init(
        baseURL: URL,
        deviceID: String,
        deviceToken: String,
        scopes: [CompanionDeviceScope] = [.presenceWrite],
        nextSequence: Int
    ) throws {
        let normalizedToken = deviceToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedToken.isEmpty else {
            throw CompanionConnectionStoreError.missingCredential
        }
        _ = try CompanionConnectionMetadata(
            baseURL: baseURL,
            deviceID: deviceID,
            scopes: scopes,
            pairingNextSequence: nextSequence,
            // Pairing never implies public sharing. A later preview confirmation
            // must explicitly enable Live Desk.
            isLiveDeskEnabled: false
        )

        self.baseURL = baseURL
        self.deviceID = deviceID
        self.deviceToken = normalizedToken
        self.scopes = Array(Set(scopes)).sorted { $0.rawValue < $1.rawValue }
        self.nextSequence = nextSequence
    }

    var description: String { "CompanionPairingClaim(<redacted>)" }
    var debugDescription: String { description }
}

struct CompanionPairedConnection: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let metadata: CompanionConnectionMetadata
    let server: CompanionServerConfiguration
    let credential: CompanionDeviceCredential

    var description: String { "CompanionPairedConnection(<redacted>)" }
    var debugDescription: String { description }
}

/// Owns the credential transaction boundary. Implementations must store the
/// token in protected storage and commit only the supplied non-secret metadata
/// to UserDefaults after that protected authority is durable.
protocol CompanionConnectionCredentialPersistence: Sendable {
    func resolveDeviceToken() async throws -> String?

    func replaceDeviceToken(
        previousValue: String,
        newValue: String,
        pendingMetadataKey: String,
        pendingMetadataValue: String
    ) async throws -> CompanionCredentialMutationResult
}

struct CompanionCredentialMutationResult: Equatable, Sendable {
    let retainedClearedKeychainValue: Bool
}

actor CompanionConnectionStore {
    static let metadataKey = "companion.connection.metadata.v1"

    private let defaults: UserDefaults
    private let credentialPersistence: any CompanionConnectionCredentialPersistence
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        defaults: UserDefaults = .standard,
        credentialPersistence: any CompanionConnectionCredentialPersistence
    ) {
        self.defaults = defaults
        self.credentialPersistence = credentialPersistence
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
    }

    /// Persists a newly claimed connection while keeping Live Desk disabled.
    /// The token is passed only to the protected persistence implementation; it
    /// is never included in the metadata string or written by this actor.
    func installPairingClaim(_ claim: CompanionPairingClaim) async throws {
        let metadata = try CompanionConnectionMetadata(
            baseURL: claim.baseURL,
            deviceID: claim.deviceID,
            scopes: claim.scopes,
            pairingNextSequence: claim.nextSequence,
            isLiveDeskEnabled: false
        )
        let metadataValue = try encodeMetadata(metadata)
        let previousToken = try await credentialPersistence.resolveDeviceToken() ?? ""
        _ = try await credentialPersistence.replaceDeviceToken(
            previousValue: previousToken,
            newValue: claim.deviceToken,
            pendingMetadataKey: Self.metadataKey,
            pendingMetadataValue: metadataValue
        )
    }

    /// Pairing codes are single-use. Callers preflight protected storage before
    /// consuming one so a known-unavailable credential authority fails without
    /// asking the server to mint an otherwise unrecoverable Device Token.
    func ensureProtectedStorageAvailable() async throws {
        _ = try await credentialPersistence.resolveDeviceToken()
    }

    func loadMetadata() throws -> CompanionConnectionMetadata? {
        guard let storedValue = defaults.string(forKey: Self.metadataKey),
              !storedValue.isEmpty
        else {
            return nil
        }
        guard let data = storedValue.data(using: .utf8) else {
            throw CompanionConnectionStoreError.invalidMetadata
        }
        do {
            return try decoder.decode(CompanionConnectionMetadata.self, from: data)
        } catch let error as CompanionConnectionStoreError {
            throw error
        } catch {
            throw CompanionConnectionStoreError.invalidMetadata
        }
    }

    /// Resolves the protected token only after both the local opt-in and the
    /// non-secret connection metadata have passed validation.
    func loadEnabledConnection() async throws -> CompanionPairedConnection? {
        guard let metadata = try loadMetadata(), metadata.isLiveDeskEnabled else {
            return nil
        }
        guard let token = try await credentialPersistence.resolveDeviceToken(),
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CompanionConnectionStoreError.missingCredential
        }
        // Credential resolution crosses an actor boundary. Re-read the local
        // consent record so a concurrent disable cannot publish with a token
        // that was resolved under the older enabled state.
        guard let currentMetadata = try loadMetadata(),
              currentMetadata == metadata,
              currentMetadata.isLiveDeskEnabled
        else {
            return nil
        }
        return CompanionPairedConnection(
            metadata: currentMetadata,
            server: try CompanionServerConfiguration(baseURL: currentMetadata.baseURL),
            credential: try CompanionDeviceCredential(
                deviceID: currentMetadata.deviceID,
                token: token
            )
        )
    }

    /// This is the explicit post-preview consent boundary. Pairing itself always
    /// persists `false`, so no newly claimed device can publish immediately.
    func setLiveDeskEnabled(_ isEnabled: Bool) throws {
        guard let metadata = try loadMetadata() else { return }
        let updated = try metadata.settingLiveDeskEnabled(isEnabled)
        defaults.set(try encodeMetadata(updated), forKey: Self.metadataKey)
    }

    func removeConnection() async throws -> CompanionCredentialMutationResult {
        let previousToken = try await credentialPersistence.resolveDeviceToken() ?? ""
        return try await credentialPersistence.replaceDeviceToken(
            previousValue: previousToken,
            newValue: "",
            pendingMetadataKey: Self.metadataKey,
            pendingMetadataValue: ""
        )
    }

    private func encodeMetadata(_ metadata: CompanionConnectionMetadata) throws -> String {
        let data = try encoder.encode(metadata)
        guard let value = String(data: data, encoding: .utf8) else {
            throw CompanionConnectionStoreError.invalidMetadata
        }
        return value
    }
}
