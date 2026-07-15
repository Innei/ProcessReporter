import SwiftUI

struct OnboardingRootView: View {
    @ObservedObject var settingsStore: SettingsStore
    @StateObject private var store = OnboardingStore()

    var body: some View {
        HStack(spacing: 0) {
            onboardingSidebar
                .frame(width: 210)
            Divider()
            VStack(spacing: 0) {
                ScrollView {
                    stepContent
                        .frame(maxWidth: 610, alignment: .leading)
                        .padding(32)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
                Divider()
                navigationBar
            }
        }
        .frame(minWidth: 720, minHeight: 500)
        .sheet(item: $store.configuredSheet) { destination in
            OnboardingDestinationEditorSheet(
                destination: destination,
                settingsStore: settingsStore,
                dismiss: { store.configuredSheet = nil }
            )
        }
    }

    private var onboardingSidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("ProcessReporter")
                    .font(.headline)
                Text("Presence Setup")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(store.steps(using: settingsStore).enumerated()), id: \.element.id) {
                    index, step in
                    HStack(spacing: 10) {
                        Image(systemName: step.symbolName)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(step.title)
                            Text("Step \(index + 1)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .font(.subheadline.weight(step == store.currentStep ? .semibold : .regular))
                    .foregroundStyle(step == store.currentStep ? Color.primary : Color.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        step == store.currentStep ? Color.accentColor.opacity(0.1) : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                }
            }

            Spacer()

            Text("Setup can be completed without enabling sharing. S3 icon hosting is always optional.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch store.currentStep {
        case .welcome:
            welcomeStep
        case .sources:
            sourcesStep
        case .destination:
            destinationStep
        case .iconHosting:
            iconHostingStep
        case .review:
            reviewStep
        }
    }

    private var welcomeStep: some View {
        OnboardingStepLayout(
            symbolName: "dot.radiowaves.left.and.right",
            title: "Share what you are doing now",
            subtitle: "ProcessReporter is a personal Presence synchronization utility."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                OnboardingExplanationRow(
                    symbolName: "app.badge.checkmark",
                    title: "Current Presence only",
                    detail: "Share the foreground application and current media with destinations you choose."
                )
                OnboardingExplanationRow(
                    symbolName: "hand.raised.fill",
                    title: "Privacy before delivery",
                    detail: "Application rules and source switches sanitize every snapshot before it reaches a destination or local history."
                )
                OnboardingExplanationRow(
                    symbolName: "chart.bar.xaxis",
                    title: "No productivity analysis",
                    detail: "ProcessReporter does not create rankings, focus scores, or work-time analytics."
                )
            }
        }
    }

    private var sourcesStep: some View {
        OnboardingStepLayout(
            symbolName: "hand.raised",
            title: "Choose sources and privacy defaults",
            subtitle: "Sources define the outer collection boundary. Privacy defaults determine what is shared."
        ) {
            SettingsGroup("Sources") {
                SettingsToggleRow(
                    title: "Applications",
                    detail: "Share the identity of the foreground application.",
                    isOn: Binding(
                        get: { settingsStore.applicationsEnabled },
                        set: settingsStore.setApplicationsEnabled
                    )
                )
                SettingsDivider()
                SettingsToggleRow(
                    title: "Window Titles",
                    detail: "Off by default because titles may contain private document or conversation names.",
                    isOn: Binding(
                        get: { settingsStore.windowTitlesEnabled },
                        set: setWindowTitles
                    )
                )
                SettingsDivider()
                SettingsToggleRow(
                    title: "Media Playback",
                    detail: "Share the current title, artist, and media application.",
                    isOn: Binding(
                        get: { settingsStore.mediaEnabled },
                        set: settingsStore.setMediaEnabled
                    )
                )
            }

            if settingsStore.windowTitlesEnabled && !settingsStore.accessibilityGranted {
                SettingsInlineNotice(
                    message: "Accessibility is required only for window titles. Application identity remains available without it.",
                    symbolName: "lock.shield"
                )
                Button("Request Accessibility Access…") {
                    _ = ApplicationMonitor.shared.requestAccessibilityPermission()
                    settingsStore.refreshCapabilities()
                }
            }
        }
    }

