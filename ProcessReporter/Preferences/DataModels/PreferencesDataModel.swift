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

	enum ImportResult {
		case success(integrationsRequiringReview: [String], ignoredFields: [String])
		case invalid
	}

    static func collectPreferences() -> [String: Any] {
        [
            "isEnabled": PreferencesDataModel.reportingAllowed,
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

	public static func importFromPlist(data: Data) async -> ImportResult {
		do {
			guard
				let dictionary = try PropertyListSerialization.propertyList(
					from: data, options: [], format: nil) as? [String: Any]
			else {
				return .invalid
			}

			let currentMixSpace = PreferencesDataModel.mixSpaceIntegration.value
			let currentSlack = PreferencesDataModel.slackIntegration.value
			let currentS3 = PreferencesDataModel.s3Integration.value
			var integrationsRequiringReview: [String] = []
			var ignoredFields: [String] = []
			var importedMixSpace: MixSpaceIntegration?
			var importedSlack: SlackIntegration?
			var importedS3: S3Integration?

			if let mixSpaceDict = dictionary["mixSpaceIntegration"] as? [String: Any] {
				var integration = MixSpaceIntegration.fromDictionary(mixSpaceDict)
				// Credentials are deliberately outside the plist contract. Ignore
				// secrets embedded by historical exports and retain the current value.
				integration.apiToken = currentMixSpace.apiToken
				if integration.isEnabled,
				   !currentMixSpace.apiToken.isEmpty,
				   integration.endpoint != currentMixSpace.endpoint
				{
					// Importing an arbitrary endpoint must not silently rebind a
					// credential already stored on this Mac. Preserve the credential,
					// but require the user to review and re-enable the integration.
					integration.isEnabled = false
					integrationsRequiringReview.append("Mix Space")
				}
				importedMixSpace = integration
			}

			if let slackDict = dictionary["slackIntegration"] as? [String: Any] {
				var integration = SlackIntegration.fromDictionary(slackDict)
				integration.apiToken = currentSlack.apiToken
				importedSlack = integration
			}

			if let s3Dict = dictionary["s3Integration"] as? [String: Any] {
				var integration = S3Integration.fromDictionary(s3Dict)
				integration.accessKey = currentS3.accessKey
				integration.secretKey = currentS3.secretKey
				let destinationChanged = [
					integration.bucket,
					integration.region,
					integration.endpoint,
					integration.path,
				] != [
					currentS3.bucket,
					currentS3.region,
					currentS3.endpoint,
					currentS3.path,
				]
				if integration.isEnabled,
				   (!currentS3.accessKey.isEmpty || !currentS3.secretKey.isEmpty),
				   destinationChanged
				{
					integration.isEnabled = false
					integrationsRequiringReview.append("S3")
				}
				importedS3 = integration
			}

			// Do not let the reporter observe a half-imported configuration. Pause it,
			// apply the complete payload, then restore the requested enabled state.
			let desiredIsEnabled = dictionary["isEnabled"] as? Bool
				?? PreferencesDataModel.isEnabled.value
			PreferencesDataModel.setReportingEnabled(false)
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
			if let enabledTypesValue = dictionary["enabledTypes"] {
				if let enabledTypesArray = enabledTypesValue as? [String] {
					let parsedTypes = enabledTypesArray.compactMap(Reporter.Types.fromStorable)
					if parsedTypes.count == enabledTypesArray.count {
						PreferencesDataModel.enabledTypes.accept(
							ReporterTypesSet(types: Set(parsedTypes))
						)
					} else {
						ignoredFields.append("Report Types")
					}
				} else {
					ignoredFields.append("Report Types")
				}
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

			if !PreferencesDataModel.setReportingEnabled(desiredIsEnabled), desiredIsEnabled {
				ignoredFields.append("Enabled state (credential store unavailable)")
			}

			return .success(
				integrationsRequiringReview: integrationsRequiringReview,
				ignoredFields: ignoredFields
			)
		} catch {
			return .invalid
		}
	}
}
