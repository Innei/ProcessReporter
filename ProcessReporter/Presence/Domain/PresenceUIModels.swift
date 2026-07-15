import AppKit
import Foundation

enum PresenceDestinationID: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case mixSpace = "mixspace"
    case slack
    case discord

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mixSpace:
            return "MixSpace"
        case .slack:
            return "Slack"
        case .discord:
            return "Discord"
        }
    }

    var assetName: String {
        switch self {
        case .mixSpace:
            return "mx-space"
        case .slack:
            return "slack"
        case .discord:
            return "discord"
        }
    }

    init?(reporterName: String) {
        switch reporterName.lowercased() {
        case "mixspace", "mix space":
            self = .mixSpace
        case "slack":
            self = .slack
        case "discord":
            self = .discord
        default:
            return nil
        }
    }
}

enum PresenceAssetCapability: Equatable, Sendable {
    case unsupported
    case optionalPublicURL
    case requiredPublicURL
}

enum PresenceDestinationConfigurationState: Equatable, Sendable {
    case notConfigured
    case disabled
    case ready
    case invalid

    var displayText: String {
        switch self {
        case .notConfigured:
            return "Not Configured"
        case .disabled:
            return "Disabled"
        case .ready:
            return "Ready"
        case .invalid:
            return "Needs Attention"
        }
    }
}

enum PresenceDeliveryState: Equatable, Sendable {
    case never
    case sending
    case succeeded(Date)
    case failed(message: String, date: Date)
    case skipped(message: String?, date: Date)

    var displayText: String {
        switch self {
        case .never:
            return "Ready"
        case .sending:
            return "Syncing"
        case .succeeded:
            return "Synced"
        case .failed:
            return "Failed"
        case .skipped:
            return "Skipped"
        }
    }

    var eventDate: Date? {
        switch self {
        case .succeeded(let date), .failed(_, let date), .skipped(_, let date):
            return date
        case .never, .sending:
            return nil
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    var isSuccess: Bool {
        if case .succeeded = self { return true }
        return false
    }
}

struct PresenceDestinationDeliveryResult: Identifiable, Equatable, Sendable {
    let id: PresenceDestinationID
    let state: PresenceDeliveryState
}

enum PresenceAssetResolution: Equatable, Sendable {
    case notRequested
    case notConfigured
    case cached(publicURL: String)
    case uploaded(publicURL: String)
    case failed(message: String, fallbackPublicURL: String?)

    var publicURL: String? {
        switch self {
        case .cached(let publicURL), .uploaded(let publicURL):
            return publicURL
        case .failed(_, let fallbackPublicURL):
            return fallbackPublicURL
        case .notRequested, .notConfigured:
            return nil
        }
    }

    var failureMessage: String? {
        if case .failed(let message, _) = self { return message }
        return nil
    }

    var isFailure: Bool {
        failureMessage != nil
    }
}

struct PresenceDestinationPresentation: Identifiable, Equatable, Sendable {
    let id: PresenceDestinationID
    let configurationState: PresenceDestinationConfigurationState
    let deliveryState: PresenceDeliveryState
}

enum PresenceAggregateStatus: Equatable, Sendable {
    case setupRequired
    case paused
    case idle
    case ready
    case syncing
    case degraded
    case error

    var displayText: String {
        switch self {
        case .setupRequired:
            return "Finish setup to start sharing"
        case .paused:
            return "Presence sharing is paused"
        case .idle:
            return "Nothing to share"
        case .ready:
            return "Sharing is active"
        case .syncing:
            return "Syncing presence…"
        case .degraded:
            return "Shared with some issues"
        case .error:
            return "Presence could not be shared"
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .setupRequired:
            return "setup required"
        case .paused:
            return "sharing paused"
        case .idle:
            return "nothing to share"
        case .ready:
            return "sharing active"
        case .syncing:
            return "syncing"
        case .degraded:
            return "sharing with issues"
        case .error:
            return "sharing failed"
        }
    }
}

enum PresenceRuntimeStatus: Equatable, Sendable {
    case ready
    case syncing
    case waitingForNetwork
    case paused
}

@MainActor
struct PresencePresentation {
    let capturedAt: Date
    let applicationName: String?
    let applicationIdentifier: String?
    let applicationIcon: NSImage?
    let windowTitle: String?
    let mediaTitle: String?
    let mediaArtist: String?
    let mediaArtwork: NSImage?
    let mediaIsPlaying: Bool

    var hasApplication: Bool {
        applicationName?.isEmpty == false
    }

    var hasMedia: Bool {
        mediaTitle?.isEmpty == false
    }

    init?(report: ReportModel) {
        let hasApplication = report.processName?.isEmpty == false
        let hasMedia = report.mediaName?.isEmpty == false
        guard hasApplication || hasMedia else { return nil }

        capturedAt = report.timeStamp
        applicationName = report.processName
        applicationIdentifier = report.sourceProcessApplicationIdentifier
            ?? report.processInfoRaw?.applicationIdentifier
        applicationIcon = report.processInfoRaw?.icon
        windowTitle = report.windowTitle
        mediaTitle = report.mediaName
        mediaArtist = report.artist
        mediaIsPlaying = report.mediaInfoRaw?.playing ?? false

        if let encodedArtwork = report.mediaInfoRaw?.image,
           let artworkData = Data(base64Encoded: encodedArtwork)
        {
            mediaArtwork = NSImage(data: artworkData)
        } else {
            mediaArtwork = nil
        }
    }
}
