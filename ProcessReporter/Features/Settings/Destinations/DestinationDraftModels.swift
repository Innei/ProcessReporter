import Foundation

enum DestinationCredentialIntent: Equatable {
    case unchanged
    case replace
    case remove
}

struct DestinationCredentialDraft: Equatable {
    let hadStoredValue: Bool
    var intent: DestinationCredentialIntent = .unchanged
    var replacement = ""

    init(hadStoredValue: Bool) {
        self.hadStoredValue = hadStoredValue
        intent = hadStoredValue ? .unchanged : .replace
    }

    var hasEffectiveValue: Bool {
        switch intent {
        case .unchanged:
            return hadStoredValue
        case .replace:
            return !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .remove:
            return false
        }
    }

    var hasIncompleteStoredReplacement: Bool {
        hadStoredValue
            && intent == .replace
            && replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    mutating func beginReplacement() {
        intent = .replace
        replacement = ""
    }

    mutating func remove() {
        intent = .remove
        replacement = ""
    }

    mutating func keepStoredValue() {
        intent = .unchanged
        replacement = ""
    }

    func resolvedValue(previousValue: String) -> String {
        switch intent {
        case .unchanged:
            return previousValue
        case .replace:
            return replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        case .remove:
            return ""
        }
    }
}

struct MixSpaceDestinationDraft: Equatable {
    var isEnabled: Bool
    var endpoint: String
    var requestMethod: String
    var token: DestinationCredentialDraft

    init(integration: MixSpaceIntegration) {
        isEnabled = integration.isEnabled
        endpoint = integration.endpoint
        requestMethod = integration.requestMethod
        token = DestinationCredentialDraft(hadStoredValue: !integration.apiToken.isEmpty)
    }

    func applying(to previous: MixSpaceIntegration) -> MixSpaceIntegration {
        MixSpaceIntegration(
            isEnabled: isEnabled,
            apiToken: token.resolvedValue(previousValue: previous.apiToken),
            endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
            requestMethod: requestMethod.uppercased()
        )
    }
}

struct SlackEmojiConditionDraft: Identifiable, Equatable {
    let id: UUID
    var variable: String
    var comparison: String
    var value: String
    var emoji: String
    var legacyExpression: String?

    init(
        id: UUID = UUID(),
        variable: String = EmojiConditionList.EmojiCondition.Variable.processName.rawValue,
        comparison: String = EmojiConditionList.EmojiCondition.Condition.contains.rawValue,
        value: String = "",
        emoji: String = "",
        legacyExpression: String? = nil
    ) {
        self.id = id
        self.variable = variable
        self.comparison = comparison
        self.value = value
        self.emoji = emoji
        self.legacyExpression = legacyExpression
    }

    init(condition: EmojiConditionList.EmojiCondition) {
        id = UUID()
        emoji = condition.emoji
        if let parsed = EmojiConditionList.EmojiCondition.parseWhenString(for: condition.when) {
            variable = parsed.variable.rawValue
            comparison = parsed.condition.rawValue
            value = parsed.value
            legacyExpression = nil
        } else {
            variable = EmojiConditionList.EmojiCondition.Variable.processName.rawValue
            comparison = EmojiConditionList.EmojiCondition.Condition.contains.rawValue
            value = ""
            legacyExpression = condition.when
        }
    }

    var whenExpression: String {
        if let legacyExpression { return legacyExpression }
        return "{\(variable)} \(comparison) \"\(value)\""
    }

    mutating func convertLegacyExpression() {
        legacyExpression = nil
    }
}

struct SlackDestinationDraft: Equatable {
    var isEnabled: Bool
    var token: DestinationCredentialDraft
    var globalCustomEmoji: String
    var statusTextTemplateString: String
    var expiration: Int
    var defaultEmoji: String
    var defaultStatusText: String
    var conditions: [SlackEmojiConditionDraft]

    init(integration: SlackIntegration) {
        isEnabled = integration.isEnabled
        token = DestinationCredentialDraft(hadStoredValue: !integration.apiToken.isEmpty)
        globalCustomEmoji = integration.globalCustomEmoji
        statusTextTemplateString = integration.statusTextTemplateString
        expiration = integration.expiration
        defaultEmoji = integration.defaultEmoji
        defaultStatusText = integration.defaultStatusText
        conditions = integration.customEmojiConditionList.getConditions().map(
            SlackEmojiConditionDraft.init(condition:)
        )
    }

