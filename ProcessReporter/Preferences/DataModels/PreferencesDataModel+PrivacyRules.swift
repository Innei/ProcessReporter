import RxCocoa
import RxSwift

extension PreferencesDataModel {
    @UserDefaultsRelay(
        "presencePrivacyConfiguration",
        defaultValue: PresencePrivacyConfiguration.newInstallation
    )
    static var presencePrivacyConfiguration: BehaviorRelay<PresencePrivacyConfiguration>
}

