//
//  PreferencesDataModel+General.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/8.
//

import Foundation
import RxCocoa
import RxSwift

extension PreferencesDataModel {
    @UserDefaultsRelay("isEnabled", defaultValue: false)
    static var isEnabled: BehaviorRelay<Bool>

    @UserDefaultsRelay("sendInterval", defaultValue: SendInterval.tenSeconds)
    static var sendInterval: BehaviorRelay<SendInterval>

    @UserDefaultsRelay("focusReport", defaultValue: true)
    static var focusReport: BehaviorRelay<Bool>

    @UserDefaultsRelay(
        "enabledTypes", defaultValue: ReporterTypesSet(types: [.media, .process]))
    static var enabledTypes: BehaviorRelay<ReporterTypesSet>
    
    @UserDefaultsRelay("ignoreNullName", defaultValue: true)
    static var ignoreNullArtist: BehaviorRelay<Bool>
    
    @UserDefaultsRelay("hasShownMediaControlInstallPrompt", defaultValue: false)
    static var hasShownMediaControlInstallPrompt: BehaviorRelay<Bool>
}

extension Reporter.Types: UserDefaultsStorable {
    func toStorable() -> Any? {
        switch self {
        case .media:
            return "media"
        case .process:
            return "process"
        }
    }

    static func fromStorable(_ value: Any?) -> Reporter.Types? {
        guard let stringValue = value as? String else { return nil }
        switch stringValue {
        case "media":
            return .media
        case "process":
            return .process
        default:
            return nil
        }
    }
}

// 创建一个包装类型
struct ReporterTypesSet: UserDefaultsStorable {
    let types: Set<Reporter.Types>

    func toStorable() -> Any? {
        // 将 Set 转换为数组，然后将每个元素转换为可存储的形式
        return Array(types).compactMap { $0.toStorable() }
    }

    static func fromStorable(_ value: Any?) -> ReporterTypesSet? {
        guard let array = value as? [String] else {
            return nil
        }
        let types = array.compactMap(Reporter.Types.fromStorable)
        return ReporterTypesSet(types: Set(types))
    }
}
