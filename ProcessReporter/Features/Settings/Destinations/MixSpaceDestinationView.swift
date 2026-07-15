import SwiftUI

struct MixSpaceDestinationView: View {
    @ObservedObject var store: SettingsStore
    let onTest: () -> Void
    let onSave: () -> Void

    var body: some View {
        DestinationEditorLayout(
            destination: .mixSpace,
            status: store.configurationStatus(for: .mixSpace),
            isEnabled: $store.mixSpaceDraft.isEnabled,
            notice: store.destinationNotices[.mixSpace],
            isBusy: store.destinationBusy != nil,
            isDirty: store.isDestinationDirty(.mixSpace),
            testTitle: "Send Test Presence…",
            onTest: onTest,
            onDiscard: { store.discardDestinationDraft(.mixSpace) },
            onSave: onSave
        ) {
            DestinationFormRow(
                "Endpoint",
                detail: "HTTPS URL that accepts the MixSpace Presence payload."
            ) {
                TextField("https://example.com/api/presence", text: $store.mixSpaceDraft.endpoint)
                    .textFieldStyle(.roundedBorder)
            }
            DestinationCredentialField(
                title: "API Token",
                placeholder: "Enter API token",
                credential: $store.mixSpaceDraft.token,
                onRemove: { store.mixSpaceDraft.isEnabled = false }
            )
        } content: {
            Text("MixSpace receives application, window-title, media, and optional hosted-icon fields after Privacy & Rules are applied.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if store.isLoadingDestinationPreview {
                ProgressView("Preparing sanitized Presence…")
            } else if let preview = store.destinationPreview, preview.hasShareableContent {
                DestinationPreviewCard(
                    title: "Sanitized Request Preview",
                    rows: [
                        ("Application", preview.applicationName ?? "—"),
                        ("Window", preview.windowTitle ?? "—"),
                        ("Media", preview.mediaTitle ?? "—"),
                        ("Artist", preview.mediaArtist ?? "—"),
                        ("Media App", preview.mediaApplicationName ?? "—"),
                        ("Icon", store.s3Integration.isEnabled ? "Public URL when available" : "No hosted URL"),
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
            DestinationFormRow(
                "Request Method",
                detail: "Use the method required by the configured endpoint."
            ) {
                Picker("Request Method", selection: $store.mixSpaceDraft.requestMethod) {
                    ForEach(["POST", "PUT", "PATCH", "DELETE"], id: \.self) { method in
                        Text(method).tag(method)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
            }
            Text("Testing sends the current sanitized Presence as a real external write using this draft. It does not save the draft.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
