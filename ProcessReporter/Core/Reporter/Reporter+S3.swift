//
//  Reporter+S3.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/14.
//

import Foundation

extension Notification.Name {
    static let assetHostingFailedUploadsDidChange = Notification.Name(
        "AssetHostingFailedUploadsDidChange"
    )
}

struct AssetHostingMaintenanceResult: Sendable {
    let attempted: Int
    let succeeded: Int

    var failed: Int { attempted - succeeded }
}

enum AssetHostingMaintenanceError: LocalizedError {
    case configurationUnavailable
    case credentialAuthorityUnavailable

    var errorDescription: String? {
        switch self {
        case .configurationUnavailable:
            return "Save a valid Application Icon Hosting configuration before running maintenance."
        case .credentialAuthorityUnavailable:
            return "Protected credentials are unavailable. Resolve credential recovery before running Application Icon Hosting maintenance."
        }
    }
}

@MainActor
protocol AssetHostingService {
    func resolveApplicationIcon(
        for data: ReportModel,
        capability: PresenceAssetCapability
    ) async -> PresenceAssetResolution
}

@MainActor
final class S3AssetHostingService: AssetHostingService {
    private static let uploadFingerprintsKey = "s3UploadedIconFingerprints"
    private static let failedUploadsKey = "s3FailedIconUploads"

    static var failedUploadCount: Int { failedUploads.count }

    static func clearStoredUploadFingerprints() {
        UserDefaults.standard.removeObject(forKey: uploadFingerprintsKey)
    }

    static func clearFailedUploads() {
        updateFailedUploads([:])
    }

    static func retryFailedUploads() async throws -> AssetHostingMaintenanceResult {
        guard !PreferencesDataModel.integrationCredentialStoreUnavailable else {
            throw AssetHostingMaintenanceError.credentialAuthorityUnavailable
        }
        let configuration = PreferencesDataModel.s3Integration.value
        guard configuration.isEnabled, configuration.isValidAssetHostingConfiguration else {
            throw AssetHostingMaintenanceError.configurationUnavailable
        }
        return await uploadApplications(failedUploads, configuration: configuration)
    }

    static func rebuildCachedIcons() async throws -> AssetHostingMaintenanceResult {
        guard !PreferencesDataModel.integrationCredentialStoreUnavailable else {
            throw AssetHostingMaintenanceError.credentialAuthorityUnavailable
        }
        let configuration = PreferencesDataModel.s3Integration.value
        guard configuration.isEnabled, configuration.isValidAssetHostingConfiguration else {
            throw AssetHostingMaintenanceError.configurationUnavailable
        }
        let icons = try await DataStore.shared.fetchIcons()
        let applications = Dictionary(
            uniqueKeysWithValues: icons.map { ($0.applicationIdentifier, $0.name) }
        )
        return await uploadApplications(applications, configuration: configuration)
    }

