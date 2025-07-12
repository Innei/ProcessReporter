//
//  Reporter+S3.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/14.
//

import Foundation
import SwiftData

class S3ReporterExtension: ReporterExtension {
    var name: String = "S3"

    var isEnabled: Bool {
        return PreferencesDataModel.shared.s3Integration.value.isEnabled
    }

    func createReporterOptions() -> ReporterOptions {
        return ReporterOptions(
            onSend: { data in
                if !PreferencesDataModel.shared.s3Integration.value.isEnabled {
                    return .failure(.ignored)
                }

                guard let nsImage = data.processInfoRaw?.icon, let iconData = nsImage.data,
                    let applicationIdentifier = data.processInfoRaw?.applicationIdentifier
                else {
                    return .failure(.cancelled(message: "S3: No icon data"))
                }

                let icon = await IconModel.findIcon(for: applicationIdentifier)
                if icon != nil {
                    return .success(())
                }

                guard let appName = data.processName, !appName.isEmpty,
                    let url = try? await S3Uploader.uploadIconToS3(
                        iconData, appName: appName
                    )
                else {
                    return .failure(.networkError("Upload failed"))
                }

                // Use the new findOrCreate method
                do {
                    _ = try await IconModel.findOrCreate(
                        name: appName,
                        url: url,
                        bundleID: applicationIdentifier
                    )
                } catch {
                    print("Failed to save icon model: \(error)")
                    return .failure(.databaseError(error.localizedDescription))
                }

                return .success(())
            }
        )
    }
}

extension S3Uploader {
    static func uploadIconToS3(_ imageData: Data, appName: String) async throws -> String {
        let config = PreferencesDataModel.s3Integration.value

        // Create S3Uploader
        let options = S3UploaderOptions(
            bucket: config.bucket,
            region: config.region,
            accessKey: config.accessKey,
            secretKey: config.secretKey,
            endpoint: config.endpoint.isEmpty ? nil : config.endpoint
        )

        let uploader = S3Uploader(options: options)

        return try await uploader.uploadImage(imageData, to: "app-icons")
    }
}
