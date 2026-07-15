import Foundation

@MainActor
enum PresencePrivacyRulesRepository {
    static func effectiveConfiguration() -> PresencePrivacyConfiguration {
        var configuration = PreferencesDataModel.presencePrivacyConfiguration.value
        let hiddenApplications = Set(PreferencesDataModel.filteredProcesses.value)
        let hiddenMediaApplications = Set(PreferencesDataModel.filteredMediaProcesses.value)

        for applicationIdentifier in hiddenApplications.union(hiddenMediaApplications) {
            var rule = configuration.rule(for: applicationIdentifier)
                ?? .empty(applicationIdentifier: applicationIdentifier)
            if hiddenApplications.contains(applicationIdentifier) {
                rule.application = .hide
            }
            if hiddenMediaApplications.contains(applicationIdentifier) {
                rule.media = .hide
            }
            configuration.rules.removeAll { $0.applicationIdentifier == applicationIdentifier }
            configuration.rules.append(rule)
        }
        configuration.rules.sort { $0.applicationIdentifier < $1.applicationIdentifier }
        return configuration
    }

    static func effectiveRule(for applicationIdentifier: String) -> ApplicationPresenceRule {
        effectiveConfiguration().rule(for: applicationIdentifier)
            ?? .empty(applicationIdentifier: applicationIdentifier)
    }

    static func updateDefaults(_ defaults: PresencePrivacyDefaults) {
        var configuration = PreferencesDataModel.presencePrivacyConfiguration.value
        configuration.defaults = defaults
        PreferencesDataModel.presencePrivacyConfiguration.accept(configuration)
    }

    static func upsert(_ unnormalizedRule: ApplicationPresenceRule) {
        let rule = unnormalizedRule.normalized
        let applicationIdentifier = rule.applicationIdentifier

        var hiddenApplications = Set(PreferencesDataModel.filteredProcesses.value)
        var hiddenMediaApplications = Set(PreferencesDataModel.filteredMediaProcesses.value)

        // Add new Hide projections before publishing the richer rule so the
        // compatibility path cannot briefly expose a field.
        if rule.application == .hide {
            hiddenApplications.insert(applicationIdentifier)
            PreferencesDataModel.filteredProcesses.accept(hiddenApplications.sorted())
        }
        if rule.media == .hide {
            hiddenMediaApplications.insert(applicationIdentifier)
            PreferencesDataModel.filteredMediaProcesses.accept(hiddenMediaApplications.sorted())
        }

        var configuration = PreferencesDataModel.presencePrivacyConfiguration.value
        configuration.rules.removeAll { $0.applicationIdentifier == applicationIdentifier }
        if !rule.isEmpty {
            configuration.rules.append(rule)
            configuration.rules.sort { $0.applicationIdentifier < $1.applicationIdentifier }
        }
        PreferencesDataModel.presencePrivacyConfiguration.accept(configuration)

        // A user Save is the explicit authority to remove an earlier Hide.
        if rule.application != .hide {
            hiddenApplications.remove(applicationIdentifier)
            PreferencesDataModel.filteredProcesses.accept(hiddenApplications.sorted())
        }
        if rule.media != .hide {
            hiddenMediaApplications.remove(applicationIdentifier)
            PreferencesDataModel.filteredMediaProcesses.accept(hiddenMediaApplications.sorted())
        }
    }

    static func removeRule(for applicationIdentifier: String) {
        var configuration = PreferencesDataModel.presencePrivacyConfiguration.value
        configuration.rules.removeAll { $0.applicationIdentifier == applicationIdentifier }
        PreferencesDataModel.presencePrivacyConfiguration.accept(configuration)

        PreferencesDataModel.filteredProcesses.accept(
            PreferencesDataModel.filteredProcesses.value
                .filter { $0 != applicationIdentifier }
                .sorted()
        )
        PreferencesDataModel.filteredMediaProcesses.accept(
            PreferencesDataModel.filteredMediaProcesses.value
                .filter { $0 != applicationIdentifier }
                .sorted()
        )
    }

    static func reconcileLegacyFilters() {
        PreferencesDataModel.presencePrivacyConfiguration.accept(effectiveConfiguration())
    }

    static func legacyMappings(
        associatedWith applicationIdentifier: String
    ) -> [PreferencesDataModel.Mapping] {
        let displayName = AppUtility.shared.getAppInfo(for: applicationIdentifier).displayName
        return PreferencesDataModel.mappingList.value.getList().filter { mapping in
            switch mapping.type {
            case .processApplicationIdentifier, .mediaProcessApplicationIdentifier:
                return mapping.from == applicationIdentifier
            case .processName, .mediaProcessName:
                return mapping.from == displayName
            }
        }
    }
}

