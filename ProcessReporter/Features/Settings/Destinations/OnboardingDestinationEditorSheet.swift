import SwiftUI

struct OnboardingDestinationEditorSheet: View {
    let destination: SettingsDestination
    @ObservedObject var settingsStore: SettingsStore
    let dismiss: () -> Void

    @State private var showingTestConfirmation = false
    @State private var showingDisableLastConfirmation = false
    @State private var showingClearCacheConfirmation = false
    @State private var dismissAfterSave = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(destination.title)
                    .font(.headline)
                Spacer()
                Button("Cancel") {
                    settingsStore.discardDestinationDraft(destination)
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(settingsStore.destinationBusy != nil)
                Button("Done") {
                    if settingsStore.isDestinationDirty(destination) {
                        requestSave(thenDismiss: true)
                    } else {
                        dismiss()
                    }
                }
                .disabled(settingsStore.destinationBusy != nil)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            Divider()
            editor
        }
        .frame(width: 760, height: 650)
        .confirmationDialog(
            "Run External Test?",
            isPresented: $showingTestConfirmation,
            titleVisibility: .visible
        ) {
            Button(testActionTitle) {
                Task { await settingsStore.testDestination(destination) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(testMessage)
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
                dismissAfterSave = false
            }
        } message: {
            Text("This change disables the last ready destination and will turn off global Presence sharing.")
        }
        .confirmationDialog(
            "Clear Local Icon Cache?",
            isPresented: $showingClearCacheConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Local Cache", role: .destructive) {
                Task { await settingsStore.clearApplicationIconCache() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Local icon URL records, upload fingerprints, and the failed-upload queue will be removed. Remote S3 objects will not be deleted.")
        }
        .task {
            await settingsStore.refreshDestinationPreview()
        }
        .interactiveDismissDisabled(
            settingsStore.destinationBusy != nil
                || settingsStore.isDestinationDirty(destination)
        )
    }

    @ViewBuilder
    private var editor: some View {
        switch destination {
        case .mixSpace:
            MixSpaceDestinationView(
                store: settingsStore,
                onTest: { showingTestConfirmation = true },
                onSave: { requestSave() }
            )
        case .slack:
            SlackDestinationView(
                store: settingsStore,
                onTest: { showingTestConfirmation = true },
                onSave: { requestSave() }
            )
        case .discord:
            DiscordDestinationView(
                store: settingsStore,
                onTest: { showingTestConfirmation = true },
                onSave: { requestSave() }
            )
        case .applicationIconHosting:
            S3DestinationView(
                store: settingsStore,
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

    private var testMessage: String {
        switch destination {
        case .mixSpace:
            return "This sends the current sanitized Presence as a real external write using the unsaved draft."
        case .slack:
            return "This replaces the Slack profile status with a temporary test using the unsaved draft and its expiration."
        case .discord:
            return "This temporarily replaces Discord Rich Presence using the unsaved draft, then clears it."
        case .applicationIconHosting:
            return "This uploads a selected application icon, verifies public GET access, and retains the remote object."
        }
    }

    private func requestSave(thenDismiss: Bool = false) {
        dismissAfterSave = thenDismiss
        if settingsStore.saveWouldDisableLastReadyDestination(destination) {
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
            let result = await settingsStore.saveDestination(
                destination,
                allowDisablingLastReadyDestination: allowDisablingLastReadyDestination
            )
            if result.succeeded, dismissAfterSave {
                dismissAfterSave = false
                dismiss()
            }
        }
    }
}
