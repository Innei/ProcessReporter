import Foundation

extension PreferencesDataModel {
    struct ImportPlan {
        let credentialIntegrationNames: [String]

        fileprivate let mixSpaceIntegration: MixSpaceIntegration?
        fileprivate let mixSpaceToken: String?
        fileprivate let slackIntegration: SlackIntegration?
        fileprivate let slackToken: String?
        fileprivate let s3Integration: S3Integration?
        fileprivate let s3AccessKey: String?
        fileprivate let s3SecretKey: String?
        fileprivate let discordIntegration: DiscordIntegration?
        fileprivate let filteredProcesses: [String]
        fileprivate let filteredMediaProcesses: [String]
        fileprivate let privacyConfiguration: PresencePrivacyConfiguration
        fileprivate let shareWindowTitles: Bool
        fileprivate let desiredIsEnabled: Bool
        fileprivate let focusReport: Bool?
        fileprivate let sendInterval: SendInterval?
        fileprivate let enabledTypes: ReporterTypesSet?
        fileprivate let ignoreNullArtist: Bool?
        fileprivate let mediaPromptState: Bool?
        fileprivate let mappingList: MappingList?
        fileprivate let ignoredFields: [String]
    }

    /// Fully validates and stages an import without changing preferences or
    /// protected credentials. The caller may safely present the credential
    /// decision only after this method returns a plan.
    static func prepareImport(data: Data) -> ImportPlan? {
        do {
            guard
                let dictionary = try PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                ) as? [String: Any]
            else {
                return nil
            }

            var importedMixSpace: MixSpaceIntegration?
            var importedMixSpaceToken: String?
            if let rawMixSpace = dictionary["mixSpaceIntegration"] {
                guard let mixSpaceDictionary = rawMixSpace as? [String: Any],
                      let integration = MixSpaceIntegration.validatedImportDictionary(
                        mixSpaceDictionary
                      )
                else { return nil }
                importedMixSpace = integration
                importedMixSpaceToken = mixSpaceDictionary["apiToken"] as? String
            }

            var importedSlack: SlackIntegration?
            var importedSlackToken: String?
            if let rawSlack = dictionary["slackIntegration"] {
                guard let slackDictionary = rawSlack as? [String: Any],
                      let integration = SlackIntegration.validatedImportDictionary(
                        slackDictionary
                      )
                else { return nil }
                importedSlack = integration
                importedSlackToken = slackDictionary["apiToken"] as? String
            }

            var importedS3: S3Integration?
            var importedS3AccessKey: String?
            var importedS3SecretKey: String?
            if let rawS3 = dictionary["s3Integration"] {
                guard let s3Dictionary = rawS3 as? [String: Any],
                      let integration = S3Integration.validatedImportDictionary(s3Dictionary)
                else { return nil }

                let hasAccessKey = s3Dictionary["accessKey"] != nil
                let hasSecretKey = s3Dictionary["secretKey"] != nil
                // S3 credentials form one authority. A partial credential pair
                // must never be combined with the other half already on this Mac.
                guard hasAccessKey == hasSecretKey else { return nil }

                importedS3 = integration
                importedS3AccessKey = s3Dictionary["accessKey"] as? String
                importedS3SecretKey = s3Dictionary["secretKey"] as? String
                guard importedS3AccessKey.hasCredentialContent
                    == importedS3SecretKey.hasCredentialContent
                else { return nil }
            }

            var importedDiscord: DiscordIntegration?
            if let rawDiscord = dictionary["discordIntegration"] {
                guard let discordDictionary = rawDiscord as? [String: Any],
                      let integration = DiscordIntegration.validatedImportDictionary(
                        discordDictionary
                      )
                else { return nil }
                importedDiscord = integration
            }

            let importedFilteredProcesses: [String]
            if let rawFilteredProcesses = dictionary["filteredProcesses"] {
                guard let values = rawFilteredProcesses as? [String] else { return nil }
                importedFilteredProcesses = Array(Set(values)).sorted()
            } else {
                importedFilteredProcesses = []
            }

            let importedFilteredMediaProcesses: [String]
            if let rawFilteredMediaProcesses = dictionary["filteredMediaProcesses"] {
                guard let values = rawFilteredMediaProcesses as? [String] else { return nil }
                importedFilteredMediaProcesses = Array(Set(values)).sorted()
            } else {
                importedFilteredMediaProcesses = []
            }

            let importedPrivacyConfiguration: PresencePrivacyConfiguration
            let importedShareWindowTitles: Bool
            if let rawPrivacyConfiguration = dictionary["presencePrivacyConfiguration"] {
                guard var configuration = PresencePrivacyConfiguration.fromStorable(
                    rawPrivacyConfiguration
                ), configuration.isValidImportSnapshot
                else { return nil }
                configuration.rules = configuration.rules
                    .map(\.normalized)
                    .sorted { $0.applicationIdentifier < $1.applicationIdentifier }
                importedPrivacyConfiguration = configuration

                if let rawShareWindowTitles = dictionary["shareWindowTitles"] {
                    guard let shareWindowTitles = rawShareWindowTitles as? Bool else {
                        return nil
                    }
                    importedShareWindowTitles = shareWindowTitles
                } else {
                    importedShareWindowTitles = configuration.defaults.windowTitle.isShared
                }
            } else {
                if let rawShareWindowTitles = dictionary["shareWindowTitles"] {
                    guard let shareWindowTitles = rawShareWindowTitles as? Bool else {
                        return nil
                    }
                    importedShareWindowTitles = shareWindowTitles
                } else {
                    // Releases predating the privacy model always shared window titles.
                    importedShareWindowTitles = true
                }
                importedPrivacyConfiguration = PresencePrivacyConfiguration(
                    defaults: PresencePrivacyDefaults(
                        application: .share,
                        windowTitle: importedShareWindowTitles ? .share : .hide,
                        media: .share
                    ),
                    rules: []
                )
            }

            var ignoredFields: [String] = []

            let desiredIsEnabled: Bool
            if let rawIsEnabled = dictionary["isEnabled"] {
                if let isEnabled = rawIsEnabled as? Bool {
                    desiredIsEnabled = isEnabled
                } else {
                    desiredIsEnabled = PreferencesDataModel.isEnabled.value
                    ignoredFields.append("Enabled state")
                }
            } else {
                desiredIsEnabled = PreferencesDataModel.isEnabled.value
            }

            let importedFocusReport: Bool?
            if let rawFocusReport = dictionary["focusReport"] {
                importedFocusReport = rawFocusReport as? Bool
                if importedFocusReport == nil { ignoredFields.append("Focus reporting") }
            } else {
                importedFocusReport = nil
            }

            let importedSendInterval: SendInterval?
            if let rawSendInterval = dictionary["sendInterval"] {
                if let sendIntervalRaw = rawSendInterval as? Int,
                   let sendInterval = SendInterval(rawValue: sendIntervalRaw)
                {
                    importedSendInterval = sendInterval
                } else {
                    importedSendInterval = nil
                    ignoredFields.append("Delivery interval")
                }
            } else {
                importedSendInterval = nil
            }

            let importedEnabledTypes: ReporterTypesSet?
            if let enabledTypesValue = dictionary["enabledTypes"] {
                if let enabledTypesArray = enabledTypesValue as? [String] {
                    let parsedTypes = enabledTypesArray.compactMap(Reporter.Types.fromStorable)
                    if parsedTypes.count == enabledTypesArray.count {
                        importedEnabledTypes = ReporterTypesSet(types: Set(parsedTypes))
                    } else {
                        importedEnabledTypes = nil
                        ignoredFields.append("Report Types")
                    }
                } else {
                    importedEnabledTypes = nil
                    ignoredFields.append("Report Types")
                }
            } else {
                importedEnabledTypes = nil
            }

            let importedIgnoreNullArtist: Bool?
            if let rawIgnoreNullArtist = dictionary["ignoreNullArtist"] {
                importedIgnoreNullArtist = rawIgnoreNullArtist as? Bool
                if importedIgnoreNullArtist == nil {
                    ignoredFields.append("Incomplete media handling")
                }
            } else {
                importedIgnoreNullArtist = nil
            }

            let importedMediaPromptState: Bool?
            if let rawMediaPromptState = dictionary["hasShownMediaControlInstallPrompt"] {
                importedMediaPromptState = rawMediaPromptState as? Bool
                if importedMediaPromptState == nil {
                    ignoredFields.append("Media helper prompt state")
                }
            } else {
                importedMediaPromptState = nil
            }

            let importedMappingList: MappingList?
            if let rawMappingList = dictionary["mappingList"] {
                if let mappingDictionaries = rawMappingList as? [[String: Any]] {
                    let mappingList = MappingList.fromDictionary(mappingDictionaries)
                    importedMappingList = mappingList
                    if mappingList.getList().count != mappingDictionaries.count {
                        ignoredFields.append("Malformed mappings")
                    }
                } else {
                    importedMappingList = nil
                    ignoredFields.append("Mappings")
                }
            } else {
                importedMappingList = nil
            }

            var credentialIntegrationNames: [String] = []
            if importedMixSpaceToken.hasCredentialContent {
                credentialIntegrationNames.append("MixSpace")
            }
            if importedSlackToken.hasCredentialContent {
                credentialIntegrationNames.append("Slack")
            }
            if importedS3AccessKey.hasCredentialContent
                || importedS3SecretKey.hasCredentialContent
            {
                credentialIntegrationNames.append("S3")
            }

            return ImportPlan(
                credentialIntegrationNames: credentialIntegrationNames,
                mixSpaceIntegration: importedMixSpace,
                mixSpaceToken: importedMixSpaceToken,
                slackIntegration: importedSlack,
                slackToken: importedSlackToken,
                s3Integration: importedS3,
                s3AccessKey: importedS3AccessKey,
                s3SecretKey: importedS3SecretKey,
                discordIntegration: importedDiscord,
                filteredProcesses: importedFilteredProcesses,
                filteredMediaProcesses: importedFilteredMediaProcesses,
                privacyConfiguration: importedPrivacyConfiguration,
                shareWindowTitles: importedShareWindowTitles,
                desiredIsEnabled: desiredIsEnabled,
                focusReport: importedFocusReport,
                sendInterval: importedSendInterval,
                enabledTypes: importedEnabledTypes,
                ignoreNullArtist: importedIgnoreNullArtist,
                mediaPromptState: importedMediaPromptState,
                mappingList: importedMappingList,
                ignoredFields: ignoredFields
            )
        } catch {
            return nil
        }
    }

    static func importFromPlist(
        data: Data,
        credentialPolicy: ImportCredentialPolicy
    ) async -> ImportResult {
        guard let plan = prepareImport(data: data) else { return .invalid }
        return await importFromPlist(plan: plan, credentialPolicy: credentialPolicy)
    }

    static func importFromPlist(
        plan: ImportPlan,
        credentialPolicy: ImportCredentialPolicy
    ) async -> ImportResult {
        let currentMixSpace = PreferencesDataModel.mixSpaceIntegration.value
        let currentSlack = PreferencesDataModel.slackIntegration.value
        let currentS3 = PreferencesDataModel.s3Integration.value

        let restoreBackupCredentials: Bool
        switch credentialPolicy {
        case .preserveCurrent:
            restoreBackupCredentials = false
        case .restoreFromBackup:
            restoreBackupCredentials = true
        }

        var integrationsRequiringReview: [String] = []
        var restoredCredentialIntegrations: [String] = []
        var excludedCredentialIntegrations = restoreBackupCredentials
            ? [] : plan.credentialIntegrationNames

        func markForReview(_ name: String) {
            if !integrationsRequiringReview.contains(name) {
                integrationsRequiringReview.append(name)
            }
        }

        var importedMixSpace = plan.mixSpaceIntegration
        let didRestoreMixSpace: Bool
        if var integration = importedMixSpace {
            if restoreBackupCredentials,
               let importedToken = plan.mixSpaceToken,
               importedToken.hasCredentialContent
            {
                integration.apiToken = importedToken
                didRestoreMixSpace = true
                restoredCredentialIntegrations.append("MixSpace")
            } else {
                integration.apiToken = currentMixSpace.apiToken
                didRestoreMixSpace = false
            }

            let reusedCredentialForDifferentAuthority = !didRestoreMixSpace
                && integration.endpoint != currentMixSpace.endpoint
                && currentMixSpace.apiToken.hasCredentialContent
            if integration.isEnabled,
               (!integration.isValidPresenceDestination
                || reusedCredentialForDifferentAuthority)
            {
                integration.isEnabled = false
                markForReview("MixSpace")
            }
            importedMixSpace = integration
        } else {
            didRestoreMixSpace = false
        }

        var importedSlack = plan.slackIntegration
        let didRestoreSlack: Bool
        if var integration = importedSlack {
            if restoreBackupCredentials,
               let importedToken = plan.slackToken,
               importedToken.hasCredentialContent
            {
                integration.apiToken = importedToken
                didRestoreSlack = true
                restoredCredentialIntegrations.append("Slack")
            } else {
                integration.apiToken = currentSlack.apiToken
                didRestoreSlack = false
            }

            if integration.isEnabled, !integration.isValidPresenceDestination {
                integration.isEnabled = false
                markForReview("Slack")
            }
            importedSlack = integration
        } else {
            didRestoreSlack = false
        }

        var importedS3 = plan.s3Integration
        let didRestoreS3: Bool
        if var integration = importedS3 {
            if restoreBackupCredentials,
               let importedAccessKey = plan.s3AccessKey,
               let importedSecretKey = plan.s3SecretKey,
               importedAccessKey.hasCredentialContent,
               importedSecretKey.hasCredentialContent
            {
                integration.accessKey = importedAccessKey
                integration.secretKey = importedSecretKey
                didRestoreS3 = true
                restoredCredentialIntegrations.append("S3")
            } else {
                integration.accessKey = currentS3.accessKey
                integration.secretKey = currentS3.secretKey
                didRestoreS3 = false
                if restoreBackupCredentials,
                   plan.credentialIntegrationNames.contains("S3")
                {
                    excludedCredentialIntegrations.append("S3")
                }
            }

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
            let reusedCredentialForDifferentAuthority = !didRestoreS3
                && destinationChanged
                && (currentS3.accessKey.hasCredentialContent
                    || currentS3.secretKey.hasCredentialContent)
            if integration.isEnabled,
               (!integration.isValidAssetHostingConfiguration
                || reusedCredentialForDifferentAuthority)
            {
                integration.isEnabled = false
                markForReview("S3")
            }
            importedS3 = integration
        } else {
            didRestoreS3 = false
        }

        var credentialChanges: [CredentialStore.Change] = []
        var pendingPreferences: [CredentialStore.PendingPreference] = []

        if didRestoreMixSpace, let importedMixSpace {
            credentialChanges.append(
                .init(
                    account: IntegrationCredentialAccount.mixSpaceToken,
                    previousValue: currentMixSpace.apiToken,
                    newValue: importedMixSpace.apiToken
                )
            )
            guard let storedValue = importedMixSpace.toStorable() as? String else {
                return .credentialStorageFailed
            }
            pendingPreferences.append(
                .init(key: "mixSpaceIntegration", value: storedValue)
            )
        }

        if didRestoreSlack, let importedSlack {
            credentialChanges.append(
                .init(
                    account: IntegrationCredentialAccount.slackToken,
                    previousValue: currentSlack.apiToken,
                    newValue: importedSlack.apiToken
                )
            )
            guard let storedValue = importedSlack.toStorable() as? String else {
                return .credentialStorageFailed
            }
            pendingPreferences.append(.init(key: "slackIntegration", value: storedValue))
        }

        if didRestoreS3, let importedS3 {
            credentialChanges.append(contentsOf: [
                .init(
                    account: IntegrationCredentialAccount.s3AccessKey,
                    previousValue: currentS3.accessKey,
                    newValue: importedS3.accessKey
                ),
                .init(
                    account: IntegrationCredentialAccount.s3SecretKey,
                    previousValue: currentS3.secretKey,
                    newValue: importedS3.secretKey
                ),
            ])
            guard let storedValue = importedS3.toStorable() as? String else {
                return .credentialStorageFailed
            }
            pendingPreferences.append(.init(key: "s3Integration", value: storedValue))
        }

        if !credentialChanges.isEmpty {
            let credentialResult = await CredentialStore.apply(
                credentialChanges,
                pendingPreferences: pendingPreferences
            )
            guard credentialResult.succeeded else { return .credentialStorageFailed }
        }

        // Publish only after every supplied value has been validated and the
        // credential transaction is durable. Reporter subscriptions therefore
        // never observe imported metadata paired with an old credential.
        PreferencesDataModel.setReportingEnabled(false)
        if let focusReport = plan.focusReport {
            PreferencesDataModel.focusReport.accept(focusReport)
        }
        if let sendInterval = plan.sendInterval {
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
        if let importedDiscord = plan.discordIntegration {
            PreferencesDataModel.discordIntegration.accept(importedDiscord)
        }
        if let enabledTypes = plan.enabledTypes {
            PreferencesDataModel.enabledTypes.accept(enabledTypes)
        }
        PreferencesDataModel.shareWindowTitles.accept(plan.shareWindowTitles)
        if let ignoreNullArtist = plan.ignoreNullArtist {
            PreferencesDataModel.ignoreNullArtist.accept(ignoreNullArtist)
        }
        PreferencesDataModel.filteredProcesses.accept(plan.filteredProcesses)
        PreferencesDataModel.filteredMediaProcesses.accept(plan.filteredMediaProcesses)
        PreferencesDataModel.presencePrivacyConfiguration.accept(plan.privacyConfiguration)
        if let hasShownMediaControlInstallPrompt = plan.mediaPromptState {
            PreferencesDataModel.hasShownMediaControlInstallPrompt.accept(
                hasShownMediaControlInstallPrompt
            )
        }
        if let mappingList = plan.mappingList {
            PreferencesDataModel.mappingList.accept(mappingList)
        }

        PresencePrivacyRulesRepository.reconcileLegacyFilters()

        var ignoredFields = plan.ignoredFields
        if !PreferencesDataModel.setReportingEnabled(plan.desiredIsEnabled),
           plan.desiredIsEnabled
        {
            ignoredFields.append(
                "Enabled state (no available destination or credential store unavailable)"
            )
        }

        return .success(
            integrationsRequiringReview: integrationsRequiringReview,
            ignoredFields: ignoredFields,
            restoredCredentialIntegrations: restoredCredentialIntegrations,
            excludedCredentialIntegrations: excludedCredentialIntegrations
        )
    }
}

private extension Optional where Wrapped == String {
    var hasCredentialContent: Bool {
        self?.hasCredentialContent == true
    }
}

private extension String {
    var hasCredentialContent: Bool {
        !trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private extension PresencePrivacyConfiguration {
    var isValidImportSnapshot: Bool {
        let identifiers = rules.map {
            $0.applicationIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return identifiers.allSatisfy { !$0.isEmpty }
            && Set(identifiers).count == identifiers.count
    }
}