    private var destinationStep: some View {
        OnboardingStepLayout(
            symbolName: "dot.radiowaves.left.and.right",
            title: "Choose a Presence destination",
            subtitle: "Configure at least one destination, or explicitly finish setup for later."
        ) {
            VStack(spacing: 0) {
                ForEach(Array([SettingsDestination.mixSpace, .slack, .discord].enumerated()), id: \.element.id) {
                    index, destination in
                    OnboardingDestinationRow(
                        destination: destination,
                        status: settingsStore.configurationStatus(for: destination),
                        isSelected: store.selectedDestination == destination,
                        action: {
                            store.selectedDestination = destination
                            store.configuredSheet = destination
                        }
                    )
                    if index < 2 { Divider().padding(.leading, 62) }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.separator, lineWidth: 1)
            }

            if settingsStore.canStartSharingAfterOnboarding {
                Label("At least one configured destination is ready.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline)
            }
        }
    }

    private var iconHostingStep: some View {
        OnboardingStepLayout(
            symbolName: "externaldrive.badge.icloud",
            title: "Optional application icon hosting",
            subtitle: "MixSpace can use a public application icon URL. S3-compatible storage provides that resource; it is not a Presence destination."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Label("Presence delivery continues without icon hosting.", systemImage: "checkmark.shield")
                    .font(.headline)
                Text("When configured, icons are uploaded on demand and their public URLs are cached locally. A hosting failure degrades only the icon enhancement.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Configure Application Icon Hosting…") {
                        store.configuredSheet = .applicationIconHosting
                    }
                    if settingsStore.configurationStatus(for: .applicationIconHosting).isConfigured {
                        Label("Configured", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
            .padding(18)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var reviewStep: some View {
        OnboardingStepLayout(
            symbolName: "checkmark.circle",
            title: "Review final Presence",
            subtitle: "This preview uses the same source, privacy, mapping, and alias decisions as delivery."
        ) {
            if store.isLoadingPreview {
                ProgressView("Preparing sanitized preview…")
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else if let preview = store.preview {
                VStack(spacing: 0) {
                    ReviewValueRow("Application", value: preview.applicationName)
                    Divider().padding(.leading, 14)
                    ReviewValueRow("Window Title", value: preview.windowTitle)
                    Divider().padding(.leading, 14)
                    ReviewValueRow("Media", value: preview.mediaTitle)
                    Divider().padding(.leading, 14)
                    ReviewValueRow("Artist", value: preview.mediaArtist)
                    Divider().padding(.leading, 14)
                    ReviewValueRow("Media Application", value: preview.mediaApplicationName)
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.separator, lineWidth: 1)
                }

                Button("Refresh Preview") {
                    Task { await store.refreshPreview() }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Ready Destinations")
                    .font(.headline)
                Text(readyDestinationNames)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var navigationBar: some View {
        HStack {
            if store.currentStep != .welcome {
                Button("Back") { store.moveBack(using: settingsStore) }
            }
            Spacer()

            switch store.currentStep {
            case .destination:
                Button("Set Up Later") {
                    settingsStore.completeOnboarding(startSharing: false)
                }
                if settingsStore.canStartSharingAfterOnboarding {
                    Button("Continue") { store.advance(using: settingsStore) }
                        .buttonStyle(.borderedProminent)
                }
            case .iconHosting:
                Button(
                    settingsStore.configurationStatus(
                        for: .applicationIconHosting
                    ).isConfigured ? "Continue" : "Skip Icon Hosting"
                ) {
                    store.advance(using: settingsStore)
                }
                    .buttonStyle(.borderedProminent)
            case .review:
                Button("Finish Without Sharing") {
                    settingsStore.completeOnboarding(startSharing: false)
                }
                Button("Start Sharing") {
                    settingsStore.completeOnboarding(startSharing: true)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!settingsStore.canStartSharingAfterOnboarding)
            case .welcome, .sources:
                Button("Continue") { store.advance(using: settingsStore) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private func setWindowTitles(_ isEnabled: Bool) {
        settingsStore.setWindowTitlesEnabled(isEnabled)
        var defaults = PreferencesDataModel.presencePrivacyConfiguration.value.defaults
        defaults.windowTitle = isEnabled ? .share : .hide
        PresencePrivacyRulesRepository.updateDefaults(defaults)
    }

    private var readyDestinationNames: String {
        let destinations: [SettingsDestination] = [.mixSpace, .slack, .discord]
        let names = destinations.filter {
            let status = settingsStore.configurationStatus(for: $0)
            return status.isEnabled && status.isValid
        }.map(\.title)
        return names.isEmpty ? "None. Sharing will remain paused." : names.joined(separator: ", ")
    }
}

private struct OnboardingStepLayout<Content: View>: View {
    let symbolName: String
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    init(
        symbolName: String,
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) {
        self.symbolName = symbolName
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbolName)
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
    }
}

private struct OnboardingExplanationRow: View {
    let symbolName: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbolName)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct OnboardingDestinationRow: View {
    let destination: SettingsDestination
    let status: SettingsConfigurationStatus
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: destination.image)
                .resizable()
                .scaledToFit()
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(destination.title)
                Text(destination.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Label(status.title, systemImage: status.symbolName)
                .font(.caption)
                .foregroundStyle(status.isEnabled ? Color.green : Color.secondary)
            Button(status.isConfigured ? "Review…" : "Set Up…", action: action)
        }
        .padding(14)
        .background(isSelected ? Color.accentColor.opacity(0.06) : .clear)
    }
}

private struct ReviewValueRow: View {
    let label: String
    let value: String?

    init(_ label: String, value: String?) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value?.isEmpty == false ? value! : "Not shared")
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .padding(14)
    }
}
