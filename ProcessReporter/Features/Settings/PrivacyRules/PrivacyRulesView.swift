import SwiftUI

struct PrivacyRulesView: View {
    @ObservedObject var settingsStore: SettingsStore
    let targetApplicationIdentifier: String?
    let targetRequestID: UUID

    @StateObject private var store = PrivacyRulesStore()
    @State private var isShowingApplicationPicker = false

    var body: some View {
        SettingsPage(
            "Privacy & Rules",
            subtitle: "Set global privacy defaults and application-specific Presence behavior."
        ) {
            SettingsGroup(
                "Global Defaults",
                footer: "General source switches remain the outer boundary. An application rule cannot re-enable a source disabled in General."
            ) {
                PrivacyDefaultRow(
                    title: "Application Name",
                    detail: "Control whether foreground application identity is shared by default.",
                    selection: defaultBinding(\.application)
                )
                SettingsDivider()
                PrivacyDefaultRow(
                    title: "Window Title",
                    detail: "Window titles are privacy-sensitive and remain hidden by default.",
                    selection: defaultBinding(\.windowTitle)
                )
                SettingsDivider()
                PrivacyDefaultRow(
                    title: "Media",
                    detail: "Control whether current media metadata is shared by default.",
                    selection: defaultBinding(\.media)
                )
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Application Rules")
                        .font(.headline)
                    Spacer()
                    Button("Add Application…") {
                        isShowingApplicationPicker = true
                    }
                }

                TextField("Search application rules", text: $store.searchText)
                    .textFieldStyle(.roundedBorder)

                if store.filteredRows.isEmpty {
                    ContentUnavailableView(
                        "No Application Rules",
                        systemImage: "hand.raised",
                        description: Text(
                            store.searchText.isEmpty
                                ? "Add a rule only when an application should differ from the global defaults."
                                : "No rules match the current search."
                        )
                    )
                    .frame(maxWidth: .infinity, minHeight: 180)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(.separator, lineWidth: 1)
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(store.filteredRows.enumerated()), id: \.element.id) {
                            index, row in
                            ApplicationRuleRow(
                                row: row,
                                editAction: { store.beginEditing(applicationIdentifier: row.id) },
                                removeAction: { store.requestRemoval(row) }
                            )
                            if index < store.filteredRows.count - 1 {
                                SettingsDivider()
                            }
                        }
                    }
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(.separator, lineWidth: 1)
                    }
                }

                Button("Open Legacy Mappings…") {
                    settingsStore.navigate(to: .section(.advanced))
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .task(id: targetRequestID) {
            guard let targetApplicationIdentifier else { return }
            store.beginEditing(applicationIdentifier: targetApplicationIdentifier)
        }
        .sheet(isPresented: $isShowingApplicationPicker) {
            AppPickerView { applicationIdentifier, _ in
                isShowingApplicationPicker = false
                guard let applicationIdentifier else { return }
                Task { @MainActor in
                    await Task.yield()
                    store.beginEditing(applicationIdentifier: applicationIdentifier)
                }
            }
            .frame(width: 440, height: 520)
        }
        .sheet(item: $store.editingRule) { rule in
            ApplicationRuleEditor(
                rule: rule,
                defaults: store.defaults,
                applicationSourceEnabled: PreferencesDataModel.enabledTypes.value.types
                    .contains(.process),
                windowSourceEnabled: PreferencesDataModel.shareWindowTitles.value,
                mediaSourceEnabled: PreferencesDataModel.enabledTypes.value.types.contains(.media),
                legacyApplicationName: legacyMappedName(
                    for: rule.applicationIdentifier,
                    type: .processName
                ),
                legacyMediaApplicationName: legacyMappedName(
                    for: rule.applicationIdentifier,
                    type: .mediaProcessName
                ),
                hasLegacyMapping: !PresencePrivacyRulesRepository.legacyMappings(
                    associatedWith: rule.applicationIdentifier
                ).isEmpty,
                cancelAction: { store.editingRule = nil },
                saveAction: store.save
            )
        }
        .alert(
            "Remove Application Rule?",
            isPresented: Binding(
                get: { store.pendingRemoval != nil },
                set: { if !$0 { store.pendingRemoval = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { store.pendingRemoval = nil }
            Button("Remove Rule", role: .destructive, action: store.confirmRemoval)
        } message: {
            Text(
                "Removing this rule also removes its legacy Hide projection and may allow the application to be shared under the global defaults. Legacy Mappings are preserved."
            )
        }
    }

    private func defaultBinding(
        _ keyPath: WritableKeyPath<PresencePrivacyDefaults, PresencePrivacyDefault>
    ) -> Binding<PresencePrivacyDefault> {
        Binding(
            get: { store.defaults[keyPath: keyPath] },
            set: { store.updateDefault(keyPath, to: $0) }
        )
    }

    private func legacyMappedName(
        for applicationIdentifier: String,
        type: PreferencesDataModel.MappingType
    ) -> String {
        let originalName = AppUtility.shared.getAppInfo(
            for: applicationIdentifier
        ).displayName
        return PreferencesDataModel.mappingList.value.getList().first {
            $0.type == type && $0.from == originalName
        }?.to ?? originalName
    }
}

private struct PrivacyDefaultRow: View {
    let title: String
    let detail: String
    @Binding var selection: PresencePrivacyDefault

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
                ForEach(PresencePrivacyDefault.allCases, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 150)
        }
        .padding(14)
    }
}

