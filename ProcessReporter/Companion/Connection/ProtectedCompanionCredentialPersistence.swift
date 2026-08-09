import Foundation

actor ProtectedCompanionCredentialPersistence: CompanionConnectionCredentialPersistence {
    private static let account = "yohaku.companion.device-token.v1"

    func resolveDeviceToken() async throws -> String? {
        let resolution = await CredentialStore.resolve("", for: Self.account)
        guard !resolution.journalUnavailable, !resolution.requiresUserAttention else {
            throw CompanionConnectionStoreError.credentialStorageUnavailable
        }
        let token = resolution.runtimeValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    func replaceDeviceToken(
        previousValue: String,
        newValue: String,
        pendingMetadataKey: String,
        pendingMetadataValue: String
    ) async throws -> CompanionCredentialMutationResult {
        guard pendingMetadataKey == CompanionConnectionStore.metadataKey,
              Self.isNonSecretMetadata(pendingMetadataValue)
        else {
            throw CompanionConnectionStoreError.invalidMetadata
        }

        let result = await CredentialStore.apply(
            [
                CredentialStore.Change(
                    account: Self.account,
                    previousValue: previousValue,
                    newValue: newValue
                ),
            ],
            pendingPreferences: [
                CredentialStore.PendingPreference(
                    key: pendingMetadataKey,
                    value: pendingMetadataValue
                ),
            ]
        )
        guard result.succeeded else {
            throw CompanionConnectionStoreError.credentialPersistenceFailed
        }
        return CompanionCredentialMutationResult(
            retainedClearedKeychainValue: result.retainedClearedKeychainValue
        )
    }

    private static func isNonSecretMetadata(_ value: String) -> Bool {
        // An empty value is the tombstone used when a connection is removed.
        guard !value.isEmpty else { return true }
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return false
        }
        let allowedKeys: Set<String> = [
            "storageVersion",
            "baseURL",
            "deviceID",
            "scopes",
            "pairingNextSequence",
            "isLiveDeskEnabled",
        ]
        guard Set(object.keys) == allowedKeys else { return false }
        return (try? JSONDecoder().decode(CompanionConnectionMetadata.self, from: data)) != nil
    }
}
