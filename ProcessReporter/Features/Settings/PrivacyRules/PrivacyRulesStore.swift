import AppKit
import Foundation
import RxSwift

struct ApplicationRuleRowModel: Identifiable {
    let id: String
    let displayName: String
    let icon: NSImage
    let rule: ApplicationPresenceRule
    let hasLegacyMapping: Bool

    var summary: String {
        var parts: [String] = []
        if rule.application == .hide { parts.append("Application hidden") }
        if rule.application == .share { parts.append("Application shared") }
        if rule.windowTitle == .hide { parts.append("Window hidden") }
        if rule.windowTitle == .share { parts.append("Window shared") }
        if rule.media == .hide { parts.append("Media hidden") }
        if rule.media == .share { parts.append("Media shared") }
        if let alias = rule.normalized.displayAlias { parts.append("Alias: \(alias)") }
        if hasLegacyMapping { parts.append("Legacy Mapping Applied") }
        return parts.isEmpty ? "Uses global defaults" : parts.joined(separator: " · ")
    }
}

@MainActor
final class PrivacyRulesStore: ObservableObject {
    @Published private(set) var defaults: PresencePrivacyDefaults
    @Published private(set) var rows: [ApplicationRuleRowModel] = []
    @Published var searchText = ""
    @Published var editingRule: ApplicationPresenceRule?
    @Published var pendingRemoval: ApplicationRuleRowModel?

    private let disposeBag = DisposeBag()

    init() {
        defaults = PreferencesDataModel.presencePrivacyConfiguration.value.defaults
        bindPreferences()
        refresh()
    }

    var filteredRows: [ApplicationRuleRowModel] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return rows }
        return rows.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
                || $0.summary.localizedCaseInsensitiveContains(query)
        }
    }

    func updateDefault(
        _ keyPath: WritableKeyPath<PresencePrivacyDefaults, PresencePrivacyDefault>,
        to value: PresencePrivacyDefault
    ) {
        var updated = defaults
        updated[keyPath: keyPath] = value
        PresencePrivacyRulesRepository.updateDefaults(updated)
    }

    func beginEditing(applicationIdentifier: String) {
        editingRule = PresencePrivacyRulesRepository.effectiveRule(
            for: applicationIdentifier
        )
    }

    func save(_ rule: ApplicationPresenceRule) {
        PresencePrivacyRulesRepository.upsert(rule)
        editingRule = nil
    }

    func requestRemoval(_ row: ApplicationRuleRowModel) {
        pendingRemoval = row
    }

    func confirmRemoval() {
        guard let pendingRemoval else { return }
        PresencePrivacyRulesRepository.removeRule(for: pendingRemoval.id)
        self.pendingRemoval = nil
    }

    private func bindPreferences() {
        Observable.combineLatest(
            PreferencesDataModel.presencePrivacyConfiguration,
            PreferencesDataModel.filteredProcesses,
            PreferencesDataModel.filteredMediaProcesses,
            PreferencesDataModel.mappingList
        )
        .observe(on: MainScheduler.instance)
        .subscribe(onNext: { [weak self] _, _, _, _ in
            self?.refresh()
        })
        .disposed(by: disposeBag)
    }

    private func refresh() {
        let configuration = PresencePrivacyRulesRepository.effectiveConfiguration()
        defaults = configuration.defaults
        rows = configuration.rules.map { rule in
            let appInfo = AppUtility.shared.getAppInfo(for: rule.applicationIdentifier)
            return ApplicationRuleRowModel(
                id: rule.applicationIdentifier,
                displayName: appInfo.displayName,
                icon: appInfo.icon,
                rule: rule,
                hasLegacyMapping: !PresencePrivacyRulesRepository.legacyMappings(
                    associatedWith: rule.applicationIdentifier
                ).isEmpty
            )
        }
        .sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }
}