    func resolveApplicationIcon(
        for data: ReportModel,
        capability: PresenceAssetCapability
    ) async -> PresenceAssetResolution {
        guard capability != .unsupported else { return .notRequested }

        guard let applicationIdentifier = data.sourceProcessApplicationIdentifier
                ?? data.processInfoRaw?.applicationIdentifier,
              !applicationIdentifier.isEmpty
        else { return .notRequested }

        let storedURL = await DataStore.shared.iconURL(for: applicationIdentifier)
        let cachedURL = storedURL.flatMap(Self.validatedPublicURL)
        let configuration = PreferencesDataModel.s3Integration.value
        guard configuration.isEnabled else {
            if let cachedURL {
                return .cached(publicURL: cachedURL)
            }
            return capability == .requiredPublicURL
                ? .failed(
                    message: "Application Icon Hosting is not configured.",
                    fallbackPublicURL: nil
                )
                : .notConfigured
        }

        guard let image = data.processInfoRaw?.icon,
              let iconData = image.data,
              let appName = data.processName,
              !appName.isEmpty
        else {
            if let cachedURL {
                return .cached(publicURL: cachedURL)
            }
            return capability == .requiredPublicURL
                ? .failed(
                    message: "No application icon is available to host.",
                    fallbackPublicURL: nil
                )
                : .notRequested
        }

        let expectedURL: String
        let uploadFingerprint = Self.uploadFingerprint(
            iconData: iconData,
            config: configuration
        )
        do {
            expectedURL = try S3Uploader.publicIconURL(iconData, config: configuration)
        } catch {
            Self.enqueueFailedUpload(
                applicationIdentifier: applicationIdentifier,
                appName: appName
            )
            return .failed(
                message: error.localizedDescription,
                fallbackPublicURL: cachedURL
            )
        }
        guard let expectedURL = Self.validatedPublicURL(expectedURL) else {
            Self.enqueueFailedUpload(
                applicationIdentifier: applicationIdentifier,
                appName: appName
            )
            return .failed(
                message: "Application Icon Hosting must use HTTPS except on localhost.",
                fallbackPublicURL: cachedURL
            )
        }

        if cachedURL == expectedURL,
           Self.storedUploadFingerprint(for: applicationIdentifier) == uploadFingerprint
        {
            do {
                try await DataStore.shared.upsertIcon(
                    name: appName,
                    url: expectedURL,
                    bundleID: applicationIdentifier
                )
                Self.removeFailedUpload(applicationIdentifier: applicationIdentifier)
                return .cached(publicURL: expectedURL)
            } catch {
                Self.enqueueFailedUpload(
                    applicationIdentifier: applicationIdentifier,
                    appName: appName
                )
                return .failed(
                    message: "The cached application icon could not be updated locally.",
                    fallbackPublicURL: expectedURL
                )
            }
        }

        let uploadedURL: String
        do {
            uploadedURL = try await S3Uploader.uploadIconToS3(
                iconData,
                appName: appName,
                config: configuration
            )
        } catch {
            Self.enqueueFailedUpload(
                applicationIdentifier: applicationIdentifier,
                appName: appName
            )
            return .failed(
                message: error.localizedDescription,
                fallbackPublicURL: cachedURL
            )
        }
        guard let uploadedURL = Self.validatedPublicURL(uploadedURL) else {
            Self.enqueueFailedUpload(
                applicationIdentifier: applicationIdentifier,
                appName: appName
            )
            return .failed(
                message: "The uploaded icon URL is not a secure public URL.",
                fallbackPublicURL: cachedURL
            )
        }

        do {
            try await DataStore.shared.upsertIcon(
                name: appName,
                url: uploadedURL,
                bundleID: applicationIdentifier
            )
        } catch {
            Self.enqueueFailedUpload(
                applicationIdentifier: applicationIdentifier,
                appName: appName
            )
            return .failed(
                message: "The application icon was uploaded, but its URL could not be cached.",
                fallbackPublicURL: uploadedURL
            )
        }

        Self.storeUploadFingerprint(uploadFingerprint, for: applicationIdentifier)
        Self.removeFailedUpload(applicationIdentifier: applicationIdentifier)
        return .uploaded(publicURL: uploadedURL)
    }

    private static func uploadApplications(
        _ applications: [String: String],
        configuration: S3Integration
    ) async -> AssetHostingMaintenanceResult {
        var succeeded = 0
        for (applicationIdentifier, storedName) in applications.sorted(by: { $0.key < $1.key }) {
            guard !Task.isCancelled else { break }
            let appInfo = AppUtility.shared.refreshAppInfo(for: applicationIdentifier)
            let appName = appInfo.path == nil ? storedName : appInfo.displayName
            guard appInfo.path != nil, let iconData = appInfo.icon.data else {
                enqueueFailedUpload(
                    applicationIdentifier: applicationIdentifier,
                    appName: appName
                )
                continue
            }

            do {
                let uploadedURL = try await S3Uploader.uploadIconToS3(
                    iconData,
                    appName: appName,
                    config: configuration
                )
                guard let uploadedURL = validatedPublicURL(uploadedURL) else {
                    throw URLError(.badURL)
                }
                try await DataStore.shared.upsertIcon(
                    name: appName,
                    url: uploadedURL,
                    bundleID: applicationIdentifier
                )
                storeUploadFingerprint(
                    uploadFingerprint(iconData: iconData, config: configuration),
                    for: applicationIdentifier
                )
                removeFailedUpload(applicationIdentifier: applicationIdentifier)
                succeeded += 1
            } catch {
                enqueueFailedUpload(
                    applicationIdentifier: applicationIdentifier,
                    appName: appName
                )
            }
        }
        return AssetHostingMaintenanceResult(
            attempted: applications.count,
            succeeded: succeeded
        )
    }

