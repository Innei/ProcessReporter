import Foundation

extension Notification.Name {
	static let settingsMaintenanceDidInvalidateDestinationDrafts = Notification.Name(
		"SettingsMaintenanceDidInvalidateDestinationDrafts"
	)
}

enum SettingsMaintenanceError: LocalizedError {
    case credentialRemovalFailed
	case localDataRemovalFailed

    var errorDescription: String? {
        switch self {
        case .credentialRemovalFailed:
			return "Runtime credentials and settings were cleared, but protected credential storage could not be fully erased. Sharing remains paused."
		case .localDataRemovalFailed:
			return "Runtime credentials and settings were cleared, but some local history or icon data could not be erased. Sharing remains paused."
        }
    }
}

@MainActor
enum SettingsMaintenanceService {
    static func resetSettings() async throws {
		try await SettingsMutationCoordinator.shared.performExclusive {
            resetPreferenceRelays(
                preserveCredentials: true,
                onboardingCompleted: true
            )
			publishDestinationDraftInvalidation()
        }
    }

    static func eraseAllAppData() async throws -> Bool {
		try await SettingsMutationCoordinator.shared.performExclusive {
            try await eraseAllAppDataTransaction()
        }
    }

    private static func eraseAllAppDataTransaction() async throws -> Bool {
        _ = PreferencesDataModel.setReportingEnabled(false)

        let mixSpace = PreferencesDataModel.mixSpaceIntegration.value
        let slack = PreferencesDataModel.slackIntegration.value
        let s3 = PreferencesDataModel.s3Integration.value

		// Clear live secrets before the first suspension. The captured values are
		// used only to remove their protected copies. A final reset below closes the
		// reentrancy window for legacy controls that do not use the coordinator.
		resetPreferenceRelays(
			preserveCredentials: false,
			onboardingCompleted: false
		)
		S3AssetHostingService.clearStoredUploadFingerprints()
		S3AssetHostingService.clearFailedUploads()
		defer {
			resetPreferenceRelays(
				preserveCredentials: false,
				onboardingCompleted: false
			)
			S3AssetHostingService.clearStoredUploadFingerprints()
			S3AssetHostingService.clearFailedUploads()
			// The final reset runs for success, credential failure, and database
			// failure. Invalidate every open editor before exclusive admission is
			// reopened so a pre-maintenance draft cannot restore erased settings.
			publishDestinationDraftInvalidation()
		}

        let credentialResult = await CredentialStore.apply(
            [
                .init(
                    account: IntegrationCredentialAccount.mixSpaceToken,
                    previousValue: mixSpace.apiToken,
                    newValue: ""
                ),
                .init(
                    account: IntegrationCredentialAccount.slackToken,
                    previousValue: slack.apiToken,
                    newValue: ""
                ),
                .init(
                    account: IntegrationCredentialAccount.s3AccessKey,
                    previousValue: s3.accessKey,
                    newValue: ""
                ),
                .init(
                    account: IntegrationCredentialAccount.s3SecretKey,
                    previousValue: s3.secretKey,
                    newValue: ""
                ),
            ],
            pendingPreferences: []
        )

		var localDataRemovalFailed = false
		do {
			try await DataStore.shared.deleteAllReports()
		} catch {
			localDataRemovalFailed = true
			NSLog("Could not erase Sync History: %@", error.localizedDescription)
		}
		do {
			try await DataStore.shared.deleteAllIcons()
		} catch {
			localDataRemovalFailed = true
			NSLog("Could not erase the icon cache: %@", error.localizedDescription)
		}

		guard credentialResult.succeeded else {
			throw SettingsMaintenanceError.credentialRemovalFailed
		}
		guard !localDataRemovalFailed else {
			throw SettingsMaintenanceError.localDataRemovalFailed
		}
        return credentialResult.retainedClearedKeychainValue
    }

	private static func publishDestinationDraftInvalidation() {
		NotificationCenter.default.post(
			name: .settingsMaintenanceDidInvalidateDestinationDrafts,
			object: nil
		)
	}

    private static func resetPreferenceRelays(
        preserveCredentials: Bool,
        onboardingCompleted: Bool
    ) {
        let currentMixSpace = PreferencesDataModel.mixSpaceIntegration.value
        let currentSlack = PreferencesDataModel.slackIntegration.value
        let currentS3 = PreferencesDataModel.s3Integration.value

        _ = PreferencesDataModel.setReportingEnabled(false)
        PreferencesDataModel.sendInterval.accept(.tenSeconds)
        PreferencesDataModel.focusReport.accept(true)
        PreferencesDataModel.enabledTypes.accept(
            ReporterTypesSet(types: [.media, .process])
        )
        PreferencesDataModel.ignoreNullArtist.accept(true)
        PreferencesDataModel.shareWindowTitles.accept(false)
        PreferencesDataModel.filteredProcesses.accept([])
        PreferencesDataModel.filteredMediaProcesses.accept([])
        PreferencesDataModel.presencePrivacyConfiguration.accept(.newInstallation)
        PreferencesDataModel.mappingList.accept(
            PreferencesDataModel.MappingList(mappings: [])
        )
        PreferencesDataModel.hasShownMediaControlInstallPrompt.accept(false)

        var mixSpace = MixSpaceIntegration()
        var slack = SlackIntegration()
        var s3 = S3Integration()
        if preserveCredentials {
            mixSpace.apiToken = currentMixSpace.apiToken
            slack.apiToken = currentSlack.apiToken
            s3.accessKey = currentS3.accessKey
            s3.secretKey = currentS3.secretKey
        }
        PreferencesDataModel.mixSpaceIntegration.accept(mixSpace)
        PreferencesDataModel.slackIntegration.accept(slack)
        PreferencesDataModel.s3Integration.accept(s3)
        PreferencesDataModel.discordIntegration.accept(DiscordIntegration())

        PreferencesDataModel.hasCompletedOnboarding.accept(onboardingCompleted)
        PreferencesDataModel.presencePreferencesSchemaVersion.accept(2)
    }
}
