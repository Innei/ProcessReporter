import Foundation

enum SyncEventKind: String, Codable, Sendable {
    case standard
    case legacy
    case unreadable
}

enum SyncEventTrigger: String, Codable, CaseIterable, Sendable {
    case interval
    case focusChanged
    case mediaChanged
    case settingsChanged
    case unknown

    var displayName: String {
        switch self {
        case .interval:
            return "Delivery interval"
        case .focusChanged:
            return "Application focus changed"
        case .mediaChanged:
            return "Media playback changed"
        case .settingsChanged:
            return "Presence settings changed"
        case .unknown:
            return "Unknown"
        }
    }
}

enum SyncDeliveryStatus: String, Codable, CaseIterable, Sendable {
    case succeeded
    case failed
    case skipped
    case unknown

    var displayName: String {
        rawValue.capitalized
    }
}

enum SyncAssetStatus: String, Codable, Sendable {
    case notRequested
    case notConfigured
    case cached
    case uploaded
    case failed
    case legacySucceeded

    var displayName: String {
        switch self {
        case .notRequested:
            return "Not Requested"
        case .notConfigured:
            return "Not Configured"
        case .cached:
            return "Cached"
        case .uploaded:
            return "Uploaded"
        case .failed:
            return "Failed"
        case .legacySucceeded:
            return "Legacy Success"
        }
    }
}

enum SyncAggregateResult: String, Codable, CaseIterable, Sendable {
    case succeeded
    case partial
    case failed
    case skipped
    case legacy
    case unreadable

    var displayName: String {
        rawValue.capitalized
    }
}

struct SyncOutputSummary: Codable, Equatable, Sendable {
    let title: String?
    let subtitle: String?
    let detail: String?
    let activityKind: String?
}

struct SyncDeliveryResult: Codable, Equatable, Identifiable, Sendable {
    let destinationID: String
    let destinationDisplayName: String?
    let status: SyncDeliveryStatus
    let startedAt: Date?
    let finishedAt: Date?
    let outputSummary: SyncOutputSummary?
    let errorCode: String?
    let message: String?

    var id: String { destinationID }

    var durationMilliseconds: Int? {
        guard let startedAt, let finishedAt else { return nil }
        return max(0, Int(finishedAt.timeIntervalSince(startedAt) * 1_000))
    }

    var displayName: String {
        if let destinationDisplayName, !destinationDisplayName.isEmpty {
            return destinationDisplayName
        }
        return PresenceDestinationID(rawValue: destinationID)?.displayName ?? destinationID
    }
}

struct SyncAssetResult: Codable, Equatable, Sendable {
    let status: SyncAssetStatus
    let usedFallback: Bool
    let errorCode: String?
    let message: String?
}

struct StoredSyncEventPayload: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let trigger: SyncEventTrigger
    let assetResult: SyncAssetResult
    let deliveryResults: [SyncDeliveryResult]

    init(
        formatVersion: Int = Self.currentFormatVersion,
        trigger: SyncEventTrigger,
        assetResult: SyncAssetResult,
        deliveryResults: [SyncDeliveryResult]
    ) {
        self.formatVersion = formatVersion
        self.trigger = trigger
        self.assetResult = assetResult
        self.deliveryResults = deliveryResults
    }
}

enum DecodedSyncPayload: Equatable, Sendable {
    case modern(StoredSyncEventPayload)
    case legacy([String])
    case unreadable
}

enum SyncEventPayloadCodec {
    static func decode(_ data: Data?) -> DecodedSyncPayload {
        guard let data else { return .legacy([]) }

        if let payload = try? JSONDecoder().decode(StoredSyncEventPayload.self, from: data) {
            guard payload.formatVersion == StoredSyncEventPayload.currentFormatVersion else {
                return .unreadable
            }
            return .modern(payload)
        }

        if let integrations = try? JSONDecoder().decode([String].self, from: data) {
            return .legacy(integrations)
        }

        return .unreadable
    }

    static func encode(_ payload: StoredSyncEventPayload) throws -> Data {
        try JSONEncoder().encode(payload)
    }
}

