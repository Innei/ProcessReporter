//
//  Reporter+MixSpace.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/10.
//

import Alamofire
import Foundation

private struct MixSpaceDataPayload: Codable {
    struct MediaInfo: Codable {
        var artist: String?
        var title: String?
        var duration: Double?
        var elapsedTime: Double?
        var processName: String?
    }

    struct ProcessInfo: Codable {
        let iconBase64: String?
        let iconUrl: String?
        let description: String?
        let name: String?
    }

    let media: MediaInfo?
    let key: String
    let timestamp: UInt
    let process: ProcessInfo

    init(process: ProcessInfo, media: MediaInfo?, key: String, observedAt: Date) {
        self.media = media
        self.process = process
        self.key = key
        timestamp = UInt(max(0, Int(observedAt.timeIntervalSince1970)))
    }

    var deliveryOutputSummary: SyncOutputSummary {
        let mediaDetail = [media?.title, media?.artist, media?.processName]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " — ")
        return SyncOutputSummary(
            title: process.name,
            subtitle: process.description,
            detail: mediaDetail.isEmpty ? nil : mediaDetail,
            activityKind: "presence"
        )
    }
}

private let descriptionDictionary: [String: String] = [
    "Xcode": "编辑",
    "Code": "编辑",
    "Cursor": "编辑",

    "Capture One": "调色",
]

@MainActor
private func sendMixSpaceRequest(
    data: ReportModel,
    assetResolution: PresenceAssetResolution
) async -> ReporterDeliveryResult {
    let config = PreferencesDataModel.shared.mixSpaceIntegration.value
    let endpoint = config.endpoint
    let method = config.requestMethod
    let token = config.apiToken

    guard !token.isEmpty else {
        return .failure(.unknown(message: "Missing MixSpace API token", successIntegrations: []))
    }
    guard let components = URLComponents(string: endpoint),
        let scheme = components.scheme?.lowercased(),
        (scheme == "https" || scheme == "http"),
        let host = components.host,
        components.user == nil,
        components.password == nil,
        let endpointURL = components.url
    else {
        return .failure(.cancelled(message: "Invalid MixSpace HTTP endpoint"))
    }
    guard scheme == "https" || isLoopbackHost(host) else {
        return .failure(
            .cancelled(message: "MixSpace API tokens require HTTPS except on localhost")
        )
    }

    let iconURL = assetResolution.publicURL

    var description: String?

    if let processName = data.processName {
        if let prefix = descriptionDictionary[processName],
            let title = data.windowTitle
        {
            description = prefix + "\n" + title
        }
    }

    let requestPayload = MixSpaceDataPayload(
        process: .init(
            iconBase64: nil, iconUrl: iconURL, description: description, name: data.processName),
        media: .init(
            artist: data.artist,
            title: data.mediaName,
            duration: data.mediaDuration,
            elapsedTime: data.mediaElapsedTime,
            processName: data.mediaProcessName
        ),
        key: token,
        observedAt: data.timeStamp
    )

    let headers: HTTPHeaders = [
        "Content-Type": "application/json"
    ]

    do {
        let request = AF.request(
            endpointURL,
            method: .init(rawValue: method.uppercased()),
            parameters: requestPayload,
            encoder: JSONParameterEncoder.default,
            headers: headers,
            requestModifier: { request in
                request.timeoutInterval = 10
            }
        )
        .validate()
        _ = try await withTaskCancellationHandler(
            operation: {
                try await request.serializingData().value
            },
            onCancel: {
                request.cancel()
            }
        )
        try Task.checkCancellation()

        return .success(
            ReporterDeliveryReceipt(outputSummary: requestPayload.deliveryOutputSummary)
        )
    } catch {
        NSLog(
            "MixSpace request failed: \(error.asAFError?.localizedDescription ?? error.localizedDescription)"
        )
        return .failure(.networkError(error.localizedDescription))
    }
}

class MixSpaceReporterExtension: ReporterExtension {
    var name: String = "MixSpace"

    var isEnabled: Bool {
        return PreferencesDataModel.shared.mixSpaceIntegration.value.isEnabled
    }

    func createReporterOptions() -> ReporterOptions {
        return ReporterOptions(
            assetCapability: .optionalPublicURL,
            onSendWithAsset: { data, assetResolution in
                if !PreferencesDataModel.shared.mixSpaceIntegration.value.isEnabled {
                    return .failure(.ignored)
                }

                return await sendMixSpaceRequest(
                    data: data,
                    assetResolution: assetResolution
                )
            }
        )
    }
}
