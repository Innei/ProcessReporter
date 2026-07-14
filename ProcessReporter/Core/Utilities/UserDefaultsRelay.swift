import Foundation
import RxCocoa
import Security
//
//  UserDefaultsRelay.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/8.
//
import RxSwift

enum CredentialStore {
    private static let service = "dev.innei.ProcessReporter.credentials"

    struct Change {
        let account: String
        let previousValue: String
        let newValue: String
    }

    private enum Lookup {
        case value(String)
        case missing
        case failure(OSStatus)
    }

    static func value(for account: String) -> String? {
        guard case let .value(value) = lookup(for: account) else { return nil }
        return value
    }

    /// Applies a group of credential changes with best-effort rollback.
    ///
    /// Every current Keychain value is read before the first mutation. If a
    /// lookup fails, nothing is changed; this prevents an inaccessible item
    /// from being mistaken for a missing credential. Successful earlier writes
    /// are restored if a later write in the same group fails.
    static func apply(_ changes: [Change]) -> Bool {
        let relevantChanges = changes.filter {
            !($0.previousValue.isEmpty && $0.newValue.isEmpty)
        }
        guard Set(relevantChanges.map(\.account)).count == relevantChanges.count else {
            NSLog("Refusing duplicate Keychain credential changes")
            return false
        }

        var snapshots: [(change: Change, lookup: Lookup)] = []
        for change in relevantChanges {
            let current = lookup(for: change.account)
            if case let .failure(status) = current {
                NSLog("Keychain preflight failed for %@ (status %d)", change.account, status)
                return false
            }
            snapshots.append((change, current))
        }

        var completed: [(change: Change, lookup: Lookup)] = []
        for snapshot in snapshots {
            let succeeded: Bool
            switch snapshot.lookup {
            case let .value(currentValue) where currentValue == snapshot.change.newValue:
                succeeded = true
            default:
                succeeded = snapshot.change.newValue.isEmpty
                    ? remove(for: snapshot.change.account)
                    : store(snapshot.change.newValue, for: snapshot.change.account)
            }

            guard succeeded else {
                rollback(completed.reversed())
                return false
            }
            completed.append(snapshot)
        }
        return true
    }

    private static func lookup(for account: String) -> Lookup {
        var query = baseQuery(for: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            NSLog("Keychain read failed for %@ (status %d)", account, status)
            return .failure(status == errSecSuccess ? errSecDecode : status)
        }
        return .value(value)
    }

    @discardableResult
    static func store(_ value: String, for account: String) -> Bool {
        // Deletion is intentionally a separate operation. A transient Keychain
        // read failure must never turn an empty in-memory value into a request to
        // delete a credential that may still exist.
        guard !value.isEmpty else { return false }

        let query = baseQuery(for: account)
        guard let data = value.data(using: .utf8) else { return false }
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else {
            NSLog("Keychain update failed for %@ (status %d)", account, updateStatus)
            return false
        }

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            NSLog("Keychain add failed for %@ (status %d)", account, addStatus)
            return false
        }
        return true
    }

    @discardableResult
    static func remove(for account: String) -> Bool {
        let status = SecItemDelete(baseQuery(for: account) as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { return true }
        NSLog("Keychain delete failed for %@ (status %d)", account, status)
        return false
    }

    private static func rollback(
        _ snapshots: ReversedCollection<[(change: Change, lookup: Lookup)]>
    ) {
        for snapshot in snapshots {
            let restored: Bool
            switch snapshot.lookup {
            case let .value(value):
                restored = store(value, for: snapshot.change.account)
            case .missing:
                restored = remove(for: snapshot.change.account)
            case .failure:
                restored = false
            }
            if !restored {
                NSLog("Keychain rollback failed for %@", snapshot.change.account)
            }
        }
    }

    private static func baseQuery(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

protocol UserDefaultsStorable {
    func toStorable() -> Any?
    static func fromStorable(_ value: Any?) -> Self?
}

@propertyWrapper
struct UserDefaultsRelay<T> {
    private let key: String
    private let defaultValue: T
    private let relay: BehaviorRelay<T>
    private let disposeBag = DisposeBag()

    init(_ key: String, defaultValue: T) {
        self.key = key
        self.defaultValue = defaultValue

        // 从 UserDefaults 读取值，如果不存在则使用默认值
        let savedValue: T

        if let storable = defaultValue as? (any UserDefaultsStorable) {
            // 使用类型擦除方式访问协议实例
            let valueType = type(of: storable)
            let storageValue = UserDefaults.standard.object(forKey: key)
            if let value = valueType.fromStorable(storageValue) as? T {
                savedValue = value

            } else {
                savedValue = defaultValue
            }
        } else {
            // 标准类型直接使用
            savedValue = UserDefaults.standard.object(forKey: key) as? T ?? defaultValue
        }

        relay = BehaviorRelay<T>(value: savedValue)

        // 观察变化并保存到 UserDefaults
        relay
            .skip(1)  // 跳过初始值
            .subscribe(onNext: { value in
                if let storable = value as? any UserDefaultsStorable {
                    // 使用协议方法转换为可存储类型
                    if let storedValue = storable.toStorable() {
                        UserDefaults.standard.set(storedValue, forKey: key)
                    } else {
                        NSLog("UserDefaults encoding failed for key %@", key)
                    }
                } else {
                    // 标准类型直接存储
                    UserDefaults.standard.set(value, forKey: key)
                }
            })
            .disposed(by: disposeBag)

        #if DEBUG
            relay.skip(1)
                .subscribe(onNext: { _ in
                    // Integration values may contain API tokens or object-storage
                    // credentials. Record the changed key without leaking its value
                    // into Console or collected diagnostic logs.
                    debugPrint("UserDefaultsRelay: \(key) changed")
                })
                .disposed(by: disposeBag)
        #endif
    }

    var wrappedValue: BehaviorRelay<T> {
        return relay
    }
}

protocol UserDefaultsJSONStorable: UserDefaultsStorable, Codable {}

extension UserDefaultsJSONStorable {
    func toStorable() -> Any? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        if let jsonData = try? encoder.encode(self) {
            let jsonString = String(data: jsonData, encoding: .utf8)
            return jsonString ?? ""
        }
        return nil
    }

    static func fromStorable(_ value: Any?) -> Self? {
        guard let value = value as? String else {
            return nil
        }
        let decoder = JSONDecoder()
        if let jsonData = value.data(using: .utf8) {
            return try? decoder.decode(Self.self, from: jsonData)
        }
        return nil
    }
}
