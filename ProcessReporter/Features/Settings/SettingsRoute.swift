import AppKit
import Foundation

enum SettingsSection: String, CaseIterable, Codable, Identifiable {
    case general
    case destinations
    case privacyRules
    case syncHistory
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .destinations: return "Destinations"
        case .privacyRules: return "Privacy & Rules"
        case .syncHistory: return "Sync History"
        case .advanced: return "Advanced"
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .destinations: return "dot.radiowaves.left.and.right"
        case .privacyRules: return "hand.raised"
        case .syncHistory: return "clock.arrow.circlepath"
        case .advanced: return "slider.horizontal.3"
        }
    }
}

enum SettingsDestination: String, Hashable, Identifiable {
    case mixSpace
    case slack
    case discord
    case applicationIconHosting

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mixSpace: return "MixSpace"
        case .slack: return "Slack"
        case .discord: return "Discord"
        case .applicationIconHosting: return "Application Icon Hosting"
        }
    }

    var subtitle: String {
        switch self {
        case .mixSpace:
            return "Publish application and media presence to MixSpace."
        case .slack:
            return "Keep your Slack status synchronized with your current activity."
        case .discord:
            return "Publish local Discord Rich Presence."
        case .applicationIconHosting:
            return "S3-compatible storage"
        }
    }

    var assetName: String {
        switch self {
        case .mixSpace: return "mx-space"
        case .slack: return "slack"
        case .discord: return "discord"
        case .applicationIconHosting: return "s3"
        }
    }

    var fallbackSymbolName: String {
        switch self {
        case .mixSpace: return "network"
        case .slack: return "number"
        case .discord: return "bubble.left.and.bubble.right"
        case .applicationIconHosting: return "externaldrive.badge.icloud"
        }
    }

    var presenceDestinationID: PresenceDestinationID? {
        switch self {
        case .mixSpace: return .mixSpace
        case .slack: return .slack
        case .discord: return .discord
        case .applicationIconHosting: return nil
        }
    }

    @MainActor
    var image: NSImage {
        NSImage(named: assetName)
            ?? NSImage(systemSymbolName: fallbackSymbolName, accessibilityDescription: title)
            ?? NSImage()
    }
}

enum SettingsRoute: Hashable {
    case section(SettingsSection)
    case destination(SettingsDestination)
    case privacyRules(applicationIdentifier: String?)
}

struct SettingsConfigurationStatus: Equatable {
    let isConfigured: Bool
    let isValid: Bool
    let isEnabled: Bool
    let isLoadingCredentials: Bool

    var title: String {
        if isLoadingCredentials {
            return "Loading Credentials"
        }
        if !isConfigured {
            return "Not Configured"
        }
        if !isValid {
            return "Needs Attention"
        }
        return isEnabled ? "Enabled" : "Configured"
    }

    var symbolName: String {
        if isLoadingCredentials {
            return "ellipsis.circle"
        }
        if !isConfigured {
            return "circle.dashed"
        }
        if !isValid {
            return "exclamationmark.circle"
        }
        return isEnabled ? "checkmark.circle.fill" : "checkmark.circle"
    }
}
