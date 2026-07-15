//
//  Reporter+S3.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/14.
//

import Foundation

class S3ReporterExtension: ReporterExtension {
    private static let uploadFingerprintsKey = "s3UploadedIconFingerprints"

    var name: String = "S3"

    var isEnabled: Bool {
        return PreferencesDataModel.shared.s3Integration.value.isEnabled
    }

    func createReporterOptions() -> ReporterOptions {
        return ReporterOptions(
            priority: 0,
            onSend: { data in
                let config = PreferencesDataModel.shared.s3Integration.value
                if !config.isEnabled {
                    return .failure(.ignored)
                }

                guard let nsImage = data.processInfoRaw?.icon, let iconData = nsImage.data,
                    let applicationIdentifier = data.processInfoRaw?.applicationIdentifier
                else {
                    // Media-only and filtered-process reports legitimately have no
                    // process icon to enrich.
                    return .failure(.ignored)
                }

                guard let appName = data.processName, !appName.isEmpty else {
                    return .failure(.ignored)
                }

                let expectedURL: String
                let uploadFingerprint = Self.uploadFingerprint(
                    iconData: iconData,
                    config: config
                )
                do {
                    expectedURL = try S3Uploader.publicIconURL(
                        iconData,
                        config: config
                    )
                } catch let error as S3UploaderError {
                    return .failure(.cancelled(message: error.localizedDescription))
                } catch {
                    return .failure(.cancelled(message: error.localizedDescription))
                }

                if await DataStore.shared.iconURL(for: applicationIdentifier) == expectedURL,
                    Self.storedUploadFingerprint(for: applicationIdentifier) == uploadFingerprint
                {
                    // Keep the display name current even when no upload is needed.
                    do {
                        try await DataStore.shared.upsertIcon(
                            name: appName,
                            url: expectedURL,
                            bundleID: applicationIdentifier
                        )
                    } catch {
                        return .failure(.databaseError(error.localizedDescription))
                    }
                    return .success(())
                }

                let url: String
                do {
                    url = try await S3Uploader.uploadIconToS3(
                        iconData,
                        appName: appName,
                        config: config
                    )
                } catch let error as S3UploaderError {
                    switch error {
                    case .uploadFailed:
                        return .failure(.networkError(error.localizedDescription))
                    case .missingConfiguration, .invalidEndpoint, .insecureEndpoint,
                        .invalidObjectKey:
                        return .failure(.cancelled(message: error.localizedDescription))
                    }
                } catch {
                    return .failure(.networkError(error.localizedDescription))
                }

                do {
                    try await DataStore.shared.upsertIcon(
                        name: appName,
                        url: url,
                        bundleID: applicationIdentifier
                    )
                } catch {
                    print("Failed to save icon model: \(error)")
                    return .failure(.databaseError(error.localizedDescription))
                }
                Self.storeUploadFingerprint(
                    uploadFingerprint,
                    for: applicationIdentifier
                )

                return .success(())
            }
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