    func applying(to previous: SlackIntegration) -> SlackIntegration {
        SlackIntegration(
            isEnabled: isEnabled,
            apiToken: token.resolvedValue(previousValue: previous.apiToken),
            globalCustomEmoji: globalCustomEmoji,
            statusTextTemplateString: statusTextTemplateString,
            expiration: expiration,
            defaultEmoji: defaultEmoji,
            defaultStatusText: defaultStatusText,
            customEmojiConditionList: EmojiConditionList(
                conditions: conditions.compactMap { condition in
                    let when = condition.whenExpression.trimmingCharacters(in: .whitespacesAndNewlines)
                    let emoji = condition.emoji.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !when.isEmpty, !emoji.isEmpty else { return nil }
                    return .init(when: when, emoji: emoji)
                }
            )
        )
    }
}

struct DiscordDestinationDraft: Equatable {
    var isEnabled: Bool
    var applicationID: String
    var showProcessInfo: Bool
    var showMediaInfo: Bool
    var prioritizeMedia: Bool
    var useListeningForMedia: Bool
    var showTimestamps: Bool
    var customLargeImageKey: String
    var customLargeImageText: String
    var brandSmallImageKey: String
    var enableButtons: Bool
    var buttonLabel: String
    var buttonURL: String

    init(integration: DiscordIntegration) {
        isEnabled = integration.isEnabled
        applicationID = integration.applicationId
        showProcessInfo = integration.showProcessInfo
        showMediaInfo = integration.showMediaInfo
        prioritizeMedia = integration.prioritizeMedia
        useListeningForMedia = integration.useListeningForMedia
        showTimestamps = integration.showTimestamps
        customLargeImageKey = integration.customLargeImageKey
        customLargeImageText = integration.customLargeImageText
        brandSmallImageKey = integration.brandSmallImageKey
        enableButtons = integration.enableButtons
        buttonLabel = integration.buttonLabel
        buttonURL = integration.buttonUrl
    }

    func applying(to previous: DiscordIntegration) -> DiscordIntegration {
        var integration = previous
        integration.isEnabled = isEnabled
        integration.applicationId = applicationID.trimmingCharacters(in: .whitespacesAndNewlines)
        integration.showProcessInfo = showProcessInfo
        integration.showMediaInfo = showMediaInfo
        integration.prioritizeMedia = prioritizeMedia
        integration.useListeningForMedia = useListeningForMedia
        integration.showTimestamps = showTimestamps
        integration.customLargeImageKey = customLargeImageKey.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        integration.customLargeImageText = customLargeImageText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        integration.brandSmallImageKey = brandSmallImageKey.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        integration.enableButtons = enableButtons
        integration.buttonLabel = buttonLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        integration.buttonUrl = buttonURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return integration
    }
}

struct S3DestinationDraft: Equatable {
    var isEnabled: Bool
    var bucket: String
    var region: String
    var accessKey: DestinationCredentialDraft
    var secretKey: DestinationCredentialDraft
    var endpoint: String
    var path: String
    var customDomain: String

    init(integration: S3Integration) {
        isEnabled = integration.isEnabled
        bucket = integration.bucket
        region = integration.region
        accessKey = DestinationCredentialDraft(hadStoredValue: !integration.accessKey.isEmpty)
        secretKey = DestinationCredentialDraft(hadStoredValue: !integration.secretKey.isEmpty)
        endpoint = integration.endpoint
        path = integration.path
        customDomain = integration.customDomain
    }

    func applying(to previous: S3Integration) -> S3Integration {
        S3Integration(
            isEnabled: isEnabled,
            bucket: bucket.trimmingCharacters(in: .whitespacesAndNewlines),
            region: region.trimmingCharacters(in: .whitespacesAndNewlines),
            accessKey: accessKey.resolvedValue(previousValue: previous.accessKey),
            secretKey: secretKey.resolvedValue(previousValue: previous.secretKey),
            endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
            path: path.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            customDomain: customDomain.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        )
    }
}

struct DestinationOperationNotice: Equatable {
    enum Kind: Equatable {
        case success
        case warning
        case failure
    }

    let kind: Kind
    let message: String
}

struct DestinationRecentActivity: Equatable, Sendable {
    let resultText: String
    let occurredAt: Date
    let isFailure: Bool
}

enum DestinationSaveResult: Equatable {
    case saved
    case failed(String)

    var succeeded: Bool {
        if case .saved = self { return true }
        return false
    }
}

extension SettingsDestination {
    static let presenceDestinations: [SettingsDestination] = [
        .mixSpace,
        .slack,
        .discord,
    ]
}

extension PresenceReviewPreview {
    var hasShareableContent: Bool {
        [applicationName, windowTitle, mediaTitle, mediaArtist, mediaApplicationName]
            .contains { value in
                value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            }
    }
}
