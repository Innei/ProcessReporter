import SwiftUI

@MainActor
struct PresencePopoverView: View {
    @ObservedObject var model: PresenceMenuBarModel
    let actions: PresencePopoverActions

    private var sharingBinding: Binding<Bool> {
        Binding(
            get: { model.isSharing },
            set: { requestedValue in
                model.setSharing(requestedValue)
            }
        )
    }

    private var preferredHeight: CGFloat {
        var height: CGFloat = 198
        height += model.currentPresence == nil ? 56 : 104

        let destinationCount = max(model.configuredDestinations.count, 1)
        height += CGFloat(destinationCount * 48)

        if model.blockingMessage != nil {
            height += 74
        }
        if model.assetResolution.isFailure {
            height += 74
        }
        return min(620, max(300, height))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    currentPresenceSection
                    destinationsSection
                    notices
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }

            Divider()
            footer
        }
        .frame(width: 372, height: preferredHeight)
        .onExitCommand(perform: actions.dismiss)
    }

    private var header: some View {
        Toggle(isOn: sharingBinding) {
            HStack(alignment: .top, spacing: 10) {
                PresenceStatusMark(status: model.aggregateStatus)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Share Presence")
                        .font(.headline)
                    Text(model.aggregateStatus.displayText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.switch)
        .disabled(!model.canShare && !model.isSharing)
        .accessibilityHint(sharingAccessibilityHint)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var sharingAccessibilityHint: String {
        if !model.canShare && !model.isSharing {
            return "Set up and enable a destination in Settings before sharing."
        }
        return model.isSharing ? "Turn off Presence sharing." : "Turn on Presence sharing."
    }

    @ViewBuilder
    private var currentPresenceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Now")

            if !model.isSharing {
                EmptyPresenceView(
                    symbolName: "pause.circle",
                    title: "Sharing is paused",
                    detail: "Resume sharing to publish your current Presence."
                )
            } else if let presence = model.currentPresence {
                PresencePreviewView(presence: presence) {
                    actions.openPrivacyRules(model.privacyTargetApplicationIdentifier)
                }
            } else {
                EmptyPresenceView(
                    symbolName: "moon.stars",
                    title: "Nothing to share right now",
                    detail: "ProcessReporter is waiting for an application or media update."
                )
            }
        }
    }

    @ViewBuilder
    private var destinationsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Destinations")

            if model.configuredDestinations.isEmpty {
                Button(action: actions.openDestinations) {
                    HStack(spacing: 10) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .frame(width: 28, height: 28)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("No destinations configured")
                                .foregroundStyle(.primary)
                            Text("Set up a destination to start sharing Presence.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Set up a Presence destination")
            } else {
                ForEach(model.configuredDestinations) { destination in
                    DestinationStatusRow(destination: destination) {
                        actions.openDestination(destination.id)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var notices: some View {
        let hasDestinationFailure = model.configuredDestinations.contains {
            $0.deliveryState.isFailure
        }

        if let blockingMessage = model.blockingMessage {
            PresenceInlineNotice(
                kind: blockingMessage == "Waiting for network" ? .information : .warning,
                title: blockingMessage == "Waiting for network"
                    ? "Waiting for network"
                    : "Sharing needs attention",
                detail: blockingMessage,
                actionTitle: blockingMessage == "Waiting for network" ? nil : "Open Settings",
                action: blockingMessage == "Waiting for network" ? nil : actions.openSettings
            )
        }

        if model.assetResolution.isFailure {
            PresenceInlineNotice(
                kind: .warning,
                title: "App icon could not be updated",
                detail: "Presence may have been sent without its application icon.",
                actionTitle: "Review Icon Hosting",
                action: actions.openIconHosting
            )
        }

        if model.aggregateStatus == .error,
           model.blockingMessage == nil,
           !hasDestinationFailure
        {
            PresenceInlineNotice(
                kind: .error,
                title: "Presence could not be completed",
                detail: "Open Settings to review the latest delivery or local history error.",
                actionTitle: "Open Settings",
                action: actions.openSettings
            )
        }
    }

    private var footer: some View {
        HStack {
            Button("Settings…", action: actions.openSettings)
                .keyboardShortcut(",", modifiers: .command)

            Spacer()

            Button("Quit", action: actions.quit)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}
