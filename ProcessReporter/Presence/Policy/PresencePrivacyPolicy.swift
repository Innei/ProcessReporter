import Foundation

enum PresencePrivacyDefault: String, Codable, CaseIterable, Sendable {
    case share
    case hide

    var isShared: Bool { self == .share }

    var displayName: String { rawValue.capitalized }
}

enum PresencePrivacyOverride: String, Codable, CaseIterable, Sendable {
    case inherit
    case share
    case hide

    func resolve(default fallback: PresencePrivacyDefault) -> PresencePrivacyDefault {
        switch self {
        case .inherit:
            return fallback
        case .share:
            return .share
        case .hide:
            return .hide
        }
    }

    var displayName: String {
        switch self {
        case .inherit:
            return "Use Global Default"
        case .share:
            return "Share"
        case .hide:
            return "Hide"
        }
    }
}

struct PresencePrivacyDefaults: Codable, Equatable, Sendable {
    var application: PresencePrivacyDefault
    var windowTitle: PresencePrivacyDefault
    var media: PresencePrivacyDefault

    static let newInstallation = PresencePrivacyDefaults(
        application: .share,
        windowTitle: .hide,
        media: .share
    )
}

struct ApplicationPresenceRule: Codable, Equatable, Identifiable, Sendable {
    var id: String { applicationIdentifier }

    let applicationIdentifier: String
    var application: PresencePrivacyOverride
    var windowTitle: PresencePrivacyOverride
    var media: PresencePrivacyOverride
    var displayAlias: String?

    static func empty(applicationIdentifier: String) -> ApplicationPresenceRule {
        ApplicationPresenceRule(
            applicationIdentifier: applicationIdentifier,
            application: .inherit,
            windowTitle: .inherit,
            media: .inherit,
            displayAlias: nil
        )
    }

    var normalized: ApplicationPresenceRule {
        var copy = self
        let alias = displayAlias?.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.displayAlias = alias?.isEmpty == false ? alias : nil
        return copy
    }

    var isEmpty: Bool {
        application == .inherit
            && windowTitle == .inherit
            && media == .inherit
            && normalized.displayAlias == nil
    }
}

struct PresencePrivacyConfiguration: Codable, Equatable, Sendable, UserDefaultsJSONStorable {
    var defaults: PresencePrivacyDefaults
    var rules: [ApplicationPresenceRule]

    static let newInstallation = PresencePrivacyConfiguration(
        defaults: .newInstallation,
        rules: []
    )

    func rule(for applicationIdentifier: String) -> ApplicationPresenceRule? {
        rules.first { $0.applicationIdentifier == applicationIdentifier }
    }
}

struct ProcessPrivacyDecision: Equatable, Sendable {
    let sharesApplication: Bool
    let sharesWindowTitle: Bool
    let displayAlias: String?
}

struct MediaPrivacyDecision: Equatable, Sendable {
    let sharesMedia: Bool
    let displayAlias: String?
}

struct PresencePrivacyEvaluator: Sendable {
    let configuration: PresencePrivacyConfiguration
    let legacyHiddenApplications: Set<String>
    let legacyHiddenMediaApplications: Set<String>
    let legacyHiddenMediaNames: Set<String>

    func processDecision(applicationIdentifier: String) -> ProcessPrivacyDecision {
        let rule = configuration.rule(for: applicationIdentifier)
            ?? .empty(applicationIdentifier: applicationIdentifier)
        let applicationIsHidden = legacyHiddenApplications.contains(applicationIdentifier)
            || rule.application.resolve(default: configuration.defaults.application) == .hide
        let windowIsShared = rule.windowTitle.resolve(
            default: configuration.defaults.windowTitle
        ).isShared

        return ProcessPrivacyDecision(
            sharesApplication: !applicationIsHidden,
            sharesWindowTitle: !applicationIsHidden && windowIsShared,
            displayAlias: applicationIsHidden ? nil : rule.normalized.displayAlias
        )
    }

    func mediaDecision(
        applicationIdentifier: String?,
        processName: String
    ) -> MediaPrivacyDecision {
        let rule = applicationIdentifier.flatMap(configuration.rule(for:))
        let mediaIsHiddenByLegacy = applicationIdentifier.map {
            legacyHiddenMediaApplications.contains($0)
        } ?? legacyHiddenMediaNames.contains(processName)
        let mediaIsHidden = mediaIsHiddenByLegacy
            || (rule?.media.resolve(default: configuration.defaults.media)
                ?? configuration.defaults.media) == .hide

        return MediaPrivacyDecision(
            sharesMedia: !mediaIsHidden,
            displayAlias: mediaIsHidden ? nil : rule?.normalized.displayAlias
        )
    }
}

