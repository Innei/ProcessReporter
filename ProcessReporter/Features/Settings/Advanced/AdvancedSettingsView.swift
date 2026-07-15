import SwiftUI

private enum AdvancedConfirmation: String, Identifiable {
    case clearHistory
    case clearIcons
    case resetSettings
    case eraseAllData
    case eraseAllDataFinal

    var id: String { rawValue }
}

struct AdvancedSettingsView: View {
    @ObservedObject var store: SettingsStore
    @StateObject private var advancedStore = AdvancedSettingsStore()
    @State private var isShowingLegacyMappings = false
    @State private var confirmation: AdvancedConfirmation?

    var body: some View {
        SettingsPage(
            "Advanced",
            subtitle: "Manage delivery behavior, local data, compatibility, updates, and diagnostics."
        ) {
            if let notice = advancedStore.notice {
                SettingsInlineNotice(
                    message: notice,
                    symbolName: notice.localizedCaseInsensitiveContains("could not")
                        ? "exclamationmark.triangle.fill" : "info.circle.fill"
                )
            }
            if let notice = store.advancedNotice,
               notice != advancedStore.notice
            {
                SettingsInlineNotice(
                    message: notice,
                    symbolName: notice.localizedCaseInsensitiveContains("failed")
                        || notice.localizedCaseInsensitiveContains("could not")
                        ? "exclamationmark.triangle.fill" : "info.circle.fill"
                )
            }

            SettingsGroup("Reporting Engine") {
                AdvancedPickerRow(
                    title: "Delivery Interval",
                    detail: "Limits how often Presence is synchronized.",
                    selection: Binding(
                        get: { store.sendInterval },
                        set: store.setSendInterval
                    )
                )
                SettingsDivider()
                SettingsToggleRow(
                    title: "Send on Application Focus Changes",
                    detail: "Prepare a Presence update when the foreground application changes.",
                    isOn: Binding(
                        get: { store.focusReportingEnabled },
                        set: store.setFocusReportingEnabled
                    )
                )
                SettingsDivider()
                SettingsToggleRow(
                    title: "Ignore Incomplete Media Metadata",
                    detail: "Do not publish media entries without artist metadata.",
                    isOn: Binding(
                        get: { store.ignoreMissingArtist },
                        set: store.setIgnoreMissingArtist
                    )
                )
                SettingsDivider()
                AdvancedValueRow(
                    title: "Active Sources",
                    value: activeSourcesDescription
                )
                SettingsDivider()
                AdvancedValueRow(
                    title: "Runtime",
                    value: PreferencesDataModel.reportingAllowed ? "Sharing" : "Paused"
                )
            }

            SettingsGroup(
                "Legacy Mappings",
                footer: "Raw identifier and name rewrites may be less intuitive than Application Rules. Hide remains higher priority."
            ) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Raw Process and Media Rewrites")
                        Text("Review compatibility mappings retained from earlier versions.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open…") { isShowingLegacyMappings = true }
                }
                .padding(14)
            }

            SettingsGroup(
                "Data & Storage",
                footer: "Clearing the icon cache removes only local URL records; remote S3 objects are preserved."
            ) {
                AdvancedValueRow(
                    title: "Sync History",
                    value: advancedStore.isLoadingCounts ? "Loading…" : "\(advancedStore.historyCount) events"
                )
                SettingsDivider()
                AdvancedValueRow(
                    title: "Application Icon Cache",
                    value: advancedStore.isLoadingCounts ? "Loading…" : "\(advancedStore.iconCount) icons"
                )
                SettingsDivider()
                HStack(spacing: 10) {
                    Button("Clear Sync History…") { confirmation = .clearHistory }
                    Button("Clear Icon Cache…") { confirmation = .clearIcons }
                    Spacer()
                    Button("Reveal Application Data in Finder", action: store.openDatabaseLocation)
                }
                .padding(14)
            }

            SettingsGroup(
                "Backup & Restore",
                footer: "New exports exclude credentials. Legacy backups with plaintext credentials require an explicit restore decision."
            ) {
                HStack(spacing: 10) {
                    Button("Import Settings…", action: store.importSettings)
                    Button("Export Settings…", action: store.exportSettings)
                    Spacer()
                }
                .padding(14)
            }

