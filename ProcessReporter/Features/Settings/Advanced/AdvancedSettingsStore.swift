import AppKit
import Foundation

private struct DiagnosticsSnapshot: Codable {
    let applicationVersion: String
    let buildNumber: String
    let credentialStorage: String
    let databaseStatus: String
    let mediaProvider: String
    let accessibilityGranted: Bool
    let sharingEnabled: Bool
    let enabledDestinationCount: Int
    let syncHistoryCount: Int
    let iconCacheCount: Int
    let lastSafeErrorCode: String?
    let lastSafeErrorMessage: String?
    let lastSafeErrorDate: Date?
}

@MainActor
final class AdvancedSettingsStore: ObservableObject {
    @Published private(set) var historyCount = 0
    @Published private(set) var iconCount = 0
    @Published private(set) var isLoadingCounts = false
    @Published var notice: String?

    var applicationVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "Unknown"
    }

    var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "Unknown"
    }

    var isUpdaterAvailable: Bool {
        (NSApp.delegate as? AppDelegate)?.isUpdaterAvailable == true
    }

    var updaterDescription: String {
        (NSApp.delegate as? AppDelegate)?.updaterAvailabilityDescription
            ?? "Update service status is unavailable."
    }

    var databaseLocation: String {
        guard let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first,
            let bundleIdentifier = Bundle.main.bundleIdentifier
        else { return "Unavailable" }
        return baseURL.appendingPathComponent(bundleIdentifier).path
    }

    var lastErrorDescription: String {
        guard let lastError = PresenceDiagnosticsState.shared.lastError else {
            return "No non-sensitive runtime error has been recorded."
        }
        return "\(lastError.code): \(lastError.message)"
    }

    func refresh() async {
        isLoadingCounts = true
        async let historyResult = DataStore.shared.reportCount()
        async let iconResult = DataStore.shared.iconCount()

        do {
            let (historyCount, iconCount) = try await (historyResult, iconResult)
            self.historyCount = historyCount
            self.iconCount = iconCount
        } catch {
            notice = "Local storage counts could not be loaded."
            NSLog("Advanced storage metrics failed: \(error.localizedDescription)")
        }
        isLoadingCounts = false
    }

    func clearHistory() async {
        do {
            try await DataStore.shared.deleteAllReports()
            notice = "Sync History was cleared."
            await refresh()
        } catch {
            notice = "Sync History could not be cleared."
        }
    }

    func clearIconCache() async {
        do {
            try await DataStore.shared.deleteAllIcons()
            S3AssetHostingService.clearStoredUploadFingerprints()
            S3AssetHostingService.clearFailedUploads()
            notice = "The local application icon cache and failed-upload queue were cleared. Remote S3 objects were not deleted."
            await refresh()
        } catch {
            notice = "The local application icon cache could not be cleared."
        }
    }

    func resetSettings() async {
        do {
            try await SettingsMaintenanceService.resetSettings()
            notice = "Settings were reset. Sync History, icon cache, and protected credentials were preserved."
        } catch {
            notice = "Settings could not be reset while another settings transaction was active."
        }
    }

    func eraseAllAppData() async {
        do {
            let retainedCredentialCopy = try await SettingsMaintenanceService.eraseAllAppData()
            notice = retainedCredentialCopy
                ? "Local app data was erased, but an inaccessible legacy Keychain copy may remain."
                : "All local app data was erased. Onboarding will restart."
        } catch {
            notice = error.localizedDescription
        }
    }

    func copyDiagnostics() {
        let enabledDestinationCount = [
            PreferencesDataModel.mixSpaceIntegration.value.isEnabled,
            PreferencesDataModel.slackIntegration.value.isEnabled,
            PreferencesDataModel.discordIntegration.value.isEnabled,
        ].filter { $0 }.count
        let lastError = PresenceDiagnosticsState.shared.lastError
        let snapshot = DiagnosticsSnapshot(
            applicationVersion: applicationVersion,
            buildNumber: buildNumber,
            credentialStorage: credentialStorageStatus,
            databaseStatus: "Ready",
            mediaProvider: CLIMediaInfoProvider.isMediaControlInstalled()
                ? "Enhanced helper available" : "Built-in provider",
            accessibilityGranted: ApplicationMonitor.shared.isAccessibilityEnabled(),
            sharingEnabled: PreferencesDataModel.reportingAllowed,
            enabledDestinationCount: enabledDestinationCount,
            syncHistoryCount: historyCount,
            iconCacheCount: iconCount,
            lastSafeErrorCode: lastError?.code,
            lastSafeErrorMessage: lastError?.message,
            lastSafeErrorDate: lastError?.occurredAt
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot),
            let value = String(data: data, encoding: .utf8)
        else {
            notice = "Diagnostics could not be encoded."
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        notice = "Sanitized diagnostics were copied."
    }

    private var credentialStorageStatus: String {
        if PreferencesDataModel.integrationCredentialStoreUnavailable {
            return "Recovery required"
        }
        if PreferencesDataModel.integrationCredentialRecoveryWarning != nil {
            return "Needs attention"
        }
        return CredentialStore.usesKeychainStorage ? "Keychain ready" : "Protected local journal"
    }
}
