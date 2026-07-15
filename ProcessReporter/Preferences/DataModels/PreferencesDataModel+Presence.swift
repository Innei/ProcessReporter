import Foundation
import RxCocoa
import RxSwift

extension PreferencesDataModel {
    @UserDefaultsRelay("shareWindowTitles", defaultValue: false)
    static var shareWindowTitles: BehaviorRelay<Bool>

    @UserDefaultsRelay("hasCompletedOnboarding", defaultValue: false)
    static var hasCompletedOnboarding: BehaviorRelay<Bool>

    @UserDefaultsRelay("presencePreferencesSchemaVersion", defaultValue: 0)
    static var presencePreferencesSchemaVersion: BehaviorRelay<Int>
}

@MainActor
enum PresencePreferencesMigrator {
    private static let currentVersion = 2

    static func migrateIfNeeded() async throws {
        var version = PreferencesDataModel.presencePreferencesSchemaVersion.value

        if version < 1 {
            try await migrateToVersion1()
            PreferencesDataModel.presencePreferencesSchemaVersion.accept(1)
            version = 1
        }

        if version < 2 {
            migrateToVersion2()
            PreferencesDataModel.presencePreferencesSchemaVersion.accept(2)
            version = 2
        }

        assert(version == currentVersion)
    }

    private static func migrateToVersion1() async throws {
        let defaults = UserDefaults.standard
        let legacyKeys = [
            "isEnabled",
            "sendInterval",
            "focusReport",
            "enabledTypes",
            "mixSpaceIntegration",
            "slackIntegration",
            "s3Integration",
            "discordIntegration",
            "filteredProcesses",
            "filteredMediaProcesses",
            "mappingList",
        ]
        let hasLegacyPreferences = legacyKeys.contains {
            defaults.object(forKey: $0) != nil
        }
        // A failed history read is not evidence of a fresh installation. Throw
        // without advancing the migration version so the next launch can retry.
        let hasLegacyHistory = try await DataStore.shared.reportCount() > 0
        let isExistingInstallation = hasLegacyPreferences || hasLegacyHistory

        // Existing releases always included the focused window title in process
        // reports. Preserve that behavior during upgrade; new installs remain
        // privacy-first with window titles disabled.
        PreferencesDataModel.shareWindowTitles.accept(isExistingInstallation)
        PreferencesDataModel.hasCompletedOnboarding.accept(isExistingInstallation)
    }

    private static func migrateToVersion2() {
        let configurationKey = "presencePrivacyConfiguration"
        if UserDefaults.standard.object(forKey: configurationKey) == nil {
            let defaults = PresencePrivacyDefaults(
                application: .share,
                windowTitle: PreferencesDataModel.shareWindowTitles.value ? .share : .hide,
                media: .share
            )
            PreferencesDataModel.presencePrivacyConfiguration.accept(
                PresencePrivacyConfiguration(defaults: defaults, rules: [])
            )
        }

        // The legacy filters remain the fail-closed compatibility projection.
        // Mapping data is deliberately left untouched.
        PresencePrivacyRulesRepository.reconcileLegacyFilters()
    }
}
