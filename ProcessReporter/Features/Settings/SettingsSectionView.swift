import SwiftUI

struct SettingsSectionView: View {
    let section: SettingsSection
    @ObservedObject var store: SettingsStore

    var body: some View {
        Group {
            switch section {
            case .general:
                GeneralSettingsView(store: store)
            case .destinations:
                DestinationsSettingsView(store: store)
            case .privacyRules:
                PrivacyRulesView(
                    settingsStore: store,
                    targetApplicationIdentifier: store.privacyTargetApplicationIdentifier,
                    targetRequestID: store.privacyTargetRequestID
                )
            case .syncHistory:
                SyncHistoryView()
            case .advanced:
                AdvancedSettingsView(store: store)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
