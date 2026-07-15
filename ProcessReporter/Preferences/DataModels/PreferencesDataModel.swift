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

    enum ImportCredentialPolicy {
        /// Retains credentials already protected on this Mac. A retained
        /// credential is never rebound to a different imported authority.
        case preserveCurrent
        /// Restores non-empty credentials embedded by a historical plaintext
        /// export and immediately copies them into protected local storage.
        case restoreFromBackup
    }

    enum ImportResult {
        case success(
            integrationsRequiringReview: [String],
            ignoredFields: [String],
            restoredCredentialIntegrations: [String],
            excludedCredentialIntegrations: [String]
        )
        case credentialStorageFailed
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
            "shareWindowTitles": PreferencesDataModel.shareWindowTitles.value,
            "mixSpaceIntegration": PreferencesDataModel.mixSpaceIntegration.value.exportDictionary(),
            "slackIntegration": PreferencesDataModel.slackIntegration.value.exportDictionary(),
            "s3Integration": PreferencesDataModel.s3Integration.value.exportDictionary(),
            "discordIntegration": PreferencesDataModel.discordIntegration.value.toDictionary(),
            "ignoreNullArtist": PreferencesDataModel.ignoreNullArtist.value,
            "filteredProcesses": PreferencesDataModel.filteredProcesses.value,
            "filteredMediaProcesses": PreferencesDataModel.filteredMediaProcesses.value,
            "presencePrivacyConfiguration":
                PreferencesDataModel.presencePrivacyConfiguration.value.toStorable() ?? "",
            "hasShownMediaControlInstallPrompt":
                PreferencesDataModel.hasShownMediaControlInstallPrompt.value,
            "mappingList": PreferencesDataModel.mappingList.value.toDictionary(),
        ]
    }

    public static func exportToPlist() -> Data? {
        let dictionary = collectPreferences()

        return try? PropertyListSerialization.data(
            fromPropertyList: dictionary,
            format: .xml,
            options: 0
        )
    }
}
