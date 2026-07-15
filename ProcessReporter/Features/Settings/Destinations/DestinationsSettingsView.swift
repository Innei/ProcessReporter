import SwiftUI

struct DestinationsSettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        NavigationStack(path: $store.destinationPath) {
            List {
                Section("Presence Destinations") {
                    destinationLink(.mixSpace)
                    destinationLink(.slack)
                    destinationLink(.discord)
                }

                Section("Resources") {
                    destinationLink(.applicationIconHosting)
                }
            }
            .listStyle(.inset)
            .navigationTitle("Destinations")
            .navigationSubtitle("Choose where Presence is delivered and how public icon URLs are hosted.")
            .navigationDestination(for: SettingsDestination.self) { destination in
                DestinationDetailView(destination: destination, store: store)
            }
            .task {
                await store.refreshDestinationActivity()
            }
        }
    }

    private func destinationLink(_ destination: SettingsDestination) -> some View {
        let status = store.configurationStatus(for: destination)
        return NavigationLink(value: destination) {
            HStack(spacing: 12) {
                Image(nsImage: destination.image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.8), lineWidth: 1)
                    }
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(destination.title)
                    Text(destination.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 3) {
                    Label(status.title, systemImage: status.symbolName)
                        .font(.caption)
                        .foregroundStyle(
                            status.isConfigured && !status.isValid
                                ? Color.orange
                                : (status.isEnabled ? Color.green : Color.secondary)
                        )
                        .labelStyle(.titleAndIcon)
                    if let activity = store.latestDestinationActivity[destination] {
                        HStack(spacing: 3) {
                            Text("Last \(activity.resultText) ·")
                            Text(activity.occurredAt, style: .relative)
                        }
                        .font(.caption2)
                        .foregroundStyle(activity.isFailure ? Color.red : Color.secondary)
                    } else {
                        Text("No sync yet")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.vertical, 5)
            .accessibilityElement(children: .combine)
        }
    }
}

private struct DestinationDetailView: View {
    let destination: SettingsDestination
    @ObservedObject var store: SettingsStore

    @State private var showingLeaveConfirmation = false
    @State private var showingDisableLastConfirmation = false
    @State private var showingTestConfirmation = false
    @State private var showingClearCacheConfirmation = false
    @State private var leaveAfterSaving = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Destinations", systemImage: "chevron.left", action: requestBack)
                    .disabled(store.destinationBusy != nil)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()
            destinationEditor
        }
        .navigationBarBackButtonHidden(true)
        .confirmationDialog(
                "Save Changes Before Leaving?",
                isPresented: $showingLeaveConfirmation,
                titleVisibility: .visible
            ) {
                Button("Save Changes") {
                    requestSave(thenLeave: true)
                }
                Button("Discard Changes", role: .destructive) {
                    store.discardDestinationDraft(destination)
                    popDestination()
                }
                .disabled(store.destinationBusy != nil)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This destination has an unsaved draft. Save or discard it before returning to the destination list.")
            }
            .confirmationDialog(
                "Stop Presence Sharing?",
                isPresented: $showingDisableLastConfirmation,
                titleVisibility: .visible
            ) {
                Button("Save and Stop Sharing", role: .destructive) {
                    performSave(allowDisablingLastReadyDestination: true)
                }
                Button("Cancel", role: .cancel) {
                    leaveAfterSaving = false
                }
            } message: {
                Text("This change disables the last ready Presence destination. Saving it will turn off the global Presence sharing switch.")
            }
            .confirmationDialog(
                "Run External Test?",
                isPresented: $showingTestConfirmation,
                titleVisibility: .visible
            ) {
                Button(testActionTitle) {
                    Task { await store.testDestination(destination) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(testConfirmationMessage)
            }
            .confirmationDialog(
                "Clear Local Icon Cache?",
                isPresented: $showingClearCacheConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear Local Cache", role: .destructive) {
                    Task { await store.clearApplicationIconCache() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Local icon URL records, upload fingerprints, and the failed-upload queue will be removed. Remote S3 objects will not be deleted.")
            }
            .task {
                await store.refreshDestinationPreview()
            }
    }

    @ViewBuilder
    private var destinationEditor: some View {
        switch destination {
        case .mixSpace:
            MixSpaceDestinationView(
                store: store,
                onTest: { showingTestConfirmation = true },
                onSave: { requestSave() }
            )
        case .slack:
            SlackDestinationView(
                store: store,
                onTest: { showingTestConfirmation = true },
                onSave: { requestSave() }
            )
        case .discord:
            DiscordDestinationView(
                store: store,
                onTest: { showingTestConfirmation = true },
                onSave: { requestSave() }
            )
        case .applicationIconHosting:
            S3DestinationView(
                store: store,
                onTest: { showingTestConfirmation = true },
                onSave: { requestSave() },
                onClearCache: { showingClearCacheConfirmation = true }
            )
        }
    }

    private var testActionTitle: String {
        switch destination {
        case .mixSpace: return "Send Test Presence"
        case .slack: return "Set Temporary Status"
        case .discord: return "Publish Temporary Activity"
        case .applicationIconHosting: return "Select App and Upload"
        }
    }

    private var testConfirmationMessage: String {
        switch destination {
        case .mixSpace:
            return "The current sanitized Presence will be sent to the endpoint using the unsaved draft. This is a real external write."
        case .slack:
            return "Your Slack profile status will be replaced with a temporary status using the current unsaved draft, including its expiration."
        case .discord:
            return "Discord Rich Presence will be temporarily replaced using the current unsaved draft, then cleared."
        case .applicationIconHosting:
            return "A selected application icon will be uploaded, then its public URL will be checked with an unauthenticated GET. The remote object will be retained."
        }
    }

    private func requestBack() {
        guard store.destinationBusy == nil else { return }
        if store.isDestinationDirty(destination) {
            showingLeaveConfirmation = true
        } else {
            popDestination()
        }
    }

    private func requestSave(thenLeave: Bool = false) {
        leaveAfterSaving = thenLeave
        if store.saveWouldDisableLastReadyDestination(destination) {
            Task { @MainActor in
                await Task.yield()
                showingDisableLastConfirmation = true
            }
        } else {
            performSave(allowDisablingLastReadyDestination: false)
        }
    }

    private func performSave(allowDisablingLastReadyDestination: Bool) {
        Task {
            let result = await store.saveDestination(
                destination,
                allowDisablingLastReadyDestination: allowDisablingLastReadyDestination
            )
            if result.succeeded, leaveAfterSaving {
                leaveAfterSaving = false
                popDestination()
            }
        }
    }

    private func popDestination() {
        guard !store.destinationPath.isEmpty else { return }
        store.destinationPath.removeLast()
    }
}
