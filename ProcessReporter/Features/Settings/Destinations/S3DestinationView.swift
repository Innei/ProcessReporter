import SwiftUI

struct S3DestinationView: View {
    @ObservedObject var store: SettingsStore
    let onTest: () -> Void
    let onSave: () -> Void
    let onClearCache: () -> Void
    var onBack: (() -> Void)? = nil
    @State private var showingCachedIcons = false
    @State private var showingRetryFailedUploadsConfirmation = false
    @State private var showingRebuildCacheConfirmation = false

    var body: some View {
        DestinationEditorLayout(
            destination: .applicationIconHosting,
            status: store.configurationStatus(for: .applicationIconHosting),
            isEnabled: $store.s3Draft.isEnabled,
            notice: store.destinationNotices[.applicationIconHosting],
            isBusy: store.destinationBusy != nil,
            isDirty: store.isDestinationDirty(.applicationIconHosting),
            testTitle: "Upload Test Icon…",
            onTest: onTest,
            onDiscard: { store.discardDestinationDraft(.applicationIconHosting) },
            onSave: onSave,
            onBack: onBack
        ) {
            DestinationFormRow("Bucket") {
                TextField("Bucket name", text: $store.s3Draft.bucket)
                    .textFieldStyle(.roundedBorder)
            }
            DestinationFormRow("Region") {
                TextField("us-east-1", text: $store.s3Draft.region)
                    .textFieldStyle(.roundedBorder)
            }
            DestinationCredentialField(
                title: "Access Key",
                placeholder: "Enter access key",
                credential: $store.s3Draft.accessKey,
                onRemove: { store.s3Draft.isEnabled = false }
            )
            DestinationCredentialField(
                title: "Secret Key",
                placeholder: "Enter secret key",
                credential: $store.s3Draft.secretKey,
                onRemove: { store.s3Draft.isEnabled = false }
            )
        } content: {
            Text("Application icons are uploaded on demand. Providers receive only the resulting public URL; S3 is not a Presence destination.")
                .font(.caption)
                .foregroundStyle(.secondary)
            DestinationPreviewCard(
                title: "Hosted Icon URL Preview",
                rows: [
                    ("Base", publicURLBase),
                    ("Object Path", objectPath),
                    ("Credentials", credentialsStatus),
                    ("Cache", store.iconCacheCount.map { "\($0) local records" } ?? "Loading…"),
                ]
            )
        } advanced: {
            DestinationFormRow(
                "S3 Endpoint",
                detail: "Optional HTTPS endpoint for S3-compatible storage."
            ) {
                TextField("https://s3.example.com", text: $store.s3Draft.endpoint)
                    .textFieldStyle(.roundedBorder)
            }
            DestinationFormRow("Object Path") {
                TextField("app-icons", text: $store.s3Draft.path)
                    .textFieldStyle(.roundedBorder)
            }
            DestinationFormRow(
                "Public URL Prefix",
                detail: "Optional CDN or custom-domain HTTPS prefix."
            ) {
                TextField("https://cdn.example.com", text: $store.s3Draft.customDomain)
                    .textFieldStyle(.roundedBorder)
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Local Icon URL Cache")
                    Text("Clearing local records never deletes remote S3 objects.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Manage Cached Icons…") {
                    showingCachedIcons = true
                }
                Button("Clear Cache…", role: .destructive, action: onClearCache)
            }
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Failed Upload Queue")
                    Text("\(store.failedIconUploadCount) application icon(s) waiting for retry.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Retry Failed Uploads…") {
                    showingRetryFailedUploadsConfirmation = true
                }
                .disabled(
                    store.failedIconUploadCount == 0
                        || store.destinationBusy != nil
                        || store.isDestinationDirty(.applicationIconHosting)
                        || !store.credentialsReady
                        || store.credentialStoreUnavailable
                )
            }
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Rebuild Hosted Icon Cache")
                    Text("Re-upload current icons for every local cache record using the saved configuration.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Rebuild Cache…") {
                    showingRebuildCacheConfirmation = true
                }
                .disabled(
                    (store.iconCacheCount ?? 0) == 0
                        || store.destinationBusy != nil
                        || store.isDestinationDirty(.applicationIconHosting)
                        || !store.credentialsReady
                        || store.credentialStoreUnavailable
                )
            }
            Text("Testing uploads the selected application icon, verifies its public URL with an unauthenticated GET, and retains the remote object. The draft is not saved.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task {
            await store.refreshIconCacheCount()
        }
        .sheet(isPresented: $showingCachedIcons, onDismiss: {
            Task { await store.refreshIconCacheCount() }
        }) {
            VStack(spacing: 0) {
                HStack {
                    Text("Cached Application Icons")
                        .font(.headline)
                    Spacer()
                    Button("Done") { showingCachedIcons = false }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                Divider()
                CachedIconsViewControllerRepresentable()
            }
            .frame(width: 900, height: 520)
        }
        .confirmationDialog(
            "Retry Failed Application Icon Uploads?",
            isPresented: $showingRetryFailedUploadsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Retry Uploads") {
                Task { await store.retryFailedApplicationIconUploads() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This performs real S3 uploads for queued applications using the saved configuration. Successfully uploaded public URLs replace their local cache records.")
        }
        .confirmationDialog(
            "Rebuild Hosted Icon Cache?",
            isPresented: $showingRebuildCacheConfirmation,
            titleVisibility: .visible
        ) {
            Button("Rebuild Cache") {
                Task { await store.rebuildApplicationIconCache() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This re-uploads every currently cached application icon using the saved S3 configuration. Existing remote objects are not deleted.")
        }
    }

    private var publicURLBase: String {
        let customDomain = store.s3Draft.customDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        if !customDomain.isEmpty { return customDomain }
        let endpoint = store.s3Draft.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !endpoint.isEmpty { return endpoint + "/" + store.s3Draft.bucket }
        guard !store.s3Draft.bucket.isEmpty, !store.s3Draft.region.isEmpty else { return "—" }
        return "https://\(store.s3Draft.bucket).s3.\(store.s3Draft.region).amazonaws.com"
    }

    private var objectPath: String {
        let path = store.s3Draft.path.trimmingCharacters(in: .whitespacesAndNewlines)
        return (path.isEmpty ? "app-icons" : path) + "/<content-hash>.png"
    }

    private var credentialsStatus: String {
        store.s3Draft.accessKey.hasEffectiveValue && store.s3Draft.secretKey.hasEffectiveValue
            ? "Protected credentials available"
            : "Missing"
    }
}

private struct CachedIconsViewControllerRepresentable: NSViewControllerRepresentable {
    func makeNSViewController(context: Context) -> PreferencesS3IconsViewController {
        PreferencesS3IconsViewController()
    }

    func updateNSViewController(
        _ nsViewController: PreferencesS3IconsViewController,
        context: Context
    ) {}
}