    private static func uploadFingerprint(iconData: Data, config: S3Integration) -> String {
        // Do not persist credentials. Public routing fields plus the image hash
        // are sufficient to detect a storage target or icon change even when a
        // stable custom domain keeps the resulting public URL unchanged.
        [
            config.bucket,
            config.region,
            config.endpoint,
            config.customDomain,
            config.path,
            iconData.md5(),
        ].joined(separator: "\u{0}").sha256()
    }

    private static func validatedPublicURL(_ value: String) -> String? {
        validatedSecurePublicURL(value)?.absoluteString
    }

    private static func storedUploadFingerprint(for applicationIdentifier: String) -> String? {
        UserDefaults.standard.dictionary(forKey: uploadFingerprintsKey)?[applicationIdentifier]
            as? String
    }

    private static func storeUploadFingerprint(
        _ fingerprint: String,
        for applicationIdentifier: String
    ) {
        var fingerprints = UserDefaults.standard.dictionary(forKey: uploadFingerprintsKey) ?? [:]
        fingerprints[applicationIdentifier] = fingerprint
        UserDefaults.standard.set(fingerprints, forKey: uploadFingerprintsKey)
    }

    private static var failedUploads: [String: String] {
        let stored = UserDefaults.standard.dictionary(forKey: failedUploadsKey) ?? [:]
        return stored.reduce(into: [String: String]()) { result, item in
            if let appName = item.value as? String {
                result[item.key] = appName
            }
        }
    }

    private static func enqueueFailedUpload(
        applicationIdentifier: String,
        appName: String
    ) {
        var uploads = failedUploads
        guard uploads[applicationIdentifier] != appName else { return }
        uploads[applicationIdentifier] = appName
        updateFailedUploads(uploads)
    }

    private static func removeFailedUpload(applicationIdentifier: String) {
        var uploads = failedUploads
        guard uploads.removeValue(forKey: applicationIdentifier) != nil else { return }
        updateFailedUploads(uploads)
    }

    private static func updateFailedUploads(_ uploads: [String: String]) {
        let previous = failedUploads
        guard previous != uploads else { return }
        if uploads.isEmpty {
            UserDefaults.standard.removeObject(forKey: failedUploadsKey)
        } else {
            UserDefaults.standard.set(uploads, forKey: failedUploadsKey)
        }
        NotificationCenter.default.post(
            name: .assetHostingFailedUploadsDidChange,
            object: nil
        )
    }
}

extension S3Uploader {
    private static func configuredUploader(_ config: S3Integration) -> (S3Uploader, String) {
        let options = S3UploaderOptions(
            bucket: config.bucket,
            region: config.region,
            accessKey: config.accessKey,
            secretKey: config.secretKey,
            endpoint: config.endpoint.isEmpty ? nil : config.endpoint,
            customDomain: config.customDomain.isEmpty ? nil : config.customDomain
        )
        let configuredPath = config.path.trimmingCharacters(in: .whitespacesAndNewlines)
        return (S3Uploader(options: options), configuredPath.isEmpty ? "app-icons" : configuredPath)
    }

    static func publicIconURL(
        _ imageData: Data,
        config: S3Integration
    ) throws -> String {
        let (uploader, path) = configuredUploader(config)
        return try uploader.publicImageURL(imageData, to: path)
    }

    static func uploadIconToS3(
        _ imageData: Data,
        appName _: String,
        config: S3Integration
    ) async throws -> String {
        let (uploader, path) = configuredUploader(config)
        return try await uploader.uploadImage(imageData, to: path)
    }
}
