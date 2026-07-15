import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        SettingsPage(
            "General",
            subtitle: "Control what ProcessReporter may collect and share."
        ) {
            if let notice = store.generalNotice {
                SettingsInlineNotice(message: notice)
            }

            if let warning = store.credentialWarning {
                SettingsInlineNotice(message: warning, symbolName: "key.fill")
            }

            SettingsGroup(
                "Presence Sharing",
                footer: "Sharing remains fail-closed if protected credential storage is unavailable."
            ) {
                SettingsToggleRow(
                    title: "Share Presence",
                    detail: store.reportingEnabled
                        ? "Current activity may be sent to enabled destinations."
                        : "Collection and delivery are paused.",
                    isOn: Binding(
                        get: { store.reportingEnabled },
                        set: store.setReportingEnabled
                    ),
                    secondaryActionTitle: !store.canStartSharingAfterOnboarding
                        && store.credentialsReady
                        ? "Set Up a Destination…" : nil,
                    secondaryAction: {
                        store.navigate(to: .section(.destinations))
                    },
                    controlEnabled: store.reportingEnabled || store.canEnableReporting
                )
            }

            SettingsGroup("Sources") {
                SettingsToggleRow(
                    title: "Applications",
                    detail: "Share the identity of the foreground application.",
                    isOn: Binding(
                        get: { store.applicationsEnabled },
                        set: store.setApplicationsEnabled
                    )
                )

                SettingsDivider()

                SettingsToggleRow(
                    title: "Window Titles",
                    detail: "Include the active window title when application Presence is shared.",
                    isOn: Binding(
                        get: { store.windowTitlesEnabled },
                        set: store.setWindowTitlesEnabled
                    )
                )

                SettingsDivider()

                SettingsToggleRow(
                    title: "Media Playback",
                    detail: "Share the currently playing title, artist, and media application.",
                    isOn: Binding(
                        get: { store.mediaEnabled },
                        set: store.setMediaEnabled
                    )
                )
            }

            SettingsGroup("Permissions & Components") {
                CapabilityRow(
                    title: "Accessibility",
                    detail: store.accessibilityGranted
                        ? "Window information is available."
                        : "Application identity remains available; window information is limited.",
                    status: store.accessibilityGranted ? "Granted" : "Not Granted",
                    symbolName: store.accessibilityGranted
                        ? "checkmark.circle.fill" : "exclamationmark.circle",
                    actionTitle: store.accessibilityGranted ? nil : "Open System Settings…",
                    action: store.openAccessibilitySettings
                )

                SettingsDivider()

                CapabilityRow(
                    title: "Media Provider",
                    detail: store.mediaHelperInstalled
                        ? "The optional media-control enrichment provider is available."
                        : "The built-in provider is ready; media-control can add richer metadata.",
                    status: store.mediaHelperInstalled ? "Enhanced" : "Ready",
                    symbolName: "waveform.circle.fill",
                    actionTitle: store.mediaHelperInstalled ? nil : "Learn More…",
                    action: store.openMediaHelperProject
                )

                SettingsDivider()

                CapabilityRow(
                    title: "Credential Storage",
                    detail: credentialDetail,
                    status: credentialStatus,
                    symbolName: credentialSymbol
                )
            }

            SettingsGroup("Startup") {
                SettingsToggleRow(
                    title: "Launch at Login",
                    detail: "Start ProcessReporter automatically after signing in.",
                    isOn: Binding(
                        get: { store.launchAtLoginEnabled },
                        set: store.setLaunchAtLoginEnabled
                    ),
                    secondaryActionTitle: store.generalNotice?.contains("Login Items") == true
                        ? "Open Login Items…" : nil,
                    secondaryAction: store.openLoginItemsSettings
                )
            }
        }
    }

    private var credentialStatus: String {
        if !store.credentialsReady { return "Loading" }
        if store.credentialStoreUnavailable { return "Recovery Required" }
        if store.credentialWarning != nil { return "Needs Attention" }
        return "Ready"
    }

    private var credentialDetail: String {
        if !store.credentialsReady {
            return "Loading protected destination credentials."
        }
        if store.credentialStoreUnavailable {
            return "Presence sharing is paused until the protected store is recovered."
        }
        return store.credentialWarning == nil
            ? "Destination credentials are available."
            : "One or more destination credentials require review."
    }

    private var credentialSymbol: String {
        if !store.credentialsReady { return "ellipsis.circle" }
        if store.credentialStoreUnavailable || store.credentialWarning != nil {
            return "exclamationmark.triangle.fill"
        }
        return "checkmark.shield.fill"
    }
}

private struct CapabilityRow: View {
    let title: String
    let detail: String
    let status: String
    let symbolName: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbolName)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 5) {
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .controlSize(.small)
                }
            }
        }
        .padding(14)
    }
}
