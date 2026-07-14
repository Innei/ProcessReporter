//
//  PreferencesDataModel.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/7.
//

import Foundation
import RxCocoa
import RxSwift

@MainActor
final class PreferencesDataModel {
	public static let shared = PreferencesDataModel.self

    static func collectPreferences() -> [String: Any] {
        [
            "isEnabled": PreferencesDataModel.isEnabled.value,
            "focusReport": PreferencesDataModel.focusReport.value,
            "sendInterval": PreferencesDataModel.sendInterval.value.rawValue,
            "enabledTypes": PreferencesDataModel.enabledTypes.value.toStorable() ?? [
                Reporter.Types.media.rawValue, Reporter.Types.process.rawValue,
            ],
            "mixSpaceIntegration": PreferencesDataModel.mixSpaceIntegration.value.exportDictionary(),
            "slackIntegration": PreferencesDataModel.slackIntegration.value.exportDictionary(),
            "s3Integration": PreferencesDataModel.s3Integration.value.exportDictionary(),
            "discordIntegration": PreferencesDataModel.discordIntegration.value.toDictionary(),
            "ignoreNullArtist": PreferencesDataModel.ignoreNullArtist.value,
            "filteredProcesses": PreferencesDataModel.filteredProcesses.value,
            "filteredMediaProcesses": PreferencesDataModel.filteredMediaProcesses.value,
            "hasShownMediaControlInstallPrompt": PreferencesDataModel.hasShownMediaControlInstallPrompt.value,

            "mappingList": PreferencesDataModel.mappingList.value.toDictionary(),
        ]
    }

	public static func exportToPlist() -> Data? {
		let dictionary = collectPreferences()

		return try? PropertyListSerialization.data(
			fromPropertyList: dictionary,
			format: .xml,
			options: 0)
	}

	public static func importFromPlist(data: Data) -> Bool {
		do {
			guard
				let dictionary = try PropertyListSerialization.propertyList(
					from: data, options: [], format: nil) as? [String: Any]
			else {
				return false
			}

			let currentMixSpace = PreferencesDataModel.mixSpaceIntegration.value
			let currentSlack = PreferencesDataModel.slackIntegration.value
			let currentS3 = PreferencesDataModel.s3Integration.value
			var importedMixSpace: MixSpaceIntegration?
			var importedSlack: SlackIntegration?
			var importedS3: S3Integration?
			var credentialChanges: [CredentialStore.Change] = []

			if let mixSpaceDict = dictionary["mixSpaceIntegration"] as? [String: Any] {
				var integration = MixSpaceIntegration.fromDictionary(mixSpaceDict)
				if (mixSpaceDict["apiToken"] as? String)?.isEmpty != false {
					integration.apiToken = currentMixSpace.apiToken
				}
				credentialChanges.append(.init(
					account: IntegrationCredentialAccount.mixSpaceToken,
					previousValue: currentMixSpace.apiToken,
					newValue: integration.apiToken
				))
				importedMixSpace = integration
			}

			if let slackDict = dictionary["slackIntegration"] as? [String: Any] {
				var integration = SlackIntegration.fromDictionary(slackDict)
				if (slackDict["apiToken"] as? String)?.isEmpty != false {
					integration.apiToken = currentSlack.apiToken
				}
				credentialChanges.append(.init(
					account: IntegrationCredentialAccount.slackToken,
					previousValue: currentSlack.apiToken,
					newValue: integration.apiToken
				))
				importedSlack = integration
			}

			if let s3Dict = dictionary["s3Integration"] as? [String: Any] {
				var integration = S3Integration.fromDictionary(s3Dict)
				if (s3Dict["accessKey"] as? String)?.isEmpty != false {
					integration.accessKey = currentS3.accessKey
				}
				if (s3Dict["secretKey"] as? String)?.isEmpty != false {
					integration.secretKey = currentS3.secretKey
				}
				credentialChanges.append(contentsOf: [
					.init(
						account: IntegrationCredentialAccount.s3AccessKey,
						previousValue: currentS3.accessKey,
						newValue: integration.accessKey
					),
					.init(
						account: IntegrationCredentialAccount.s3SecretKey,
						previousValue: currentS3.secretKey,
						newValue: integration.secretKey
					),
				])
				importedS3 = integration
			}

			// A legacy backup may contain credentials. Commit all of those Keychain
			// changes as one rollback-capable group before exposing any imported
			// preference to the running reporter.
			guard CredentialStore.apply(credentialChanges) else { return false }

			// Do not let the reporter observe a half-imported configuration. Pause it,
			// apply the complete payload, then restore the requested enabled state.
			let desiredIsEnabled = dictionary["isEnabled"] as? Bool
				?? PreferencesDataModel.isEnabled.value
			PreferencesDataModel.isEnabled.accept(false)
			if let focusReport = dictionary["focusReport"] as? Bool {
				PreferencesDataModel.focusReport.accept(focusReport)
			}
			if let sendIntervalRaw = dictionary["sendInterval"] as? Int,
			   let sendInterval = SendInterval(rawValue: sendIntervalRaw)
			{
				PreferencesDataModel.sendInterval.accept(sendInterval)
			}
			if let importedMixSpace {
				PreferencesDataModel.mixSpaceIntegration.accept(importedMixSpace)
			}
			if let importedSlack {
				PreferencesDataModel.slackIntegration.accept(importedSlack)
			}
			if let importedS3 {
				PreferencesDataModel.s3Integration.accept(importedS3)
            }
            if let discordDict = dictionary["discordIntegration"] as? [String: Any] {
                PreferencesDataModel.discordIntegration.accept(
                    DiscordIntegration.fromDictionary(discordDict))
            }
            if let enabledTypesArray = dictionary["enabledTypes"] as? [String] {
                let enabledTypesSet = ReporterTypesSet(
                    types: Set(enabledTypesArray.compactMap(Reporter.Types.fromStorable))
                )
                PreferencesDataModel.enabledTypes.accept(enabledTypesSet)
			}
			if let ignoreNullArtist = dictionary["ignoreNullArtist"] as? Bool {
				PreferencesDataModel.ignoreNullArtist.accept(ignoreNullArtist)
			}
			if let filteredProcesses = dictionary["filteredProcesses"] as? [String] {
				PreferencesDataModel.filteredProcesses.accept(filteredProcesses)
			}
			if let filteredMediaProcesses = dictionary["filteredMediaProcesses"] as? [String] {
				PreferencesDataModel.filteredMediaProcesses.accept(filteredMediaProcesses)
			}
			if let hasShownMediaControlInstallPrompt = dictionary["hasShownMediaControlInstallPrompt"] as? Bool {
				PreferencesDataModel.hasShownMediaControlInstallPrompt.accept(hasShownMediaControlInstallPrompt)
			}

			// Mapping lists are exported as an array of dictionaries. Ignore malformed
			// mapping entries while still importing the other valid preferences.
			if let mapping = dictionary["mappingList"] as? [[String: Any]] {
				PreferencesDataModel.mappingList.accept(MappingList.fromDictionary(mapping))
			}

			PreferencesDataModel.isEnabled.accept(desiredIsEnabled)

			return true
		} catch {
			return false
		}
	}
}
