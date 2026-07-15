import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SlackDestinationView: View {
    @ObservedObject var store: SettingsStore
    let onTest: () -> Void
    let onSave: () -> Void

    private let expirationOptions = [30, 60, 120, 300, 600, 1_800, 3_600]

    var body: some View {
        DestinationEditorLayout(
            destination: .slack,
            status: store.configurationStatus(for: .slack),
            isEnabled: $store.slackDraft.isEnabled,
            notice: store.destinationNotices[.slack],
            isBusy: store.destinationBusy != nil,
            isDirty: store.isDestinationDirty(.slack),
            testTitle: "Set Test Status…",
            onTest: onTest,
            onDiscard: { store.discardDestinationDraft(.slack) },
            onSave: onSave
        ) {
            DestinationCredentialField(
                title: "User OAuth Token",
                placeholder: "xoxp-…",
                credential: $store.slackDraft.token,
                onRemove: { store.slackDraft.isEnabled = false }
            )
            Link("Create or configure a Slack app", destination: URL(string: "https://api.slack.com/apps")!)
                .font(.caption)
            Text("The token requires the users.profile:write user scope.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } content: {
            DestinationFormRow("Emoji") {
                TextField(":headphones:", text: $store.slackDraft.globalCustomEmoji)
                    .textFieldStyle(.roundedBorder)
            }
            DestinationFormRow(
                "Status Template",
                detail: "Supports {process_name}, {media_process_name}, {media_name}, {artist}, and {media_name_artist}."
            ) {
                HStack(spacing: 8) {
                    TextField("Status text", text: $store.slackDraft.statusTextTemplateString)
                        .textFieldStyle(.roundedBorder)
                    Menu("Insert Variable") {
                        templateVariableButton("Application", token: "{process_name}")
                        templateVariableButton("Media Application", token: "{media_process_name}")
                        templateVariableButton("Media Title", token: "{media_name}")
                        templateVariableButton("Artist", token: "{artist}")
                        templateVariableButton("Artist and Title", token: "{media_name_artist}")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            DestinationFormRow("Default Emoji") {
                TextField(":computer:", text: $store.slackDraft.defaultEmoji)
                    .textFieldStyle(.roundedBorder)
            }
            DestinationFormRow("Default Status") {
                TextField("Working", text: $store.slackDraft.defaultStatusText)
                    .textFieldStyle(.roundedBorder)
            }
            if store.isLoadingDestinationPreview {
                ProgressView("Preparing sanitized Presence…")
            } else if let preview = store.destinationPreview, preview.hasShareableContent,
                      let text = previewText(using: preview)
            {
                DestinationPreviewCard(
                    title: "Sanitized Status Preview",
                    rows: [
                        ("Text", text),
                        ("Emoji", previewEmoji(using: preview)),
                        ("Expires", "\(store.slackDraft.expiration) seconds"),
                    ]
                )
            } else {
                Label("Nothing to share after Privacy & Rules.", systemImage: "eye.slash")
                    .foregroundStyle(.secondary)
            }
            Button("Refresh Preview") {
                Task { await store.refreshDestinationPreview() }
            }
            .buttonStyle(.link)
        } advanced: {
            DestinationFormRow("Expiration") {
                Picker("Expiration", selection: $store.slackDraft.expiration) {
                    ForEach(effectiveExpirationOptions, id: \.self) { seconds in
                        Text("\(seconds) seconds").tag(seconds)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
            }
            Divider()
            HStack {
                Text("Conditional Emoji")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button("Add Condition", systemImage: "plus") {
                    store.slackDraft.conditions.append(.init())
                }
            }
            Text("Rules are evaluated from top to bottom; the first match supplies the emoji.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(Array(store.slackDraft.conditions.enumerated()), id: \.element.id) { index, condition in
                if let legacyExpression = condition.legacyExpression {
                    VStack(alignment: .leading, spacing: 7) {
                        Label("Legacy condition requires review", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text(legacyExpression)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        HStack {
                            Button("Convert to Structured Rule") {
                                store.slackDraft.conditions[index].convertLegacyExpression()
                            }
                            Button("Remove", role: .destructive) {
                                store.slackDraft.conditions.removeAll { $0.id == condition.id }
                            }
                        }
                    }
                    .padding(10)
                    .background(.orange.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            conditionVariablePicker(index: index)
                                .frame(width: 150)
                            conditionOperatorPicker(index: index)
                                .frame(width: 105)
                            conditionValueEditor(index: index, variable: condition.variable)
                            conditionEmojiEditor(index: index)
                                .frame(width: 110)
                            removeConditionButton(condition)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                conditionVariablePicker(index: index)
                                conditionOperatorPicker(index: index)
                            }
                            conditionValueEditor(index: index, variable: condition.variable)
                            HStack(spacing: 8) {
                                conditionEmojiEditor(index: index)
                                Spacer()
                                removeConditionButton(condition)
                            }
                        }
                    }
                }
            }

            Text("Testing writes a real Slack status with this draft and its configured expiration; it does not save the draft.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var effectiveExpirationOptions: [Int] {
        Array(Set(expirationOptions + [store.slackDraft.expiration])).sorted()
    }

    private func previewText(using preview: PresenceReviewPreview) -> String? {
        var text = store.slackDraft.statusTextTemplateString
        if let value = preview.applicationName {
            text = text.replacingOccurrences(of: "{process_name}", with: value)
        }
        if let value = preview.mediaApplicationName {
            text = text.replacingOccurrences(of: "{media_process_name}", with: value)
        }
        if let value = preview.mediaTitle {
            text = text.replacingOccurrences(of: "{media_name}", with: value)
        }
        if let value = preview.mediaArtist {
            text = text.replacingOccurrences(of: "{artist}", with: value)
        }
        if let title = preview.mediaTitle, let artist = preview.mediaArtist {
            text = text.replacingOccurrences(
                of: "{media_name_artist}",
                with: "\(artist) - \(title)"
            )
        }
        let unresolvedTokens = [
            "{process_name}", "{media_process_name}", "{media_name}",
            "{artist}", "{media_name_artist}",
        ]
        if unresolvedTokens.contains(where: { text.contains($0) }) {
            let fallback = store.slackDraft.defaultStatusText.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return fallback.isEmpty ? nil : fallback
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    private func templateVariableButton(_ title: String, token: String) -> some View {
        Button(title) {
            if !store.slackDraft.statusTextTemplateString.isEmpty,
               !store.slackDraft.statusTextTemplateString.hasSuffix(" ")
            {
                store.slackDraft.statusTextTemplateString += " "
            }
            store.slackDraft.statusTextTemplateString += token
        }
    }

    private func supportsApplicationPicker(_ variable: String) -> Bool {
        [
            EmojiConditionList.EmojiCondition.Variable.processApplicationIdentifier.rawValue,
            EmojiConditionList.EmojiCondition.Variable.mediaProcessApplicationIdentifier.rawValue,
            EmojiConditionList.EmojiCondition.Variable.processName.rawValue,
            EmojiConditionList.EmojiCondition.Variable.mediaProcessName.rawValue,
        ].contains(variable)
    }

    private func conditionVariablePicker(index: Int) -> some View {
        Picker("Variable", selection: $store.slackDraft.conditions[index].variable) {
            ForEach(EmojiConditionList.EmojiCondition.Variable.allCases, id: \.rawValue) { variable in
                Text(variable.toCopyableString()).tag(variable.rawValue)
            }
        }
        .labelsHidden()
    }

    private func conditionOperatorPicker(index: Int) -> some View {
        Picker("Operator", selection: $store.slackDraft.conditions[index].comparison) {
            ForEach(EmojiConditionList.EmojiCondition.Condition.allCases, id: \.rawValue) { comparison in
                Text(comparison.rawValue).tag(comparison.rawValue)
            }
        }
        .labelsHidden()
    }

    private func conditionValueEditor(index: Int, variable: String) -> some View {
        HStack(spacing: 8) {
            TextField("Value", text: $store.slackDraft.conditions[index].value)
                .textFieldStyle(.roundedBorder)
            if supportsApplicationPicker(variable) {
                Button("Choose App…") {
                    chooseApplication(forConditionAt: index)
                }
                .fixedSize()
            }
        }
    }

    private func conditionEmojiEditor(index: Int) -> some View {
        TextField("Emoji", text: $store.slackDraft.conditions[index].emoji)
            .textFieldStyle(.roundedBorder)
    }

    private func removeConditionButton(_ condition: SlackEmojiConditionDraft) -> some View {
        Button(role: .destructive) {
            store.slackDraft.conditions.removeAll { $0.id == condition.id }
        } label: {
            Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Remove Slack emoji condition")
    }

    private func chooseApplication(forConditionAt index: Int) {
        guard store.slackDraft.conditions.indices.contains(index) else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose an Application"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let variable = store.slackDraft.conditions[index].variable
        switch variable {
        case EmojiConditionList.EmojiCondition.Variable.processApplicationIdentifier.rawValue,
             EmojiConditionList.EmojiCondition.Variable.mediaProcessApplicationIdentifier.rawValue:
            guard let identifier = Bundle(url: url)?.bundleIdentifier else { return }
            store.slackDraft.conditions[index].value = identifier
        default:
            store.slackDraft.conditions[index].value = url.deletingPathExtension().lastPathComponent
        }
    }

    private func previewEmoji(using preview: PresenceReviewPreview) -> String {
        for condition in store.slackDraft.conditions {
            guard condition.legacyExpression == nil else { continue }
            guard let parsed = EmojiConditionList.EmojiCondition.parseWhenString(
                for: condition.whenExpression
            ) else { continue }
            let candidate: String?
            switch parsed.variable {
            case .processName:
                candidate = preview.applicationName
            case .mediaProcessName:
                candidate = preview.mediaApplicationName
            case .mediaName:
                candidate = preview.mediaTitle
            case .artist:
                candidate = preview.mediaArtist
            case .processApplicationIdentifier:
                candidate = preview.applicationIdentifier
            case .mediaProcessApplicationIdentifier:
                candidate = preview.mediaApplicationIdentifier
            }
            guard let candidate else { continue }
            let matches: Bool
            switch parsed.condition {
            case .equals: matches = candidate == parsed.value
            case .startsWith: matches = candidate.hasPrefix(parsed.value)
            case .endsWith: matches = candidate.hasSuffix(parsed.value)
            case .contains: matches = candidate.contains(parsed.value)
            }
            if matches { return condition.emoji }
        }
        return store.slackDraft.globalCustomEmoji
    }
}