struct SyncPresenceSnapshot: Codable, Equatable, Sendable {
    let applicationDisplayName: String?
    let windowTitle: String?
    let mediaTitle: String?
    let mediaArtist: String?
    let mediaApplicationName: String?
    let mediaDuration: Double?
    let mediaElapsedTime: Double?
}

struct SyncEventValue: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let capturedAt: Date
    let kind: SyncEventKind
    let snapshot: SyncPresenceSnapshot
    let trigger: SyncEventTrigger
    let assetResult: SyncAssetResult?
    let deliveryResults: [SyncDeliveryResult]

    var aggregateResult: SyncAggregateResult {
        switch kind {
        case .legacy:
            return .legacy
        case .unreadable:
            return .unreadable
        case .standard:
            break
        }

        let statuses = deliveryResults.map(\.status)
        let hasSuccess = statuses.contains(.succeeded)
        let hasFailure = statuses.contains(.failed)
        let assetFailed = assetResult?.status == .failed

        if hasSuccess, hasFailure || assetFailed {
            return .partial
        }
        if hasFailure {
            return .failed
        }
        if hasSuccess {
            return .succeeded
        }
        return .skipped
    }
}

extension ReportValue {
    var syncEventValue: SyncEventValue {
        let snapshot = SyncPresenceSnapshot(
            applicationDisplayName: processName,
            windowTitle: windowTitle,
            mediaTitle: mediaName,
            mediaArtist: artist,
            mediaApplicationName: mediaProcessName,
            mediaDuration: mediaDuration,
            mediaElapsedTime: mediaElapsedTime
        )

        switch decodedSyncPayload {
        case .modern(let payload):
            return SyncEventValue(
                id: id,
                capturedAt: timeStamp,
                kind: .standard,
                snapshot: snapshot,
                trigger: payload.trigger,
                assetResult: payload.assetResult,
                deliveryResults: payload.deliveryResults
            )
        case .legacy(let legacyIntegrations):
            return SyncEventValue(
                id: id,
                capturedAt: timeStamp,
                kind: .legacy,
                snapshot: snapshot,
                trigger: .unknown,
                assetResult: Self.legacyAssetResult(from: legacyIntegrations),
                deliveryResults: Self.legacyDeliveryResults(
                    from: legacyIntegrations,
                    capturedAt: timeStamp
                )
            )
        case .unreadable:
            return SyncEventValue(
                id: id,
                capturedAt: timeStamp,
                kind: .unreadable,
                snapshot: snapshot,
                trigger: .unknown,
                assetResult: nil,
                deliveryResults: []
            )
        }
    }

    private static func legacyAssetResult(from integrations: [String]) -> SyncAssetResult? {
        guard integrations.contains(where: { $0.caseInsensitiveCompare("S3") == .orderedSame })
        else { return nil }
        return SyncAssetResult(
            status: .legacySucceeded,
            usedFallback: false,
            errorCode: nil,
            message: "Recorded by an earlier ProcessReporter version."
        )
    }

    private static func legacyDeliveryResults(
        from integrations: [String],
        capturedAt: Date
    ) -> [SyncDeliveryResult] {
        let nonAssetNames = integrations.filter {
            $0.caseInsensitiveCompare("S3") != .orderedSame
        }
        let recordedDestinationIDs = Set(
            nonAssetNames.compactMap { PresenceDestinationID(reporterName: $0) }
        )

        var results = PresenceDestinationID.allCases.map { destination in
            SyncDeliveryResult(
                destinationID: destination.rawValue,
                destinationDisplayName: destination.displayName,
                status: recordedDestinationIDs.contains(destination) ? .succeeded : .unknown,
                startedAt: capturedAt,
                finishedAt: capturedAt,
                outputSummary: nil,
                errorCode: nil,
                message: nil
            )
        }

        let unknownNames = nonAssetNames.filter {
            PresenceDestinationID(reporterName: $0) == nil
        }
        for (index, name) in unknownNames.enumerated() {
            results.append(
                SyncDeliveryResult(
                    destinationID: "legacy-\(index)-\(name.lowercased())",
                    destinationDisplayName: name,
                    status: .succeeded,
                    startedAt: capturedAt,
                    finishedAt: capturedAt,
                    outputSummary: nil,
                    errorCode: nil,
                    message: nil
                )
            )
        }
        return results
    }
}
