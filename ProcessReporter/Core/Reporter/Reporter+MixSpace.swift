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

    init(process: ProcessInfo, media: MediaInfo?, key: String) {
        self.media = media
        self.process = process
        self.key = key
        timestamp = UInt(Int(Date().timeIntervalSince1970))
    }
}

private let descriptionDictionary: [String: String] = [
    "Xcode": "编辑",
    "Code": "编辑",
    "Cursor": "编辑",

    "Capture One": "调色",
]

private func isLoopbackHost(_ host: String) -> Bool {
    let normalized = host.lowercased()
    return normalized == "localhost" || normalized == "::1" || normalized.hasPrefix("127.")
}

@MainActor
private func sendMixSpaceRequest(data: ReportModel) async -> Result<Void, ReporterError> {
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

    let iconUrl = await DataStore.shared.iconURL(for: data.processInfoRaw?.applicationIdentifier ?? "")

    var description: String?

    if let processName = data.processName {
        if let prefix = descriptionDictionary[processName],
            let title = data.processInfoRaw?.title
        {
            description = prefix + "\n" + title
        }
    }

    let requestPayload = MixSpaceDataPayload(
        process: .init(
            iconBase64: nil, iconUrl: iconUrl, description: description, name: data.processName),
        media: .init(
            artist: data.artist,
            title: data.mediaName,
            duration: data.mediaDuration,
            elapsedTime: data.mediaElapsedTime,
            processName: data.mediaProcessName
        ),
        key: token
    )

    let headers: HTTPHeaders = [
        "Content-Type": "application/json"
    ]

    do {
        _ = try await AF.request(
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
        .serializingData()
        .value

        return .success(())
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
            onSend: { data in
                if !PreferencesDataModel.shared.mixSpaceIntegration.value.isEnabled {
                    return .failure(.ignored)
                }

                return await sendMixSpaceRequest(data: data)
            }
        )
    }
}