private struct ApplicationRuleRow: View {
    let row: ApplicationRuleRowModel
    let editAction: () -> Void
    let removeAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: row.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.displayName)
                    if row.hasLegacyMapping {
                        Label("Legacy Mapping", systemImage: "arrow.triangle.swap")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .labelStyle(.iconOnly)
                            .help("A Legacy Mapping is also applied to this application.")
                    }
                }
                Text(row.id)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Text(row.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            Button("Edit", action: editAction)
            Button(action: removeAction) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove Rule")
            .accessibilityLabel("Remove rule for \(row.displayName)")
        }
        .padding(14)
    }
}

private struct ApplicationRuleEditor: View {
    let defaults: PresencePrivacyDefaults
    let applicationSourceEnabled: Bool
    let windowSourceEnabled: Bool
    let mediaSourceEnabled: Bool
    let legacyApplicationName: String
    let legacyMediaApplicationName: String
    let hasLegacyMapping: Bool
    let cancelAction: () -> Void
    let saveAction: (ApplicationPresenceRule) -> Void

    @State private var draft: ApplicationPresenceRule

    init(
        rule: ApplicationPresenceRule,
        defaults: PresencePrivacyDefaults,
        applicationSourceEnabled: Bool,
        windowSourceEnabled: Bool,
        mediaSourceEnabled: Bool,
        legacyApplicationName: String,
        legacyMediaApplicationName: String,
        hasLegacyMapping: Bool,
        cancelAction: @escaping () -> Void,
        saveAction: @escaping (ApplicationPresenceRule) -> Void
    ) {
        _draft = State(initialValue: rule)
        self.defaults = defaults
        self.applicationSourceEnabled = applicationSourceEnabled
        self.windowSourceEnabled = windowSourceEnabled
        self.mediaSourceEnabled = mediaSourceEnabled
        self.legacyApplicationName = legacyApplicationName
        self.legacyMediaApplicationName = legacyMediaApplicationName
        self.hasLegacyMapping = hasLegacyMapping
        self.cancelAction = cancelAction
        self.saveAction = saveAction
    }

    private var appInfo: AppInfo {
        AppUtility.shared.getAppInfo(for: draft.applicationIdentifier)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: appInfo.icon)
                    .resizable()
                    .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(appInfo.displayName)
                        .font(.title3.weight(.semibold))
                    Text(draft.applicationIdentifier)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    RulePickerRow("Application Presence", selection: $draft.application)
                    RulePickerRow("Window Title", selection: $draft.windowTitle)
                    RulePickerRow("Media Presence", selection: $draft.media)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Display Alias")
                            .font(.headline)
                        TextField("Use original application name", text: aliasBinding)
                            .textFieldStyle(.roundedBorder)
                        Text("Hide takes priority over the alias. An empty alias uses the original name.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if hasLegacyMapping {
                        SettingsInlineNotice(
                            message: "A Legacy Mapping is also applied. This explicit alias takes priority over legacy name mappings; Hide remains final."
                        )
                    }

                    RulePreview(
                        legacyApplicationName: legacyApplicationName,
                        legacyMediaApplicationName: legacyMediaApplicationName,
                        rule: draft,
                        defaults: defaults,
                        applicationSourceEnabled: applicationSourceEnabled,
                        windowSourceEnabled: windowSourceEnabled,
                        mediaSourceEnabled: mediaSourceEnabled
                    )
                }
                .padding(20)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel", action: cancelAction)
                    .keyboardShortcut(.cancelAction)
                Button("Save Rule") {
                    saveAction(draft.normalized)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520, height: 610)
    }

    private var aliasBinding: Binding<String> {
        Binding(
            get: { draft.displayAlias ?? "" },
            set: { draft.displayAlias = $0 }
        )
    }
}

private struct RulePickerRow: View {
    let title: String
    @Binding var selection: PresencePrivacyOverride

    init(_ title: String, selection: Binding<PresencePrivacyOverride>) {
        self.title = title
        _selection = selection
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.headline)
            Spacer()
            Picker(title, selection: $selection) {
                ForEach(PresencePrivacyOverride.allCases, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .labelsHidden()
            .frame(width: 190)
        }
    }
}

private struct RulePreview: View {
    let legacyApplicationName: String
    let legacyMediaApplicationName: String
    let rule: ApplicationPresenceRule
    let defaults: PresencePrivacyDefaults
    let applicationSourceEnabled: Bool
    let windowSourceEnabled: Bool
    let mediaSourceEnabled: Bool

    private var sharesApplication: Bool {
        applicationSourceEnabled
            && rule.application.resolve(default: defaults.application).isShared
    }

    private var sharesWindow: Bool {
        sharesApplication
            && windowSourceEnabled
            && rule.windowTitle.resolve(default: defaults.windowTitle).isShared
    }

    private var sharesMedia: Bool {
        mediaSourceEnabled && rule.media.resolve(default: defaults.media).isShared
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Final Presence Preview")
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                PreviewRow(
                    "Application",
                    value: sharesApplication
                        ? (rule.normalized.displayAlias ?? legacyApplicationName) : "Not shared"
                )
                PreviewRow("Window Title", value: sharesWindow ? "Example window title" : "Not shared")
                PreviewRow("Media", value: sharesMedia ? "Example track — Artist" : "Not shared")
                PreviewRow(
                    "Media Application",
                    value: sharesMedia
                        ? (rule.normalized.displayAlias ?? legacyMediaApplicationName)
                        : "Not shared"
                )
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }
}

private struct PreviewRow: View {
    let label: String
    let value: String

    init(_ label: String, value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}
