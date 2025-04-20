//
//  PreferencesDataModel.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/7.
//

import Foundation
import RxCocoa
import RxSwift

class PreferencesDataModel {
	public static let shared = PreferencesDataModel.self

	static func collectPreferences() -> [String: Any] {
		[
			"isEnabled": PreferencesDataModel.isEnabled.value,
			"focusReport": PreferencesDataModel.focusReport.value,
			"sendInterval": PreferencesDataModel.sendInterval.value.rawValue,
			"enabledTypes": PreferencesDataModel.enabledTypes.value.toStorable() ?? [
				Reporter.Types.media.rawValue, Reporter.Types.process.rawValue,
			],
			"mixSpaceIntegration": PreferencesDataModel.mixSpaceIntegration.value.toDictionary(),
			"slackIntegration": PreferencesDataModel.slackIntegration.value.toDictionary(),
			"s3Integration": PreferencesDataModel.s3Integration.value.toDictionary(),
			"ignoreNullArtist": PreferencesDataModel.ignoreNullArtist.value,
			"filteredProcesses": PreferencesDataModel.filteredProcesses.value,
			"filteredMediaProcesses": PreferencesDataModel.filteredMediaProcesses.value,

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

			if let isEnabled = dictionary["isEnabled"] as? Bool {
				PreferencesDataModel.isEnabled.accept(isEnabled)
			}
			if let focusReport = dictionary["focusReport"] as? Bool {
				PreferencesDataModel.focusReport.accept(focusReport)
			}
			if let sendIntervalRaw = dictionary["sendInterval"] as? Int,
			   let sendInterval = SendInterval(rawValue: sendIntervalRaw)
			{
				PreferencesDataModel.sendInterval.accept(sendInterval)
			}
			if let mixSpaceDict = dictionary["mixSpaceIntegration"] as? [String: Any] {
				PreferencesDataModel.mixSpaceIntegration.accept(
					MixSpaceIntegration.fromDictionary(mixSpaceDict))
			}
			if let slackDict = dictionary["slackIntegration"] as? [String: Any] {
				PreferencesDataModel.slackIntegration.accept(
					SlackIntegration.fromDictionary(slackDict))
			}
			if let s3Dict = dictionary["s3Integration"] as? [String: Any] {
				PreferencesDataModel.s3Integration.accept(
					S3Integration.fromDictionary(s3Dict))
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

			if let mapping = dictionary["mappingList"] as? [String: Any] {
				PreferencesDataModel.mappingList.accept(MappingList.fromDictionary(mapping))
			}

			return true
		} catch {
			return false
		}
	}
}
