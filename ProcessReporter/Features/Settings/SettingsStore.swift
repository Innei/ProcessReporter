import AppKit
import Combine
import Foundation
import RxCocoa
import RxSwift
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class SettingsStore: ObservableObject {
    private static let lastSectionKey = "Settings.LastSection"

    @Published var selectedSection: SettingsSection {
        didSet {
            UserDefaults.standard.set(selectedSection.rawValue, forKey: Self.lastSectionKey)
        }
    }
    @Published var destinationPath: [SettingsDestination] = []
    @Published private(set) var privacyTargetApplicationIdentifier: String?
    @Published private(set) var privacyTargetRequestID = UUID()

    @Published private(set) var reportingEnabled: Bool
    @Published private(set) var onboardingCompleted: Bool
    @Published private(set) var applicationsEnabled: Bool
    @Published private(set) var windowTitlesEnabled: Bool
    @Published private(set) var mediaEnabled: Bool
    @Published private(set) var sendInterval: SendInterval
    @Published private(set) var focusReportingEnabled: Bool
    @Published private(set) var ignoreMissingArtist: Bool
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var mediaHelperInstalled = false
    @Published private(set) var credentialsReady: Bool
    @Published private(set) var credentialStoreUnavailable = false
    @Published private(set) var credentialWarning: String?
    @Published var generalNotice: String?
    @Published var advancedNotice: String?

    @Published private(set) var mixSpaceIntegration: MixSpaceIntegration
    @Published private(set) var slackIntegration: SlackIntegration
    @Published private(set) var discordIntegration: DiscordIntegration
    @Published private(set) var s3Integration: S3Integration

    @Published var mixSpaceDraft: MixSpaceDestinationDraft
    @Published var slackDraft: SlackDestinationDraft
    @Published var discordDraft: DiscordDestinationDraft
    @Published var s3Draft: S3DestinationDraft
    @Published private(set) var destinationBusy: SettingsDestination?
    @Published private(set) var destinationNotices: [SettingsDestination: DestinationOperationNotice] = [:]
    @Published private(set) var iconCacheCount: Int?
    @Published private(set) var failedIconUploadCount = S3AssetHostingService.failedUploadCount
    @Published private(set) var destinationPreview: PresenceReviewPreview?
    @Published private(set) var isLoadingDestinationPreview = false
    @Published private(set) var latestDestinationActivity: [SettingsDestination: DestinationRecentActivity] = [:]

    private var mixSpaceDraftBaseline: MixSpaceDestinationDraft
    private var slackDraftBaseline: SlackDestinationDraft
    private var discordDraftBaseline: DiscordDestinationDraft
    private var s3DraftBaseline: S3DestinationDraft

    private let disposeBag = DisposeBag()

    var canStartSharingAfterOnboarding: Bool {
        credentialsReady
            && !credentialStoreUnavailable
            && PreferencesDataModel.hasEnabledConfiguredPresenceDestination
    }

    var canEnableReporting: Bool {
        onboardingCompleted && canStartSharingAfterOnboarding
    }

    init(initialRoute: SettingsRoute? = nil) {
        let restoredSection = UserDefaults.standard.string(forKey: Self.lastSectionKey)
            .flatMap(SettingsSection.init(rawValue:)) ?? .general
        selectedSection = PreferencesDataModel.hasCompletedOnboarding.value
            ? restoredSection : .general
        privacyTargetApplicationIdentifier = nil

        reportingEnabled = PreferencesDataModel.reportingAllowed
        onboardingCompleted = PreferencesDataModel.hasCompletedOnboarding.value
        let enabledTypes = PreferencesDataModel.enabledTypes.value.types
        applicationsEnabled = enabledTypes.contains(.process)
        windowTitlesEnabled = PreferencesDataModel.shareWindowTitles.value
        mediaEnabled = enabledTypes.contains(.media)
        sendInterval = PreferencesDataModel.sendInterval.value
        focusReportingEnabled = PreferencesDataModel.focusReport.value
        ignoreMissingArtist = PreferencesDataModel.ignoreNullArtist.value
        credentialsReady = PreferencesDataModel.integrationCredentialsReady.value
        let initialMixSpaceIntegration = PreferencesDataModel.mixSpaceIntegration.value
        mixSpaceIntegration = initialMixSpaceIntegration
        let initialSlackIntegration = PreferencesDataModel.slackIntegration.value
        slackIntegration = initialSlackIntegration
        let initialDiscordIntegration = PreferencesDataModel.discordIntegration.value
        discordIntegration = initialDiscordIntegration
        let initialS3Integration = PreferencesDataModel.s3Integration.value
        s3Integration = initialS3Integration

        let initialMixSpaceDraft = MixSpaceDestinationDraft(
            integration: initialMixSpaceIntegration
        )
        mixSpaceDraft = initialMixSpaceDraft
        mixSpaceDraftBaseline = initialMixSpaceDraft
        let initialSlackDraft = SlackDestinationDraft(integration: initialSlackIntegration)
        slackDraft = initialSlackDraft
        slackDraftBaseline = initialSlackDraft
        let initialDiscordDraft = DiscordDestinationDraft(integration: initialDiscordIntegration)
        discordDraft = initialDiscordDraft
        discordDraftBaseline = initialDiscordDraft
        let initialS3Draft = S3DestinationDraft(integration: initialS3Integration)
        s3Draft = initialS3Draft
        s3DraftBaseline = initialS3Draft

        bindPreferences()
		bindMaintenanceInvalidation()
		bindDestinationActivityInvalidation()
        bindAssetHostingFailureInvalidation()
        refreshCapabilities()

        if let initialRoute {
            navigate(to: initialRoute)
        }
    }

    func navigate(to route: SettingsRoute) {
        switch route {
        case .section(let section):
            selectedSection = section
            if section == .destinations {
                destinationPath.removeAll()
            }
            if section == .privacyRules {
                privacyTargetApplicationIdentifier = nil
                privacyTargetRequestID = UUID()
            }
        case .destination(let destination):
            selectedSection = .destinations
            destinationPath = [destination]
        case .privacyRules(let applicationIdentifier):
            selectedSection = .privacyRules
            privacyTargetApplicationIdentifier = applicationIdentifier
            privacyTargetRequestID = UUID()
        }
    }

    func refreshCapabilities() {
        reportingEnabled = PreferencesDataModel.reportingAllowed
        accessibilityGranted = ApplicationMonitor.shared.isAccessibilityEnabled()
        mediaHelperInstalled = CLIMediaInfoProvider.isMediaControlInstalled()
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        credentialsReady = PreferencesDataModel.integrationCredentialsReady.value
        credentialStoreUnavailable = PreferencesDataModel.integrationCredentialStoreUnavailable
        credentialWarning = PreferencesDataModel.integrationCredentialRecoveryWarning
        clearDestinationRequirementNoticeIfResolved()
    }

    func setReportingEnabled(_ isEnabled: Bool) {
        if isEnabled, !credentialsReady {
            _ = PreferencesDataModel.setReportingEnabled(false)
            reportingEnabled = false
            generalNotice = "Wait for protected credential storage to finish loading."
            return
        }

        if isEnabled, !canEnableReporting {
            _ = PreferencesDataModel.setReportingEnabled(false)
            reportingEnabled = false
            generalNotice = "Set up and enable a destination before sharing Presence."
            return
        }

        let accepted = PreferencesDataModel.setReportingEnabled(isEnabled)
        reportingEnabled = PreferencesDataModel.reportingAllowed
        generalNotice = accepted
            ? nil
            : "Presence sharing remains paused until credential storage is recovered."
    }

    func completeOnboarding(startSharing: Bool) {
        if startSharing {
            guard canStartSharingAfterOnboarding else {
                generalNotice = "Set up and enable a destination before sharing Presence."
                return
            }
            PreferencesDataModel.hasCompletedOnboarding.accept(true)
            setReportingEnabled(true)
            guard reportingEnabled else {
                PreferencesDataModel.hasCompletedOnboarding.accept(false)
                onboardingCompleted = false
                return
            }
        } else {
            _ = PreferencesDataModel.setReportingEnabled(false)
            reportingEnabled = false
            PreferencesDataModel.hasCompletedOnboarding.accept(true)
        }

        onboardingCompleted = true
        generalNotice = nil
    }

    func setApplicationsEnabled(_ isEnabled: Bool) {
        updateSource(.process, isEnabled: isEnabled)
    }

    func setMediaEnabled(_ isEnabled: Bool) {
        updateSource(.media, isEnabled: isEnabled)
    }

    func setWindowTitlesEnabled(_ isEnabled: Bool) {
        PreferencesDataModel.shareWindowTitles.accept(isEnabled)
    }

    func setSendInterval(_ interval: SendInterval) {
        PreferencesDataModel.sendInterval.accept(interval)
    }

    func setFocusReportingEnabled(_ isEnabled: Bool) {
        PreferencesDataModel.focusReport.accept(isEnabled)
    }

    func setIgnoreMissingArtist(_ isEnabled: Bool) {
        PreferencesDataModel.ignoreNullArtist.accept(isEnabled)
    }

    func setLaunchAtLoginEnabled(_ isEnabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if isEnabled {
                switch service.status {
                case .enabled:
                    break
                case .requiresApproval:
                    generalNotice =
                        "Allow ProcessReporter in System Settings > General > Login Items."
                default:
                    try service.register()
                }
            } else {
                switch service.status {
                case .notRegistered, .notFound:
                    break
                default:
                    try service.unregister()
                }
            }
        } catch {
            generalNotice = "Could not update Launch at Login: \(error.localizedDescription)"
        }

        launchAtLoginEnabled = service.status == .enabled
        if isEnabled, service.status == .requiresApproval {
            generalNotice =
                "Allow ProcessReporter in System Settings > General > Login Items."
        }
    }

    func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func openLoginItemsSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func openMediaHelperProject() {
        guard let url = URL(string: "https://github.com/ungive/media-control") else { return }
        NSWorkspace.shared.open(url)
    }

    func exportSettings() {
        guard let data = PreferencesDataModel.exportToPlist() else {
            advancedNotice = "Settings could not be encoded."
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Settings"
        panel.prompt = "Export"
        panel.nameFieldStringValue = "ProcessReporterData.plist"
        panel.allowedContentTypes = [.propertyList]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try data.write(to: url, options: [.atomic])
            advancedNotice = "Settings exported successfully. Credentials were excluded."
        } catch {
            advancedNotice = "Settings export failed: \(error.localizedDescription)"
        }
    }

    func importSettings() {
        let panel = NSOpenPanel()
        panel.title = "Import Settings"
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.propertyList]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            guard let importPlan = PreferencesDataModel.prepareImport(data: data) else {
                advancedNotice = "Settings import failed because the file is invalid."
                return
            }

            let credentialPolicy: PreferencesDataModel.ImportCredentialPolicy
            if importPlan.credentialIntegrationNames.isEmpty {
                credentialPolicy = .preserveCurrent
            } else {
                let credentialNames = importPlan.credentialIntegrationNames.joined(
                    separator: ", "
                )
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Restore credentials from this legacy backup?"
                alert.informativeText = """
                    This file contains plaintext credentials for \(credentialNames). Restoring copies them into protected local storage and associates them with the imported endpoints. The selected backup is not modified and will still contain plaintext credentials.

                    Enabled integrations may immediately send Presence or upload application icons to the imported services after import.

                    Importing without credentials preserves credentials already stored on this Mac only when their destination remains unchanged. Affected integrations will otherwise be disabled for review.
                    """
                alert.addButton(withTitle: "Restore Credentials")
                alert.addButton(withTitle: "Import Without Credentials")
                alert.addButton(withTitle: "Cancel")

                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    credentialPolicy = .restoreFromBackup
                case .alertSecondButtonReturn:
                    credentialPolicy = .preserveCurrent
                default:
                    return
                }
            }

            let importTask = SettingsMutationCoordinator.shared.enqueue { [weak self] in
                let importResult = await PreferencesDataModel.importFromPlist(
                    plan: importPlan,
                    credentialPolicy: credentialPolicy
                )
                guard let self else { return }
                switch importResult {
                case .invalid:
                    self.advancedNotice = "Settings import failed because the file is invalid."
                case .credentialStorageFailed:
                    self.advancedNotice = """
                        Settings were not imported because the credentials could not be saved to protected storage.
                        """
                case .success(
                    let integrationsRequiringReview,
                    let ignoredFields,
                    let restoredCredentialIntegrations,
                    let excludedCredentialIntegrations
                ):
                    var details: [String] = []
                    if !restoredCredentialIntegrations.isEmpty {
                        details.append(
                            "Credentials restored: "
                                + restoredCredentialIntegrations.joined(separator: ", ")
                        )
                    }
                    if !excludedCredentialIntegrations.isEmpty {
                        details.append(
                            "Backup credentials not restored: "
                                + excludedCredentialIntegrations.joined(separator: ", ")
                        )
                    }
                    if !integrationsRequiringReview.isEmpty {
                        details.append(
                            "Review: " + integrationsRequiringReview.joined(separator: ", ")
                        )
                    }
                    if !ignoredFields.isEmpty {
                        details.append("Ignored: " + ignoredFields.joined(separator: ", "))
                    }
                    self.advancedNotice = details.isEmpty
                        ? "Settings imported successfully."
                        : "Settings imported. " + details.joined(separator: ". ") + "."
                    self.refreshCapabilities()
                    self.reloadCleanDestinationDrafts()
                }
            }
            if importTask == nil {
                advancedNotice = "Settings cannot be imported while maintenance is running."
            }
        } catch {
            advancedNotice = "Settings import failed: \(error.localizedDescription)"
        }
    }

    func openDatabaseLocation() {
        guard let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first,
            let bundleIdentifier = Bundle.main.bundleIdentifier
        else {
            advancedNotice = "The database location is unavailable."
            return
        }

        let directoryURL = applicationSupportURL.appendingPathComponent(bundleIdentifier)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directoryURL.path)
    }

    func checkForUpdates() {
        (NSApp.delegate as? AppDelegate)?.checkForUpdates(nil)
    }

    func configurationStatus(for destination: SettingsDestination) -> SettingsConfigurationStatus {
        switch destination {
        case .mixSpace:
            return SettingsConfigurationStatus(
                isConfigured: mixSpaceIntegration.hasPresenceDestinationConfiguration,
                isValid: mixSpaceIntegration.isValidPresenceDestination,
                isEnabled: mixSpaceIntegration.isEnabled,
                isLoadingCredentials: !credentialsReady
            )
        case .slack:
            return SettingsConfigurationStatus(
                isConfigured: slackIntegration.hasPresenceDestinationConfiguration,
                isValid: slackIntegration.isValidPresenceDestination,
                isEnabled: slackIntegration.isEnabled,
                isLoadingCredentials: !credentialsReady
            )
        case .discord:
            return SettingsConfigurationStatus(
                isConfigured: discordIntegration.hasPresenceDestinationConfiguration,
                isValid: discordIntegration.isValidPresenceDestination,
                isEnabled: discordIntegration.isEnabled,
                isLoadingCredentials: false
            )
        case .applicationIconHosting:
            return SettingsConfigurationStatus(
                isConfigured: s3Integration.hasAssetHostingConfiguration,
                isValid: s3Integration.isValidAssetHostingConfiguration,
                isEnabled: s3Integration.isEnabled,
                isLoadingCredentials: !credentialsReady
            )
        }
    }

    func isDestinationDirty(_ destination: SettingsDestination) -> Bool {
        switch destination {
        case .mixSpace:
            return mixSpaceDraft != mixSpaceDraftBaseline
        case .slack:
            return slackDraft != slackDraftBaseline
        case .discord:
            return discordDraft != discordDraftBaseline
        case .applicationIconHosting:
            return s3Draft != s3DraftBaseline
        }
    }

    var activeDirtyDestination: SettingsDestination? {
        if selectedSection == .destinations,
           let destination = destinationPath.last,
           isDestinationDirty(destination)
        {
            return destination
        }
        return nil
    }

    var anyDirtyDestination: SettingsDestination? {
        activeDirtyDestination
            ?? (SettingsDestination.presenceDestinations + [.applicationIconHosting])
                .first(where: isDestinationDirty)
    }

    func discardDestinationDraft(_ destination: SettingsDestination) {
        guard destinationBusy == nil else { return }
        switch destination {
        case .mixSpace:
            mixSpaceDraft = mixSpaceDraftBaseline
        case .slack:
            slackDraft = slackDraftBaseline
        case .discord:
            discordDraft = discordDraftBaseline
        case .applicationIconHosting:
            s3Draft = s3DraftBaseline
        }
        destinationNotices[destination] = nil
    }

    func saveWouldDisableLastReadyDestination(_ destination: SettingsDestination) -> Bool {
        guard destination != .applicationIconHosting else { return false }
        let currentReady = isReadyDestination(destination)
        guard currentReady, !proposedDestinationIsReady(destination) else { return false }
        return SettingsDestination.presenceDestinations
            .filter { $0 != destination }
            .allSatisfy { !isReadyDestination($0) }
    }

    func saveDestination(
        _ destination: SettingsDestination,
        allowDisablingLastReadyDestination: Bool = false
    ) async -> DestinationSaveResult {
        guard destinationBusy == nil else {
            return .failed("Another destination operation is already in progress.")
        }
        if destination != .discord, !credentialsReady {
            return .failed("Wait for protected credentials to finish loading.")
        }
        if saveWouldDisableLastReadyDestination(destination),
           !allowDisablingLastReadyDestination
        {
            return .failed("Confirm that Presence sharing should stop before saving this change.")
        }
        if let validationMessage = validationMessage(for: destination) {
            let result = DestinationSaveResult.failed(validationMessage)
            destinationNotices[destination] = .init(kind: .failure, message: validationMessage)
            return result
        }

        let draftSnapshot = destinationDraftSnapshot(for: destination)

        destinationBusy = destination
        destinationNotices[destination] = nil
        defer { destinationBusy = nil }

        do {
            let credentialResult: CredentialStore.ApplyResult? = try await SettingsMutationCoordinator
                .shared.perform {
                    switch draftSnapshot {
                    case .mixSpace(let draft):
                        let previous = PreferencesDataModel.mixSpaceIntegration.value
                        let requested = draft.applying(to: previous)
                        let result = await requested.persistCredentialChanges(comparedTo: previous)
                        guard result.succeeded else { throw DestinationSettingsError.persistenceFailed }
                        PreferencesDataModel.mixSpaceIntegration.accept(requested)
                        PreferencesDataModel.pauseReportingIfDestinationUnavailable()
                        return result
                    case .slack(let draft):
                        let previous = PreferencesDataModel.slackIntegration.value
                        let requested = draft.applying(to: previous)
                        let result = await requested.persistCredentialChanges(comparedTo: previous)
                        guard result.succeeded else { throw DestinationSettingsError.persistenceFailed }
                        PreferencesDataModel.slackIntegration.accept(requested)
                        PreferencesDataModel.pauseReportingIfDestinationUnavailable()
                        return result
                    case .discord(let draft):
                        let previous = PreferencesDataModel.discordIntegration.value
                        let requested = draft.applying(to: previous)
                        PreferencesDataModel.discordIntegration.accept(requested)
                        PreferencesDataModel.pauseReportingIfDestinationUnavailable()
                        return nil
                    case .s3(let draft):
                        let previous = PreferencesDataModel.s3Integration.value
                        let requested = draft.applying(to: previous)
                        let result = await requested.persistCredentialChanges(comparedTo: previous)
                        guard result.succeeded else { throw DestinationSettingsError.persistenceFailed }
                        PreferencesDataModel.s3Integration.accept(requested)
                        return result
                    }
                }

            if draftSnapshot == destinationDraftSnapshot(for: destination) {
                resetDraft(destination)
            }
            refreshCapabilities()
            destinationNotices[destination] = credentialNotice(for: credentialResult)
            return .saved
        } catch {
            let message = error.localizedDescription
            destinationNotices[destination] = .init(kind: .failure, message: message)
            return .failed(message)
        }
    }

    func testDestination(_ destination: SettingsDestination) async {
        guard destinationBusy == nil else { return }
        if destination != .discord, !credentialsReady {
            destinationNotices[destination] = .init(
                kind: .warning,
                message: "Wait for protected credentials to finish loading."
            )
            return
        }
        if let validationMessage = validationMessage(for: destination, requireEnabled: false) {
            destinationNotices[destination] = .init(kind: .failure, message: validationMessage)
            return
        }

        destinationBusy = destination
        destinationNotices[destination] = nil
        defer { destinationBusy = nil }

        do {
            let successMessage: String
            switch destination {
            case .mixSpace:
                successMessage = try await testMixSpaceDraft()
            case .slack:
                successMessage = try await testSlackDraft()
            case .discord:
                successMessage = try await testDiscordDraft()
            case .applicationIconHosting:
                successMessage = try await testS3Draft()
            }
            destinationNotices[destination] = .init(kind: .success, message: successMessage)
        } catch is CancellationError {
            destinationNotices[destination] = nil
        } catch {
            destinationNotices[destination] = .init(
                kind: .failure,
                message: "Test failed: \(error.localizedDescription)"
            )
        }
    }

    func refreshIconCacheCount() async {
        iconCacheCount = try? await DataStore.shared.iconCount()
        failedIconUploadCount = S3AssetHostingService.failedUploadCount
    }

    func retryFailedApplicationIconUploads() async {
        await performApplicationIconMaintenance(operationName: "retry") {
            try await S3AssetHostingService.retryFailedUploads()
        }
    }

    func rebuildApplicationIconCache() async {
        await performApplicationIconMaintenance(operationName: "rebuild") {
            try await S3AssetHostingService.rebuildCachedIcons()
        }
    }

    func refreshDestinationPreview() async {
        isLoadingDestinationPreview = true
        destinationPreview = await PresencePreviewService.captureCurrent()
        isLoadingDestinationPreview = false
    }

    func refreshDestinationActivity() async {
        guard let events = try? await DataStore.shared.fetchSyncEvents() else { return }
        var latest: [SettingsDestination: DestinationRecentActivity] = [:]

        for destination in SettingsDestination.presenceDestinations {
            guard let destinationID = destination.presenceDestinationID else { continue }
            for event in events {
                guard let delivery = event.deliveryResults.first(where: {
                    $0.destinationID == destinationID.rawValue
                }) else { continue }
                latest[destination] = DestinationRecentActivity(
                    resultText: delivery.status.displayName.lowercased(),
                    occurredAt: delivery.finishedAt ?? event.capturedAt,
                    isFailure: delivery.status == .failed
                )
                break
            }
        }

        for event in events {
            guard let asset = event.assetResult,
                  asset.status != .notRequested,
                  asset.status != .notConfigured
            else { continue }
            latest[.applicationIconHosting] = DestinationRecentActivity(
                resultText: asset.status.displayName.lowercased(),
                occurredAt: event.capturedAt,
                isFailure: asset.status == .failed
            )
            break
        }

        latestDestinationActivity = latest
    }

    func clearApplicationIconCache() async {
        guard destinationBusy == nil else { return }
        destinationBusy = .applicationIconHosting
        defer { destinationBusy = nil }
        do {
            try await DataStore.shared.deleteAllIcons()
            S3AssetHostingService.clearStoredUploadFingerprints()
            S3AssetHostingService.clearFailedUploads()
            iconCacheCount = 0
            failedIconUploadCount = 0
            destinationNotices[.applicationIconHosting] = .init(
                kind: .success,
                message: "Local icon URL records, upload fingerprints, and failed-upload queue were cleared. Remote S3 objects were not deleted."
            )
        } catch {
            destinationNotices[.applicationIconHosting] = .init(
                kind: .failure,
                message: "The icon cache could not be cleared: \(error.localizedDescription)"
            )
        }
    }

    private func performApplicationIconMaintenance(
        operationName: String,
        operation: () async throws -> AssetHostingMaintenanceResult
    ) async {
        guard destinationBusy == nil else { return }
        guard !isDestinationDirty(.applicationIconHosting) else {
            destinationNotices[.applicationIconHosting] = .init(
                kind: .warning,
                message: "Save or discard the Application Icon Hosting draft before maintenance."
            )
            return
        }

        destinationBusy = .applicationIconHosting
        defer { destinationBusy = nil }
        do {
            let result = try await operation()
            await refreshIconCacheCount()
            let message: String
            if result.attempted == 0 {
                message = operationName == "retry"
                    ? "No failed application icon uploads are queued."
                    : "No cached application icons are available to rebuild."
            } else if result.failed == 0 {
                message = "Successfully processed \(result.succeeded) application icon upload(s)."
            } else {
                message = "Processed \(result.succeeded) of \(result.attempted) application icon upload(s); \(result.failed) remain queued."
            }
            destinationNotices[.applicationIconHosting] = .init(
                kind: result.failed == 0 ? .success : .warning,
                message: message
            )
        } catch {
            failedIconUploadCount = S3AssetHostingService.failedUploadCount
            destinationNotices[.applicationIconHosting] = .init(
                kind: .failure,
                message: "Application icon maintenance failed: \(error.localizedDescription)"
            )
        }
    }

    private func resetDraft(_ destination: SettingsDestination) {
        switch destination {
        case .mixSpace:
            let draft = MixSpaceDestinationDraft(
                integration: PreferencesDataModel.mixSpaceIntegration.value
            )
            mixSpaceDraft = draft
            mixSpaceDraftBaseline = draft
        case .slack:
            let draft = SlackDestinationDraft(
                integration: PreferencesDataModel.slackIntegration.value
            )
            slackDraft = draft
            slackDraftBaseline = draft
        case .discord:
            let draft = DiscordDestinationDraft(
                integration: PreferencesDataModel.discordIntegration.value
            )
            discordDraft = draft
            discordDraftBaseline = draft
        case .applicationIconHosting:
            let draft = S3DestinationDraft(
                integration: PreferencesDataModel.s3Integration.value
            )
            s3Draft = draft
            s3DraftBaseline = draft
        }
    }

    private func destinationDraftSnapshot(
        for destination: SettingsDestination
    ) -> DestinationDraftSnapshot {
        switch destination {
        case .mixSpace:
            return .mixSpace(mixSpaceDraft)
        case .slack:
            return .slack(slackDraft)
        case .discord:
            return .discord(discordDraft)
        case .applicationIconHosting:
            return .s3(s3Draft)
        }
    }

    private func reloadCleanDestinationDrafts() {
        for destination in SettingsDestination.presenceDestinations + [.applicationIconHosting]
            where !isDestinationDirty(destination)
        {
            resetDraft(destination)
        }
    }

	/// Replaces every editor snapshot after Reset or Erase, irrespective of dirty
	/// state. Maintenance publishes this while its exclusive coordinator gate is
	/// still closed, so no pre-maintenance draft can be saved after the gate opens.
	func invalidateDestinationDraftsAfterMaintenance() {
		mixSpaceIntegration = PreferencesDataModel.mixSpaceIntegration.value
		slackIntegration = PreferencesDataModel.slackIntegration.value
		discordIntegration = PreferencesDataModel.discordIntegration.value
		s3Integration = PreferencesDataModel.s3Integration.value

		for destination in SettingsDestination.presenceDestinations
			+ [.applicationIconHosting]
		{
			resetDraft(destination)
		}
		destinationNotices.removeAll()
		refreshCapabilities()
	}

    private func credentialNotice(
        for result: CredentialStore.ApplyResult?
    ) -> DestinationOperationNotice {
        guard let result else {
            return .init(kind: .success, message: "Configuration saved.")
        }
        var warnings: [String] = []
        if result.retainedClearedKeychainValue {
            warnings.append("an inaccessible Keychain copy may remain")
        }
        if result.usedLocalFallback {
            warnings.append("credentials were stored in the protected local fallback")
        }
        if warnings.isEmpty {
            return .init(kind: .success, message: "Configuration and credentials saved.")
        }
        return .init(kind: .warning, message: "Saved, but " + warnings.joined(separator: "; ") + ".")
    }

    private func isReadyDestination(_ destination: SettingsDestination) -> Bool {
        switch destination {
        case .mixSpace:
            return mixSpaceIntegration.isEnabled && mixSpaceIntegration.isValidPresenceDestination
        case .slack:
            return slackIntegration.isEnabled && slackIntegration.isValidPresenceDestination
        case .discord:
            return discordIntegration.isEnabled && discordIntegration.isValidPresenceDestination
        case .applicationIconHosting:
            return false
        }
    }

    private func proposedDestinationIsReady(_ destination: SettingsDestination) -> Bool {
        switch destination {
        case .mixSpace:
            let integration = mixSpaceDraft.applying(to: mixSpaceIntegration)
            return integration.isEnabled && integration.isValidPresenceDestination
        case .slack:
            let integration = slackDraft.applying(to: slackIntegration)
            return integration.isEnabled && integration.isValidPresenceDestination
        case .discord:
            let integration = discordDraft.applying(to: discordIntegration)
            return integration.isEnabled && integration.isValidPresenceDestination
        case .applicationIconHosting:
            return false
        }
    }

    private func validationMessage(
        for destination: SettingsDestination,
        requireEnabled: Bool = true
    ) -> String? {
        switch destination {
        case .mixSpace:
            let integration = mixSpaceDraft.applying(to: mixSpaceIntegration)
            let requiresCompleteConfiguration = requireEnabled ? integration.isEnabled : true
            if mixSpaceDraft.token.hasIncompleteStoredReplacement {
                return "Enter a replacement API token, keep the stored token, or remove it explicitly."
            }
            if requiresCompleteConfiguration && !mixSpaceDraft.token.hasEffectiveValue {
                return "An API token is required."
            }
            if requiresCompleteConfiguration || !integration.endpoint.isEmpty {
                guard let components = URLComponents(string: integration.endpoint),
                      let scheme = components.scheme?.lowercased(),
                      let host = components.host,
                      components.user == nil,
                      components.password == nil,
                      components.url != nil,
                      scheme == "https" || (scheme == "http" && isLoopbackHost(host))
                else {
                    return "The endpoint must use HTTPS; HTTP is allowed only for localhost."
                }
            }
            guard ["POST", "PUT", "PATCH", "DELETE"].contains(integration.requestMethod) else {
                return "Select a supported request method."
            }
        case .slack:
            let integration = slackDraft.applying(to: slackIntegration)
            let requiresCompleteConfiguration = requireEnabled ? integration.isEnabled : true
            if slackDraft.token.hasIncompleteStoredReplacement {
                return "Enter a replacement Slack token, keep the stored token, or remove it explicitly."
            }
            if requiresCompleteConfiguration && !slackDraft.token.hasEffectiveValue {
                return "A Slack User OAuth token is required."
            }
            guard (1 ... 86_400).contains(integration.expiration) else {
                return "Status expiration must be between 1 and 86,400 seconds."
            }
            if requiresCompleteConfiguration && integration.statusTextTemplateString
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return "A status text template is required when Slack is enabled."
            }
            for (index, condition) in slackDraft.conditions.enumerated() {
                if condition.legacyExpression != nil {
                    return "Slack emoji condition \(index + 1) is a legacy expression. Convert or remove it before saving."
                }
                let value = condition.value.trimmingCharacters(in: .whitespacesAndNewlines)
                let emoji = condition.emoji.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, !emoji.isEmpty else {
                    return "Slack emoji condition \(index + 1) requires both a value and an emoji."
                }
                guard !value.contains("\"") else {
                    return "Slack emoji condition values cannot contain quotation marks."
                }
                guard EmojiConditionList.EmojiCondition.Variable(rawValue: condition.variable) != nil,
                      EmojiConditionList.EmojiCondition.Condition(rawValue: condition.comparison) != nil
                else {
                    return "Slack emoji condition \(index + 1) has an unsupported field or operator."
                }
            }
        case .discord:
            let integration = discordDraft.applying(to: discordIntegration)
            let requiresCompleteConfiguration = requireEnabled ? integration.isEnabled : true
            if requiresCompleteConfiguration {
                guard let value = Int64(integration.applicationId), value > 0 else {
                    return "The Discord Application ID must be a positive integer."
                }
            } else if !integration.applicationId.isEmpty,
                      (Int64(integration.applicationId) ?? 0) <= 0
            {
                return "The Discord Application ID must be a positive integer."
            }
            if requiresCompleteConfiguration
                && !integration.showProcessInfo
                && !integration.showMediaInfo
            {
                return "Enable application content, media content, or both."
            }
        case .applicationIconHosting:
            let integration = s3Draft.applying(to: s3Integration)
            let requiresCompleteConfiguration = requireEnabled ? integration.isEnabled : true
            if s3Draft.accessKey.hasIncompleteStoredReplacement
                || s3Draft.secretKey.hasIncompleteStoredReplacement
            {
                return "Complete each credential replacement, keep the stored value, or remove it explicitly."
            }
            if requiresCompleteConfiguration,
               !s3Draft.accessKey.hasEffectiveValue || !s3Draft.secretKey.hasEffectiveValue
            {
                return "Both an access key and a secret key are required."
            }
            if requiresCompleteConfiguration,
               [integration.bucket, integration.region].contains(where: { $0.isEmpty })
            {
                return "Bucket and region are required."
            }
            for (label, value) in [
                ("endpoint", integration.endpoint),
                ("public URL prefix", integration.customDomain),
            ] where !value.isEmpty {
                guard validatedSecurePublicURL(value) != nil else {
                    return "The \(label) must use HTTPS; HTTP is allowed only for localhost."
                }
            }
        }
        return nil
    }

    private func testMixSpaceDraft() async throws -> String {
        let integration = mixSpaceDraft.applying(to: mixSpaceIntegration)
        let preview = await PresencePreviewService.captureCurrent()
        guard preview.hasShareableContent else {
            throw DestinationSettingsError.providerMessage(
                "Nothing is shareable after Privacy & Rules"
            )
        }
        guard let url = URL(string: integration.endpoint) else {
            throw DestinationSettingsError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = integration.requestMethod
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var process: [String: Any] = [
            "iconBase64": NSNull(),
            "iconUrl": NSNull(),
        ]
        if let applicationName = preview.applicationName { process["name"] = applicationName }
        if let windowTitle = preview.windowTitle { process["description"] = windowTitle }
        var media: [String: Any] = [:]
        if let title = preview.mediaTitle { media["title"] = title }
        if let artist = preview.mediaArtist { media["artist"] = artist }
        if let applicationName = preview.mediaApplicationName {
            media["processName"] = applicationName
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "key": integration.apiToken,
            "timestamp": UInt(Date().timeIntervalSince1970),
            "process": process,
            "media": media.isEmpty ? NSNull() : media,
        ])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode)
        else {
            throw DestinationSettingsError.providerRejected
        }
        return "MixSpace accepted the test Presence payload."
    }

    private func testSlackDraft() async throws -> String {
        let draft = slackDraft
        let integration = draft.applying(to: slackIntegration)
        let preview = await PresencePreviewService.captureCurrent()
        guard preview.hasShareableContent,
              let renderedStatus = renderSlackDraft(draft: draft, using: preview)
        else {
            throw DestinationSettingsError.providerMessage(
                "Nothing is shareable to Slack after Privacy & Rules"
            )
        }
        guard let url = URL(string: "https://slack.com/api/users.profile.set") else {
            throw DestinationSettingsError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(integration.apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "profile": [
                "status_text": renderedStatus.text,
                "status_emoji": renderedStatus.emoji,
                "status_expiration": Int(Date().timeIntervalSince1970) + integration.expiration,
            ],
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode)
        else {
            throw DestinationSettingsError.providerRejected
        }
        let decoded = try JSONDecoder().decode(SlackDestinationTestResponse.self, from: data)
        guard decoded.ok else {
            throw DestinationSettingsError.providerMessage(decoded.error ?? "unknown_error")
        }
        return "Slack accepted the temporary status with the draft expiration."
    }

    private func testDiscordDraft() async throws -> String {
        let integration = discordDraft.applying(to: discordIntegration)
        let preview = await PresencePreviewService.captureCurrent()
        let hasMedia = preview.mediaTitle?.isEmpty == false
        let hasApplication = preview.applicationName?.isEmpty == false
        let showsMedia = integration.showMediaInfo && hasMedia
            && (integration.prioritizeMedia || !integration.showProcessInfo || !hasApplication)
        let details: String?
        let state: String?
        let activityType: DiscordActivityType?
        if showsMedia {
            details = preview.mediaTitle
            state = preview.mediaArtist
            activityType = integration.useListeningForMedia ? .listening : nil
        } else if integration.showProcessInfo, hasApplication {
            details = preview.applicationName
            state = preview.windowTitle
            activityType = nil
        } else {
            throw DestinationSettingsError.providerMessage(
                "Nothing is shareable to Discord after Privacy & Rules"
            )
        }
        let savedIntegration = PreferencesDataModel.discordIntegration.value
        try? await DiscordClientProvider.shared.clearActivity()
        DiscordClientProvider.shared.shutdown()
        DiscordClientProvider.shared.initialize(applicationId: integration.applicationId)
        try await Task.sleep(nanoseconds: 750_000_000)
        guard DiscordClientProvider.shared.isConnected else {
            restoreDiscordConnection(savedIntegration)
            throw DestinationSettingsError.providerMessage(
                DiscordClientProvider.shared is NoopDiscordClient
                    ? "Discord SDK is unavailable"
                    : "Discord is not running or rejected the Application ID"
            )
        }
        do {
            try await DiscordClientProvider.shared.setActivity(
                details: details,
                state: state,
                activityType: activityType,
                startTimestamp: integration.showTimestamps
                    ? Int64(Date().timeIntervalSince1970) : nil,
                endTimestamp: nil,
                largeImageKey: integration.customLargeImageKey.isEmpty
                    ? nil : integration.customLargeImageKey,
                largeImageText: nil,
                smallImageKey: integration.brandSmallImageKey.isEmpty
                    ? nil : integration.brandSmallImageKey,
                smallImageText: "ProcessReporter",
                buttons: nil
            )
        } catch {
            DiscordClientProvider.shared.shutdown()
            restoreDiscordConnection(savedIntegration)
            throw error
        }
        do {
            try await DiscordClientProvider.shared.clearActivity()
        } catch {
            DiscordClientProvider.shared.shutdown()
            restoreDiscordConnection(savedIntegration)
            throw error
        }
        DiscordClientProvider.shared.shutdown()
        restoreDiscordConnection(savedIntegration)
        return "Discord accepted and then cleared the temporary Rich Presence."
    }

    private func restoreDiscordConnection(_ integration: DiscordIntegration) {
        guard integration.isEnabled, integration.isValidPresenceDestination else { return }
        DiscordClientProvider.shared.initialize(applicationId: integration.applicationId)
    }

    private func renderSlackDraft(
        draft: SlackDestinationDraft,
        using preview: PresenceReviewPreview
    ) -> (text: String, emoji: String)? {
        var text = draft.statusTextTemplateString
        if let value = preview.applicationName {
            text = text.replacingOccurrences(of: "{process_name}", with: value)
        }
        if let value = preview.mediaApplicationName {
            text = text.replacingOccurrences(of: "{media_process_name}", with: value)
        }
        if let value = preview.mediaTitle {
            text = text.replacingOccurrences(of: "{media_name}", with: value)
        }
        if let value = preview.mediaArtist {
            text = text.replacingOccurrences(of: "{artist}", with: value)
        }
        if let title = preview.mediaTitle, let artist = preview.mediaArtist {
            text = text.replacingOccurrences(
                of: "{media_name_artist}",
                with: "\(artist) - \(title)"
            )
        }

        let unresolvedTokens = [
            "{process_name}", "{media_process_name}", "{media_name}",
            "{artist}", "{media_name_artist}",
        ]
        var emoji = draft.globalCustomEmoji
        if unresolvedTokens.contains(where: { text.contains($0) }) {
            text = draft.defaultStatusText
            emoji = draft.defaultEmoji
        } else {
            for condition in draft.conditions where condition.legacyExpression == nil {
                guard let parsed = EmojiConditionList.EmojiCondition.parseWhenString(
                    for: condition.whenExpression
                ) else { continue }
                let candidate: String?
                switch parsed.variable {
                case .processName: candidate = preview.applicationName
                case .mediaProcessName: candidate = preview.mediaApplicationName
                case .mediaName: candidate = preview.mediaTitle
                case .artist: candidate = preview.mediaArtist
                case .processApplicationIdentifier:
                    candidate = preview.applicationIdentifier
                case .mediaProcessApplicationIdentifier:
                    candidate = preview.mediaApplicationIdentifier
                }
                guard let candidate else { continue }
                let matches: Bool
                switch parsed.condition {
                case .equals: matches = candidate == parsed.value
                case .startsWith: matches = candidate.hasPrefix(parsed.value)
                case .endsWith: matches = candidate.hasSuffix(parsed.value)
                case .contains: matches = candidate.contains(parsed.value)
                }
                if matches {
                    emoji = condition.emoji
                    break
                }
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return (text, emoji)
    }

    private func testS3Draft() async throws -> String {
        let integration = s3Draft.applying(to: s3Integration)
        let panel = NSOpenPanel()
        panel.title = "Select an Application Icon to Upload"
        panel.prompt = "Upload Test Icon"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        guard panel.runModal() == .OK, let applicationURL = panel.url else {
            throw CancellationError()
        }
        let icon = NSWorkspace.shared.icon(forFile: applicationURL.path)
        guard let iconData = icon.data else {
            throw DestinationSettingsError.providerMessage("The selected application icon could not be encoded")
        }
        let publicURLString: String
        do {
            publicURLString = try await S3Uploader.uploadIconToS3(
                iconData,
                appName: applicationURL.lastPathComponent,
                config: integration
            )
        } catch let error as S3UploaderError {
            switch error {
            case .uploadFailed(let statusCode, _):
                throw DestinationSettingsError.providerMessage(
                    "S3 rejected the upload with HTTP \(statusCode)"
                )
            case .missingConfiguration(let field):
                throw DestinationSettingsError.providerMessage(
                    "The S3 \(field) configuration is missing"
                )
            case .invalidEndpoint:
                throw DestinationSettingsError.providerMessage("The S3 endpoint is invalid")
            case .insecureEndpoint:
                throw DestinationSettingsError.providerMessage(
                    "The S3 endpoint must use HTTPS except on localhost"
                )
            case .invalidObjectKey:
                throw DestinationSettingsError.providerMessage("The S3 object path is invalid")
            }
        }
        guard let publicURL = validatedSecurePublicURL(publicURLString) else {
            throw DestinationSettingsError.providerMessage(
                "The upload returned an invalid or insecure public URL"
            )
        }
        var request = URLRequest(url: publicURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode)
        else {
            throw DestinationSettingsError.providerMessage(
                "The uploaded object was not publicly readable with an unauthenticated GET"
            )
        }
        return "The test icon was uploaded and verified as publicly readable. The remote object was retained."
    }

    private func updateSource(_ type: Reporter.Types, isEnabled: Bool) {
        var types = PreferencesDataModel.enabledTypes.value.types
        if isEnabled {
            types.insert(type)
        } else {
            types.remove(type)
        }
        PreferencesDataModel.enabledTypes.accept(ReporterTypesSet(types: types))
    }

	private func bindMaintenanceInvalidation() {
		// SettingsMaintenanceService is MainActor-isolated and NotificationCenter
		// delivers this notification synchronously. Do not introduce an async hop:
		// draft invalidation must finish before exclusive admission is reopened.
		NotificationCenter.default.rx
			.notification(.settingsMaintenanceDidInvalidateDestinationDrafts)
			.subscribe(onNext: { [weak self] _ in
				self?.invalidateDestinationDraftsAfterMaintenance()
			})
			.disposed(by: disposeBag)
	}

	private func bindDestinationActivityInvalidation() {
		NotificationCenter.default.rx
			.notification(DataStore.changedNotification)
			.subscribe(onNext: { [weak self] _ in
				Task { @MainActor [weak self] in
					await self?.refreshDestinationActivity()
				}
			})
			.disposed(by: disposeBag)
	}

    private func bindAssetHostingFailureInvalidation() {
        NotificationCenter.default.rx
            .notification(.assetHostingFailedUploadsDidChange)
            .subscribe(onNext: { [weak self] _ in
                self?.failedIconUploadCount = S3AssetHostingService.failedUploadCount
            })
            .disposed(by: disposeBag)
    }

    private func bindPreferences() {
        PreferencesDataModel.isEnabled
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] _ in
                self?.reportingEnabled = PreferencesDataModel.reportingAllowed
            })
            .disposed(by: disposeBag)

        PreferencesDataModel.hasCompletedOnboarding
            .distinctUntilChanged()
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] value in
                self?.onboardingCompleted = value
            })
            .disposed(by: disposeBag)

        PreferencesDataModel.enabledTypes
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] value in
                self?.applicationsEnabled = value.types.contains(.process)
                self?.mediaEnabled = value.types.contains(.media)
            })
            .disposed(by: disposeBag)

        PreferencesDataModel.shareWindowTitles
            .distinctUntilChanged()
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] value in
                self?.windowTitlesEnabled = value
            })
            .disposed(by: disposeBag)

        PreferencesDataModel.sendInterval
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] value in
                self?.sendInterval = value
            })
            .disposed(by: disposeBag)

        PreferencesDataModel.focusReport
            .distinctUntilChanged()
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] value in
                self?.focusReportingEnabled = value
            })
            .disposed(by: disposeBag)

        PreferencesDataModel.ignoreNullArtist
            .distinctUntilChanged()
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] value in
                self?.ignoreMissingArtist = value
            })
            .disposed(by: disposeBag)

        PreferencesDataModel.integrationCredentialsReady
            .distinctUntilChanged()
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] isReady in
                self?.credentialsReady = isReady
                self?.refreshCapabilities()
            })
            .disposed(by: disposeBag)

        PreferencesDataModel.mixSpaceIntegration
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] value in
                guard let self else { return }
                let shouldReloadDraft = !self.isDestinationDirty(.mixSpace)
                self.mixSpaceIntegration = value
                if shouldReloadDraft {
                    self.resetDraft(.mixSpace)
                } else {
                    self.mixSpaceDraftBaseline = MixSpaceDestinationDraft(integration: value)
                }
                self.clearDestinationRequirementNoticeIfResolved()
            })
            .disposed(by: disposeBag)

        PreferencesDataModel.slackIntegration
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] value in
                guard let self else { return }
                let shouldReloadDraft = !self.isDestinationDirty(.slack)
                self.slackIntegration = value
                if shouldReloadDraft {
                    self.resetDraft(.slack)
                } else {
                    self.slackDraftBaseline = SlackDestinationDraft(integration: value)
                }
                self.clearDestinationRequirementNoticeIfResolved()
            })
            .disposed(by: disposeBag)

        PreferencesDataModel.discordIntegration
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] value in
                guard let self else { return }
                let shouldReloadDraft = !self.isDestinationDirty(.discord)
                self.discordIntegration = value
                if shouldReloadDraft {
                    self.resetDraft(.discord)
                } else {
                    self.discordDraftBaseline = DiscordDestinationDraft(integration: value)
                }
                self.clearDestinationRequirementNoticeIfResolved()
            })
            .disposed(by: disposeBag)

        PreferencesDataModel.s3Integration
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] value in
                guard let self else { return }
                let shouldReloadDraft = !self.isDestinationDirty(.applicationIconHosting)
                self.s3Integration = value
                if shouldReloadDraft {
                    self.resetDraft(.applicationIconHosting)
                } else {
                    self.s3DraftBaseline = S3DestinationDraft(integration: value)
                }
            })
            .disposed(by: disposeBag)
    }

    private func clearDestinationRequirementNoticeIfResolved() {
        guard canStartSharingAfterOnboarding,
              generalNotice == "Set up and enable a destination before sharing Presence."
        else { return }
        generalNotice = nil
    }
}

private struct SlackDestinationTestResponse: Decodable {
    let ok: Bool
    let error: String?
}

private enum DestinationDraftSnapshot: Equatable {
    case mixSpace(MixSpaceDestinationDraft)
    case slack(SlackDestinationDraft)
    case discord(DiscordDestinationDraft)
    case s3(S3DestinationDraft)
}

private enum DestinationSettingsError: LocalizedError {
    case invalidConfiguration
    case persistenceFailed
    case providerRejected
    case providerMessage(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "The draft configuration is invalid."
        case .persistenceFailed:
            return "The configuration or protected credentials could not be saved."
        case .providerRejected:
            return "The provider rejected the test request."
        case .providerMessage(let message):
            return message
        }
    }
}