            SettingsGroup("Updates") {
                AdvancedValueRow(
                    title: "Version",
                    value: "\(advancedStore.applicationVersion) (\(advancedStore.buildNumber))"
                )
                SettingsDivider()
                HStack {
                    Text(advancedStore.updaterDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Check for Updates…", action: store.checkForUpdates)
                        .disabled(!advancedStore.isUpdaterAvailable)
                }
                .padding(14)
            }

            SettingsGroup("Diagnostics") {
                AdvancedValueRow(
                    title: "Credential Storage",
                    value: credentialStorageDescription
                )
                SettingsDivider()
                AdvancedValueRow(title: "Database", value: advancedStore.databaseLocation)
                SettingsDivider()
                AdvancedValueRow(
                    title: "Media Provider",
                    value: store.mediaHelperInstalled ? "Enhanced" : "Built-in"
                )
                SettingsDivider()
                VStack(alignment: .leading, spacing: 5) {
                    Text("Latest Safe Error")
                    Text(advancedStore.lastErrorDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(14)
                SettingsDivider()
                HStack {
                    Text("Diagnostics exclude credentials, endpoints, window titles, media titles, and raw provider responses.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy Diagnostics", action: advancedStore.copyDiagnostics)
                }
                .padding(14)
            }

            SettingsGroup(
                "Danger Zone",
                footer: "Reset Settings preserves Sync History, icon cache, and credentials. Erase All App Data removes them and restarts onboarding."
            ) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Reset Settings")
                        Text("Restore preference defaults without deleting local history or credentials.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Reset Settings…") { confirmation = .resetSettings }
                }
                .padding(14)
                SettingsDivider()
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Erase All App Data")
                        Text("Remove settings, Sync History, icon cache, and protected credentials.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Erase All App Data…", role: .destructive) {
                        confirmation = .eraseAllData
                    }
                }
                .padding(14)
            }
        }
        .task { await advancedStore.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: DataStore.changedNotification)) { _ in
            Task { await advancedStore.refresh() }
        }
        .sheet(isPresented: $isShowingLegacyMappings) {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Done") { isShowingLegacyMappings = false }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                Divider()
                LegacySettingsPage(
                    title: "Legacy Mappings",
                    subtitle: "Raw process and media rewrite rules retained for compatibility.",
                    controller: .mappings
                )
            }
            .frame(width: 720, height: 540)
        }
        .alert(item: $confirmation) { confirmation in
            confirmationAlert(confirmation)
        }
    }

    private var activeSourcesDescription: String {
        var sources: [String] = []
        if store.applicationsEnabled { sources.append("Applications") }
        if store.windowTitlesEnabled { sources.append("Window Titles") }
        if store.mediaEnabled { sources.append("Media") }
        return sources.isEmpty ? "None" : sources.joined(separator: ", ")
    }

    private var credentialStorageDescription: String {
        if store.credentialStoreUnavailable { return "Recovery Required" }
        if store.credentialWarning != nil { return "Needs Attention" }
        return CredentialStore.usesKeychainStorage ? "Keychain Ready" : "Protected Local Journal"
    }

    private func confirmationAlert(_ action: AdvancedConfirmation) -> Alert {
        switch action {
        case .clearHistory:
            return Alert(
                title: Text("Clear Sync History?"),
                message: Text("This permanently removes all local Sync Events."),
                primaryButton: .destructive(Text("Clear History")) {
                    Task { await advancedStore.clearHistory() }
                },
                secondaryButton: .cancel()
            )
        case .clearIcons:
            return Alert(
                title: Text("Clear Icon Cache?"),
                message: Text("Local public URL records will be removed. Remote S3 objects will not be deleted."),
                primaryButton: .destructive(Text("Clear Cache")) {
                    Task { await advancedStore.clearIconCache() }
                },
                secondaryButton: .cancel()
            )
        case .resetSettings:
            return Alert(
                title: Text("Reset Settings?"),
                message: Text("Preference defaults will be restored. History, icon cache, and credentials are preserved."),
                primaryButton: .destructive(Text("Reset Settings")) {
                    Task { await advancedStore.resetSettings() }
                },
                secondaryButton: .cancel()
            )
        case .eraseAllData:
            return Alert(
                title: Text("Erase All App Data?"),
                message: Text("This removes settings, history, icon cache, and protected credentials. This action cannot be undone."),
                primaryButton: .destructive(Text("Continue")) {
                    Task { @MainActor in
                        await Task.yield()
                        confirmation = .eraseAllDataFinal
                    }
                },
                secondaryButton: .cancel()
            )
        case .eraseAllDataFinal:
            return Alert(
                title: Text("Confirm Permanent Erasure"),
                message: Text("ProcessReporter will return to onboarding after local data is removed."),
                primaryButton: .destructive(Text("Erase Everything")) {
                    Task { await advancedStore.eraseAllAppData() }
                },
                secondaryButton: .cancel()
            )
        }
    }
}

private struct AdvancedPickerRow: View {
    let title: String
    let detail: String
    @Binding var selection: SendInterval

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker(title, selection: $selection) {
                ForEach(SendInterval.allCases, id: \.rawValue) { interval in
                    Text(interval.toString()).tag(interval)
                }
            }
            .labelsHidden()
            .frame(width: 110)
        }
        .padding(14)
    }
}

private struct AdvancedValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(14)
    }
}
