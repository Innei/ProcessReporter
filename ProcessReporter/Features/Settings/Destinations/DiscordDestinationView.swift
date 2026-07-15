import SwiftUI

struct DiscordDestinationView: View {
    @ObservedObject var store: SettingsStore
    let onTest: () -> Void
    let onSave: () -> Void
    var onBack: (() -> Void)? = nil

    var body: some View {
        DestinationEditorLayout(
            destination: .discord,
            status: store.configurationStatus(for: .discord),
            isEnabled: $store.discordDraft.isEnabled,
            notice: store.destinationNotices[.discord],
            isBusy: store.destinationBusy != nil,
            isDirty: store.isDestinationDirty(.discord),
            testTitle: "Publish Test Activity…",
            onTest: onTest,
            onDiscard: { store.discardDestinationDraft(.discord) },
            onSave: onSave,
            onBack: onBack
        ) {
            DestinationFormRow(
                "Application ID",
                detail: "Numeric Application ID from the Discord Developer Portal."
            ) {
                TextField("123456789012345678", text: $store.discordDraft.applicationID)
                    .textFieldStyle(.roundedBorder)
            }
            Link(
                "Open Discord Developer Portal",
                destination: URL(string: "https://discord.com/developers/applications")!
            )
            .font(.caption)
        } content: {
            Toggle("Share application activity", isOn: $store.discordDraft.showProcessInfo)
            Toggle("Share media activity", isOn: $store.discordDraft.showMediaInfo)
            Toggle("Prioritize media when both sources are available", isOn: $store.discordDraft.prioritizeMedia)
            Toggle("Use Listening activity type for media", isOn: $store.discordDraft.useListeningForMedia)
            Toggle("Show activity timestamps", isOn: $store.discordDraft.showTimestamps)
            if store.isLoadingDestinationPreview {
                ProgressView("Preparing sanitized Presence…")
            } else if let rows = previewRows {
                DestinationPreviewCard(title: "Sanitized Rich Presence Preview", rows: rows)
            } else {
                Label("Nothing to share after Privacy & Rules.", systemImage: "eye.slash")
                    .foregroundStyle(.secondary)
            }
            Button("Refresh Preview") {
                Task { await store.refreshDestinationPreview() }
            }
            .buttonStyle(.link)
        } advanced: {
            DestinationFormRow("Large Image Asset Key") {
                TextField("Optional", text: $store.discordDraft.customLargeImageKey)
                    .textFieldStyle(.roundedBorder)
            }
            DestinationFormRow("Large Image Hover Text") {
                TextField("Optional", text: $store.discordDraft.customLargeImageText)
                    .textFieldStyle(.roundedBorder)
            }
            DestinationFormRow("Brand Small Image Key") {
                TextField("processreporter", text: $store.discordDraft.brandSmallImageKey)
                    .textFieldStyle(.roundedBorder)
            }
            Divider()
            Label("Rich Presence buttons are unavailable in this build.", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            if store.discordDraft.enableButtons
                || !store.discordDraft.buttonLabel.isEmpty
                || !store.discordDraft.buttonURL.isEmpty
            {
                Text("Existing button values are retained for compatibility but are not tested or published by the bundled Discord transport.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                DestinationFormRow("Button Label") {
                    TextField("Open", text: $store.discordDraft.buttonLabel)
                        .textFieldStyle(.roundedBorder)
                        .disabled(true)
                }
                DestinationFormRow("Button URL") {
                    TextField("https://example.com", text: $store.discordDraft.buttonURL)
                        .textFieldStyle(.roundedBorder)
                        .disabled(true)
                }
            }
            Text("Image asset keys must already exist in the Discord application. Testing publishes the supported fields from this draft, temporarily replaces the current Rich Presence, then clears it; it does not save.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var previewRows: [(String, String)]? {
        guard let preview = store.destinationPreview, preview.hasShareableContent else { return nil }
        let hasMedia = preview.mediaTitle?.isEmpty == false
        let hasApplication = preview.applicationName?.isEmpty == false
        let showsMedia = store.discordDraft.showMediaInfo && hasMedia
            && (store.discordDraft.prioritizeMedia
                || !store.discordDraft.showProcessInfo
                || !hasApplication)
        if showsMedia {
            return [
                ("Details", preview.mediaTitle ?? "—"),
                ("State", preview.mediaArtist ?? "—"),
                ("Type", store.discordDraft.useListeningForMedia ? "Listening" : "Playing"),
                ("Media App", preview.mediaApplicationName ?? "—"),
                ("Timestamp", store.discordDraft.showTimestamps ? "Enabled" : "Hidden"),
            ]
        }
        guard store.discordDraft.showProcessInfo, hasApplication else { return nil }
        return [
            ("Details", preview.applicationName ?? "—"),
            ("State", preview.windowTitle ?? "—"),
            ("Type", "Playing"),
            ("Timestamp", store.discordDraft.showTimestamps ? "Enabled" : "Hidden"),
        ]
    }
}
