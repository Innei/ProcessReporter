//
//  PreferencesDataModel+Integration.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/8.
//

import Foundation
import RxCocoa
import RxSwift

enum IntegrationCredentialAccount {
	static let mixSpaceToken = "mixspace.api-token"
	static let slackToken = "slack.api-token"
	static let s3AccessKey = "s3.access-key"
	static let s3SecretKey = "s3.secret-key"
}

private func encodeIntegrationForUserDefaults<Value: Encodable>(_ value: Value) -> Any? {
	let encoder = JSONEncoder()
	encoder.outputFormatting = .sortedKeys
	guard let data = try? encoder.encode(value) else { return nil }
	return String(data: data, encoding: .utf8)
}

private func decodeIntegrationFromUserDefaults<Value: Decodable>(
	_ value: Any?,
	as type: Value.Type
) -> Value? {
	guard let string = value as? String,
		let data = string.data(using: .utf8)
	else { return nil }
	return try? JSONDecoder().decode(type, from: data)
}

struct MixSpaceIntegration: UserDefaultsJSONStorable, DictionaryConvertible {
	var isEnabled: Bool = false
	var apiToken: String = ""
	var endpoint: String = ""
	var requestMethod: String = "POST"
}

struct SlackIntegration: UserDefaultsJSONStorable, DictionaryConvertible {
	var isEnabled: Bool = false
	var apiToken: String = ""
	var globalCustomEmoji: String = "🎵"
	var statusTextTemplateString: String = "正在使用 {media_process_name} 听 {media_name_artist}"
	var expiration: Int = 60
	var defaultEmoji: String = ""
	var defaultStatusText: String = ""
	var customEmojiConditionList: EmojiConditionList = .init()
}

struct EmojiConditionList: Codable, UserDefaultsStorable, DictionaryConvertible, DictionaryConvertibleDelegate {
	func toDictionary() -> Any {
		return conditions.map { $0.toDictionary() }
	}

	struct EmojiCondition: Codable, Equatable, UserDefaultsJSONStorable, DictionaryConvertible {
		static func fromDictionary(_ dict: Any) -> EmojiConditionList.EmojiCondition {
			if let dict = dict as? [String: Any] {
				let when = dict["when"] as? String ?? ""
				let emoji = dict["emoji"] as? String ?? ""
				return EmojiCondition(when: when, emoji: emoji)
			}
			return .init(when: "", emoji: "")
		}

		let when: String
		let emoji: String
	}

	private var conditions: [EmojiCondition] = []

	public func getConditions() -> [EmojiCondition] {
		return conditions
	}

	init(conditions: [EmojiCondition] = []) {
		self.conditions = conditions
	}

	func toStorable() -> Any? {
		return conditions.map { $0.toDictionary() }
	}

	static func fromStorable(_ value: Any?) -> EmojiConditionList? {
		guard let array = value as? [[String: Any]] else { return nil }
		let conditions = array.compactMap { EmojiCondition.fromDictionary($0) }
		return EmojiConditionList(conditions: conditions)
	}

	static func fromDictionary(_ dict: Any) -> EmojiConditionList {
		if let conditions = dict as? [[String: Any]] {
			return EmojiConditionList(conditions: conditions.compactMap { EmojiCondition.fromDictionary($0) })
		}
		return EmojiConditionList()
	}
}

// MARK: - S3 Integration Model

struct S3Integration: UserDefaultsJSONStorable, DictionaryConvertible {
	var isEnabled: Bool = false
	var bucket: String = ""
	var region: String = "us-east-1"
	var accessKey: String = ""
	var secretKey: String = ""
	var endpoint: String = ""
	var path: String = ""

	var customDomain: String = ""
}

extension PreferencesDataModel {
    @UserDefaultsRelay("mixSpaceIntegration", defaultValue: MixSpaceIntegration())
    static var mixSpaceIntegration: BehaviorRelay<MixSpaceIntegration>

    @UserDefaultsRelay("slackIntegration", defaultValue: SlackIntegration())
    static var slackIntegration: BehaviorRelay<SlackIntegration>
}

extension MixSpaceIntegration {
	private enum CodingKeys: String, CodingKey {
		case isEnabled, apiToken, endpoint, requestMethod
	}

	init(from decoder: Decoder) throws {
		self.init()
		let container = try decoder.container(keyedBy: CodingKeys.self)
		isEnabled = (try? container.decode(Bool.self, forKey: .isEnabled)) ?? isEnabled
		apiToken = (try? container.decode(String.self, forKey: .apiToken)) ?? apiToken
		endpoint = (try? container.decode(String.self, forKey: .endpoint)) ?? endpoint
		requestMethod = (try? container.decode(String.self, forKey: .requestMethod))
			?? requestMethod
	}

	static func fromDictionary(_ dict: Any) -> MixSpaceIntegration {
		guard let dict = dict as? [String: Any] else { return MixSpaceIntegration() }
		var integration = MixSpaceIntegration()
		integration.isEnabled = dict["isEnabled"] as? Bool ?? false
		integration.apiToken = dict["apiToken"] as? String ?? ""
		integration.endpoint = dict["endpoint"] as? String ?? ""
		integration.requestMethod = dict["requestMethod"] as? String ?? "POST"
		return integration
	}

	/// Decodes an exported integration only after validating the complete
	/// non-secret contract. `fromDictionary` remains intentionally tolerant for
	/// historical internal callers; settings import must not use its defaulting
	/// behavior because a truncated dictionary could otherwise clear a working
	/// configuration while still being reported as a successful restore.
	static func validatedImportDictionary(_ dict: [String: Any]) -> MixSpaceIntegration? {
		guard let isEnabled = dict["isEnabled"] as? Bool,
		      let endpoint = dict["endpoint"] as? String,
		      let requestMethod = dict["requestMethod"] as? String,
		      ["POST", "PUT", "DELETE", "PATCH"].contains(requestMethod),
		      dict["apiToken"].map({ $0 is String }) ?? true
		else { return nil }

		return MixSpaceIntegration(
			isEnabled: isEnabled,
			apiToken: "",
			endpoint: endpoint,
			requestMethod: requestMethod
		)
	}

	func toStorable() -> Any? {
		var storedValue = self
		storedValue.apiToken = ""
		return encodeIntegrationForUserDefaults(storedValue)
	}

	static func fromStorable(_ value: Any?) -> MixSpaceIntegration? {
		decodeIntegrationFromUserDefaults(value, as: Self.self) ?? .init()
	}

	func persistCredentialChanges(
		comparedTo previous: Self
	) async -> CredentialStore.ApplyResult {
		var storedConfiguration = self
		storedConfiguration.apiToken = ""
		guard let storedValue = encodeIntegrationForUserDefaults(
			storedConfiguration
		) as? String else {
			return .failed
		}
		return await CredentialStore.apply([
			.init(
				account: IntegrationCredentialAccount.mixSpaceToken,
				previousValue: previous.apiToken,
				newValue: apiToken
			)
		], pendingPreferences: [
			.init(key: "mixSpaceIntegration", value: storedValue),
		])
	}

	func exportDictionary() -> [String: Any] {
		var dictionary = toDictionary()
		dictionary.removeValue(forKey: "apiToken")
		return dictionary
	}
}

extension SlackIntegration {
	private enum CodingKeys: String, CodingKey {
		case isEnabled, apiToken, globalCustomEmoji, statusTextTemplateString
		case expiration, defaultEmoji, defaultStatusText, customEmojiConditionList
	}

	init(from decoder: Decoder) throws {
		self.init()
		let container = try decoder.container(keyedBy: CodingKeys.self)
		isEnabled = (try? container.decode(Bool.self, forKey: .isEnabled)) ?? isEnabled
		apiToken = (try? container.decode(String.self, forKey: .apiToken)) ?? apiToken
		globalCustomEmoji = (try? container.decode(String.self, forKey: .globalCustomEmoji))
			?? globalCustomEmoji
		statusTextTemplateString = (try? container.decode(
			String.self, forKey: .statusTextTemplateString)) ?? statusTextTemplateString
		expiration = (try? container.decode(Int.self, forKey: .expiration)) ?? expiration
		defaultEmoji = (try? container.decode(String.self, forKey: .defaultEmoji))
			?? defaultEmoji
		defaultStatusText = (try? container.decode(String.self, forKey: .defaultStatusText))
			?? defaultStatusText
		customEmojiConditionList = (try? container.decode(
			EmojiConditionList.self, forKey: .customEmojiConditionList))
			?? customEmojiConditionList
	}

	static func fromDictionary(_ dict: Any) -> SlackIntegration {
		guard let dict = dict as? [String: Any] else { return SlackIntegration() }
		var integration = SlackIntegration()
		integration.isEnabled = dict["isEnabled"] as? Bool ?? false
		integration.apiToken = dict["apiToken"] as? String ?? ""
		integration.globalCustomEmoji = dict["globalCustomEmoji"] as? String ?? ""
		integration.statusTextTemplateString = dict["statusTextTemplateString"] as? String ?? ""
		integration.expiration = dict["expiration"] as? Int ?? 60
		integration.defaultEmoji = dict["defaultEmoji"] as? String ?? ""
		integration.defaultStatusText = dict["defaultStatusText"] as? String ?? ""
		if let conditions = dict["customEmojiConditionList"] as? [[String: Any]] {
			integration.customEmojiConditionList = EmojiConditionList(conditions: conditions.compactMap { EmojiConditionList.EmojiCondition.fromDictionary($0) })
		}
		return integration
	}

	static func validatedImportDictionary(_ dict: [String: Any]) -> SlackIntegration? {
		guard let isEnabled = dict["isEnabled"] as? Bool,
		      let globalCustomEmoji = dict["globalCustomEmoji"] as? String,
		      let statusTextTemplateString = dict["statusTextTemplateString"] as? String,
		      let expiration = dict["expiration"] as? Int,
		      (1 ... 86_400).contains(expiration),
		      let defaultEmoji = dict["defaultEmoji"] as? String,
		      let defaultStatusText = dict["defaultStatusText"] as? String,
		      let conditionDictionaries = dict["customEmojiConditionList"] as? [[String: Any]],
		      dict["apiToken"].map({ $0 is String }) ?? true
		else { return nil }

		var conditions: [EmojiConditionList.EmojiCondition] = []
		conditions.reserveCapacity(conditionDictionaries.count)
		for conditionDictionary in conditionDictionaries {
			guard let when = conditionDictionary["when"] as? String,
			      let emoji = conditionDictionary["emoji"] as? String
			else { return nil }
			conditions.append(.init(when: when, emoji: emoji))
		}

		return SlackIntegration(
			isEnabled: isEnabled,
			apiToken: "",
			globalCustomEmoji: globalCustomEmoji,
			statusTextTemplateString: statusTextTemplateString,
			expiration: expiration,
			defaultEmoji: defaultEmoji,
			defaultStatusText: defaultStatusText,
			customEmojiConditionList: .init(conditions: conditions)
		)
	}

	func toStorable() -> Any? {
		var storedValue = self
		storedValue.apiToken = ""
		return encodeIntegrationForUserDefaults(storedValue)
	}

	static func fromStorable(_ value: Any?) -> SlackIntegration? {
		decodeIntegrationFromUserDefaults(value, as: Self.self) ?? .init()
	}

	func persistCredentialChanges(
		comparedTo previous: Self
	) async -> CredentialStore.ApplyResult {
		var storedConfiguration = self
		storedConfiguration.apiToken = ""
		guard let storedValue = encodeIntegrationForUserDefaults(
			storedConfiguration
		) as? String else {
			return .failed
		}
		return await CredentialStore.apply([
			.init(
				account: IntegrationCredentialAccount.slackToken,
				previousValue: previous.apiToken,
				newValue: apiToken
			)
		], pendingPreferences: [
			.init(key: "slackIntegration", value: storedValue),
		])
	}

	func exportDictionary() -> [String: Any] {
		var dictionary = toDictionary()
		dictionary.removeValue(forKey: "apiToken")
		return dictionary
	}
}

extension S3Integration {
	private enum CodingKeys: String, CodingKey {
		case isEnabled, bucket, region, accessKey, secretKey, endpoint, path, customDomain
	}

	init(from decoder: Decoder) throws {
		self.init()
		let container = try decoder.container(keyedBy: CodingKeys.self)
		isEnabled = (try? container.decode(Bool.self, forKey: .isEnabled)) ?? isEnabled
		bucket = (try? container.decode(String.self, forKey: .bucket)) ?? bucket
		region = (try? container.decode(String.self, forKey: .region)) ?? region
		accessKey = (try? container.decode(String.self, forKey: .accessKey)) ?? accessKey
		secretKey = (try? container.decode(String.self, forKey: .secretKey)) ?? secretKey
		endpoint = (try? container.decode(String.self, forKey: .endpoint)) ?? endpoint
		path = (try? container.decode(String.self, forKey: .path)) ?? path
		customDomain = (try? container.decode(String.self, forKey: .customDomain))
			?? customDomain
	}

	static func fromDictionary(_ dict: Any) -> S3Integration {
		guard let dict = dict as? [String: Any] else { return S3Integration() }

		var integration = S3Integration()
		integration.isEnabled = dict["isEnabled"] as? Bool ?? false
		integration.bucket = dict["bucket"] as? String ?? ""
		integration.region = dict["region"] as? String ?? "us-east-1"
		integration.accessKey = dict["accessKey"] as? String ?? ""
		integration.secretKey = dict["secretKey"] as? String ?? ""
		integration.endpoint = dict["endpoint"] as? String ?? ""
		integration.path = dict["path"] as? String ?? ""
		integration.customDomain = dict["customDomain"] as? String ?? ""
		return integration
	}

	static func validatedImportDictionary(_ dict: [String: Any]) -> S3Integration? {
		guard let isEnabled = dict["isEnabled"] as? Bool,
		      let bucket = dict["bucket"] as? String,
		      let region = dict["region"] as? String,
		      let endpoint = dict["endpoint"] as? String,
		      let path = dict["path"] as? String,
		      dict["accessKey"].map({ $0 is String }) ?? true,
		      dict["secretKey"].map({ $0 is String }) ?? true
		else { return nil }

		let customDomain: String
		if let rawCustomDomain = dict["customDomain"] {
			guard let value = rawCustomDomain as? String else { return nil }
			customDomain = value
		} else {
			// The first S3 export schema predated custom domains and included both
			// credential keys. Requiring that exact fingerprint distinguishes it
			// from a truncated modern, credential-redacted export.
			guard dict["accessKey"] is String, dict["secretKey"] is String else {
				return nil
			}
			customDomain = ""
		}

		return S3Integration(
			isEnabled: isEnabled,
			bucket: bucket,
			region: region,
			accessKey: "",
			secretKey: "",
			endpoint: endpoint,
			path: path,
			customDomain: customDomain
		)
	}

	func toStorable() -> Any? {
		var storedValue = self
		storedValue.accessKey = ""
		storedValue.secretKey = ""
		return encodeIntegrationForUserDefaults(storedValue)
	}

	static func fromStorable(_ value: Any?) -> S3Integration? {
		decodeIntegrationFromUserDefaults(value, as: Self.self) ?? .init()
	}

	func persistCredentialChanges(
		comparedTo previous: Self
	) async -> CredentialStore.ApplyResult {
		var storedConfiguration = self
		storedConfiguration.accessKey = ""
		storedConfiguration.secretKey = ""
		guard let storedValue = encodeIntegrationForUserDefaults(
			storedConfiguration
		) as? String else {
			return .failed
		}
		return await CredentialStore.apply([
			.init(
				account: IntegrationCredentialAccount.s3AccessKey,
				previousValue: previous.accessKey,
				newValue: accessKey
			),
			.init(
				account: IntegrationCredentialAccount.s3SecretKey,
				previousValue: previous.secretKey,
				newValue: secretKey
			),
		], pendingPreferences: [
			.init(key: "s3Integration", value: storedValue),
		])
	}

	func exportDictionary() -> [String: Any] {
		var dictionary = toDictionary()
		dictionary.removeValue(forKey: "accessKey")
		dictionary.removeValue(forKey: "secretKey")
		return dictionary
	}
}

extension PreferencesDataModel {
    @UserDefaultsRelay("s3Integration", defaultValue: S3Integration())
    static var s3Integration: BehaviorRelay<S3Integration>

    static let integrationCredentialsReady = BehaviorRelay<Bool>(value: false)
    static private(set) var integrationCredentialRecoveryWarning: String?
    static private(set) var integrationCredentialStoreUnavailable = false

    /// The credential journal is an authority boundary, not only a UI warning.
    /// Keep every Reporter entry point fail-closed even if a caller writes to the
    /// persisted `isEnabled` relay while the journal is unavailable.
    static var reportingAllowed: Bool {
        isEnabled.value
            && !integrationCredentialStoreUnavailable
            && hasCompletedOnboarding.value
            && hasEnabledConfiguredPresenceDestination
    }

    /// S3 is asset infrastructure and never satisfies the destination invariant.
    /// A Presence session is runnable only when at least one real destination is
    /// both enabled and minimally configured.
    static var hasEnabledConfiguredPresenceDestination: Bool {
        let mixSpace = mixSpaceIntegration.value
        let slack = slackIntegration.value
        let discord = discordIntegration.value

        return (mixSpace.isEnabled && mixSpace.isValidPresenceDestination)
            || (slack.isEnabled && slack.isValidPresenceDestination)
            || (discord.isEnabled && discord.isValidPresenceDestination)
    }

    /// Applies a user- or import-requested reporting state without allowing an
    /// unreadable credential authority to be bypassed.
    @discardableResult
    static func setReportingEnabled(_ requestedValue: Bool) -> Bool {
        guard !requestedValue
                || (!integrationCredentialStoreUnavailable
                    && hasCompletedOnboarding.value
                    && hasEnabledConfiguredPresenceDestination)
        else {
            isEnabled.accept(false)
            return false
        }
        isEnabled.accept(requestedValue)
        return true
    }

    /// Configuration editors may disable or invalidate the final destination
    /// while sharing is active. Reconcile that transition immediately so the
    /// persisted master switch cannot claim to be running without a receiver.
    static func pauseReportingIfDestinationUnavailable() {
        guard isEnabled.value, !hasEnabledConfiguredPresenceDestination else { return }
        isEnabled.accept(false)
    }

    /// Loads Keychain-backed credentials before the Reporter subscribes to the
    /// integration relays. Security framework calls run on CredentialStore's
    /// serial queue, while relay updates remain isolated to the main actor.
    static func hydrateIntegrationCredentials() async {
        defer { integrationCredentialsReady.accept(true) }
        integrationCredentialRecoveryWarning = nil
        integrationCredentialStoreUnavailable = false

        let currentMixSpace = mixSpaceIntegration.value
        let currentSlack = slackIntegration.value
        let currentS3 = s3Integration.value

        let mixSpaceResolution = await CredentialStore.resolve(
            currentMixSpace.apiToken,
            for: IntegrationCredentialAccount.mixSpaceToken
        )
        guard !Task.isCancelled else { return }
        let slackResolution = await CredentialStore.resolve(
            currentSlack.apiToken,
            for: IntegrationCredentialAccount.slackToken
        )
        guard !Task.isCancelled else { return }
        let s3AccessKeyResolution = await CredentialStore.resolve(
            currentS3.accessKey,
            for: IntegrationCredentialAccount.s3AccessKey
        )
        guard !Task.isCancelled else { return }
        let s3SecretKeyResolution = await CredentialStore.resolve(
            currentS3.secretKey,
            for: IntegrationCredentialAccount.s3SecretKey
        )
        guard !Task.isCancelled else { return }

        // Keychain work is intentionally performed off the main actor. Merge each
        // resolved credential only when that field still has the value captured
        // before the await. This preserves newer UI edits without discarding
        // unrelated metadata changes made while hydration was in flight.
        let latestMixSpace = mixSpaceIntegration.value
        if latestMixSpace.apiToken == currentMixSpace.apiToken {
            if mixSpaceResolution.runtimeValue != latestMixSpace.apiToken {
                var mergedMixSpace = latestMixSpace
                mergedMixSpace.apiToken = mixSpaceResolution.runtimeValue
                mixSpaceIntegration.accept(mergedMixSpace)
            }
            if mixSpaceResolution.persistedValue != currentMixSpace.apiToken {
                var persistedMixSpace = mixSpaceIntegration.value
                persistedMixSpace.apiToken = mixSpaceResolution.persistedValue
                if let storedValue = encodeIntegrationForUserDefaults(persistedMixSpace) {
                    UserDefaults.standard.set(storedValue, forKey: "mixSpaceIntegration")
                }
            }
        }

        let latestSlack = slackIntegration.value
        if latestSlack.apiToken == currentSlack.apiToken {
            if slackResolution.runtimeValue != latestSlack.apiToken {
                var mergedSlack = latestSlack
                mergedSlack.apiToken = slackResolution.runtimeValue
                slackIntegration.accept(mergedSlack)
            }
            if slackResolution.persistedValue != currentSlack.apiToken {
                var persistedSlack = slackIntegration.value
                persistedSlack.apiToken = slackResolution.persistedValue
                if let storedValue = encodeIntegrationForUserDefaults(persistedSlack) {
                    UserDefaults.standard.set(storedValue, forKey: "slackIntegration")
                }
            }
        }

        let latestS3 = s3Integration.value
        let canMergeAccessKey = latestS3.accessKey == currentS3.accessKey
        let canMergeSecretKey = latestS3.secretKey == currentS3.secretKey
        var mergedS3 = latestS3
        if canMergeAccessKey {
            mergedS3.accessKey = s3AccessKeyResolution.runtimeValue
        }
        if canMergeSecretKey {
            mergedS3.secretKey = s3SecretKeyResolution.runtimeValue
        }
        if mergedS3.accessKey != latestS3.accessKey
            || mergedS3.secretKey != latestS3.secretKey
        {
            s3Integration.accept(mergedS3)
        }

        let shouldPersistAccessKey = canMergeAccessKey
            && s3AccessKeyResolution.persistedValue != currentS3.accessKey
        let shouldPersistSecretKey = canMergeSecretKey
            && s3SecretKeyResolution.persistedValue != currentS3.secretKey
        if shouldPersistAccessKey || shouldPersistSecretKey {
            var persistedS3 = s3Integration.value
            // Manual migration storage bypasses S3Integration.toStorable(), so
            // every credential field must be assigned explicitly. A field changed
            // by a newer transaction is already Keychain-backed and stays redacted.
            persistedS3.accessKey = canMergeAccessKey
                ? s3AccessKeyResolution.persistedValue : ""
            persistedS3.secretKey = canMergeSecretKey
                ? s3SecretKeyResolution.persistedValue : ""
            if let storedValue = encodeIntegrationForUserDefaults(persistedS3) {
                UserDefaults.standard.set(storedValue, forKey: "s3Integration")
            }
        }

        // Confirm removal of any plaintext fields written by pre-journal builds.
        // If synchronization is deferred, the protected journal remains the
        // authority and the next launch repeats this idempotent redaction pass.
        if !UserDefaults.standard.synchronize() {
            NSLog("Integration credential redaction synchronization was deferred")
        }

        let journalUnavailable = [
            mixSpaceResolution,
            slackResolution,
            s3AccessKeyResolution,
            s3SecretKeyResolution,
        ].contains(where: \.journalUnavailable)
        if journalUnavailable {
            // Do not let integrations send with a mixture of stale preferences and
            // unknown credential authority. Preserve every source and require an
            // explicit backup-preserving recovery decision from the user.
            PreferencesDataModel.setReportingEnabled(false)
            integrationCredentialStoreUnavailable = true
            integrationCredentialRecoveryWarning =
                "The protected integration credential journal could not be read and was not overwritten. "
                + "Reporting was paused. Keep the store in place, or back it up and reset it before re-entering credentials."
            return
        }

        var integrationsNeedingCredentials: [String] = []
        if mixSpaceResolution.requiresUserAttention,
           mixSpaceIntegration.value.isEnabled,
           mixSpaceIntegration.value.apiToken.isEmpty
        {
            integrationsNeedingCredentials.append("Mix Space")
        }
        if slackResolution.requiresUserAttention,
           slackIntegration.value.isEnabled,
           slackIntegration.value.apiToken.isEmpty
        {
            integrationsNeedingCredentials.append("Slack")
        }
        let runtimeS3 = s3Integration.value
        if runtimeS3.isEnabled,
           (s3AccessKeyResolution.requiresUserAttention && runtimeS3.accessKey.isEmpty
            || s3SecretKeyResolution.requiresUserAttention && runtimeS3.secretKey.isEmpty)
        {
            integrationsNeedingCredentials.append("S3")
        }
        var integrationsUsingUnprotectedLegacyValues: [String] = []
        if mixSpaceResolution.requiresUserAttention,
           !mixSpaceResolution.runtimeValue.isEmpty,
           !mixSpaceResolution.persistedValue.isEmpty
        {
            integrationsUsingUnprotectedLegacyValues.append("Mix Space")
        }
        if slackResolution.requiresUserAttention,
           !slackResolution.runtimeValue.isEmpty,
           !slackResolution.persistedValue.isEmpty
        {
            integrationsUsingUnprotectedLegacyValues.append("Slack")
        }
        if (s3AccessKeyResolution.requiresUserAttention
            && !s3AccessKeyResolution.runtimeValue.isEmpty
            && !s3AccessKeyResolution.persistedValue.isEmpty)
            || (s3SecretKeyResolution.requiresUserAttention
                && !s3SecretKeyResolution.runtimeValue.isEmpty
                && !s3SecretKeyResolution.persistedValue.isEmpty)
        {
            integrationsUsingUnprotectedLegacyValues.append("S3")
        }

        var warnings: [String] = []
        if !integrationsNeedingCredentials.isEmpty {
            warnings.append(
                "ProcessReporter could not read previously stored credentials for "
                + integrationsNeedingCredentials.joined(separator: ", ")
                + ". Re-enter them in Integration settings. Existing Keychain items were not deleted."
            )
        }
        if !integrationsUsingUnprotectedLegacyValues.isEmpty {
            warnings.append(
                "Credentials for "
                + integrationsUsingUnprotectedLegacyValues.joined(separator: ", ")
                + " remain available, but could not be migrated into protected storage. "
                + "Resolve the storage error and save them again."
            )
        }
        if !warnings.isEmpty {
            integrationCredentialRecoveryWarning = warnings.joined(separator: " ")
        }
    }
}

private extension String {
    var hasNonWhitespaceContent: Bool {
        !trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension MixSpaceIntegration {
    var hasPresenceDestinationConfiguration: Bool {
        endpoint.hasNonWhitespaceContent || apiToken.hasNonWhitespaceContent
    }

    var isValidPresenceDestination: Bool {
        guard apiToken.hasNonWhitespaceContent,
              let components = URLComponents(
                string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
              ),
              let scheme = components.scheme?.lowercased(),
              let host = components.host,
              components.user == nil,
              components.password == nil,
              components.url != nil
        else { return false }
        return scheme == "https" || (scheme == "http" && isLoopbackHost(host))
    }
}

extension SlackIntegration {
    var hasPresenceDestinationConfiguration: Bool {
        apiToken.hasNonWhitespaceContent
    }

    var isValidPresenceDestination: Bool {
        apiToken.hasNonWhitespaceContent
    }
}

extension DiscordIntegration {
    var hasPresenceDestinationConfiguration: Bool {
        applicationId.hasNonWhitespaceContent
    }

    var isValidPresenceDestination: Bool {
        guard let value = Int64(
            applicationId.trimmingCharacters(in: .whitespacesAndNewlines)
        ) else { return false }
        return value > 0
    }
}

extension S3Integration {
    var hasAssetHostingConfiguration: Bool {
        isEnabled
            || [bucket, accessKey, secretKey, endpoint, path, customDomain]
                .contains(where: \.hasNonWhitespaceContent)
    }

    var isValidAssetHostingConfiguration: Bool {
        guard [bucket, region, accessKey, secretKey]
            .allSatisfy(\.hasNonWhitespaceContent)
        else { return false }

        if endpoint.hasNonWhitespaceContent,
           validatedSecurePublicURL(endpoint) == nil
        {
            return false
        }
        if customDomain.hasNonWhitespaceContent,
           validatedSecurePublicURL(customDomain) == nil
        {
            return false
        }
        return true
    }
}

// MARK: - Discord Integration Model

struct DiscordIntegration: UserDefaultsJSONStorable, DictionaryConvertible {
    var isEnabled: Bool = false
    var applicationId: String = ""
    var showProcessInfo: Bool = true
    var showMediaInfo: Bool = true
    var prioritizeMedia: Bool = true
    var useListeningForMedia: Bool = true
    var showTimestamps: Bool = true

    // Asset keys (must be pre-uploaded in Discord Dev Portal)
    var customLargeImageKey: String = ""
    var customLargeImageText: String = ""
    var brandSmallImageKey: String = "processreporter"

    // Buttons (optional, supports one configurable button)
    var enableButtons: Bool = false
    var buttonLabel: String = ""
    var buttonUrl: String = ""
}

extension DiscordIntegration {
	private enum CodingKeys: String, CodingKey {
		case isEnabled, applicationId, showProcessInfo, showMediaInfo, prioritizeMedia
		case useListeningForMedia, showTimestamps, customLargeImageKey
		case customLargeImageText, brandSmallImageKey, enableButtons, buttonLabel, buttonUrl
	}

	init(from decoder: Decoder) throws {
		self.init()
		let container = try decoder.container(keyedBy: CodingKeys.self)
		isEnabled = (try? container.decode(Bool.self, forKey: .isEnabled)) ?? isEnabled
		applicationId = (try? container.decode(String.self, forKey: .applicationId))
			?? applicationId
		showProcessInfo = (try? container.decode(Bool.self, forKey: .showProcessInfo))
			?? showProcessInfo
		showMediaInfo = (try? container.decode(Bool.self, forKey: .showMediaInfo))
			?? showMediaInfo
		prioritizeMedia = (try? container.decode(Bool.self, forKey: .prioritizeMedia))
			?? prioritizeMedia
		useListeningForMedia = (try? container.decode(
			Bool.self, forKey: .useListeningForMedia)) ?? useListeningForMedia
		showTimestamps = (try? container.decode(Bool.self, forKey: .showTimestamps))
			?? showTimestamps
		customLargeImageKey = (try? container.decode(String.self, forKey: .customLargeImageKey))
			?? customLargeImageKey
		customLargeImageText = (try? container.decode(
			String.self, forKey: .customLargeImageText)) ?? customLargeImageText
		brandSmallImageKey = (try? container.decode(String.self, forKey: .brandSmallImageKey))
			?? brandSmallImageKey
		enableButtons = (try? container.decode(Bool.self, forKey: .enableButtons))
			?? enableButtons
		buttonLabel = (try? container.decode(String.self, forKey: .buttonLabel)) ?? buttonLabel
		buttonUrl = (try? container.decode(String.self, forKey: .buttonUrl)) ?? buttonUrl
	}

    static func fromDictionary(_ dict: Any) -> DiscordIntegration {
        guard let dict = dict as? [String: Any] else { return DiscordIntegration() }
        var integration = DiscordIntegration()
        integration.isEnabled = dict["isEnabled"] as? Bool ?? false
        integration.applicationId = dict["applicationId"] as? String ?? ""
        integration.showProcessInfo = dict["showProcessInfo"] as? Bool ?? true
        integration.showMediaInfo = dict["showMediaInfo"] as? Bool ?? true
        integration.prioritizeMedia = dict["prioritizeMedia"] as? Bool ?? true
        integration.useListeningForMedia = dict["useListeningForMedia"] as? Bool ?? true
        integration.showTimestamps = dict["showTimestamps"] as? Bool ?? true
        integration.customLargeImageKey = dict["customLargeImageKey"] as? String ?? ""
        integration.customLargeImageText = dict["customLargeImageText"] as? String ?? ""
        integration.brandSmallImageKey = dict["brandSmallImageKey"] as? String ?? "processreporter"
        integration.enableButtons = dict["enableButtons"] as? Bool ?? false
        integration.buttonLabel = dict["buttonLabel"] as? String ?? ""
        integration.buttonUrl = dict["buttonUrl"] as? String ?? ""
        return integration
    }

	static func validatedImportDictionary(_ dict: [String: Any]) -> DiscordIntegration? {
		guard let isEnabled = dict["isEnabled"] as? Bool,
		      let applicationId = dict["applicationId"] as? String,
		      let showProcessInfo = dict["showProcessInfo"] as? Bool,
		      let showMediaInfo = dict["showMediaInfo"] as? Bool,
		      let prioritizeMedia = dict["prioritizeMedia"] as? Bool,
		      let showTimestamps = dict["showTimestamps"] as? Bool,
		      let customLargeImageKey = dict["customLargeImageKey"] as? String,
		      let customLargeImageText = dict["customLargeImageText"] as? String,
		      let brandSmallImageKey = dict["brandSmallImageKey"] as? String
		else { return nil }

		let useListeningForMedia: Bool
		if let rawUseListeningForMedia = dict["useListeningForMedia"] {
			guard let value = rawUseListeningForMedia as? Bool else { return nil }
			useListeningForMedia = value
		} else {
			useListeningForMedia = true
		}

		let buttonKeys = ["enableButtons", "buttonLabel", "buttonUrl"]
		let suppliedButtonKeyCount = buttonKeys.filter { dict[$0] != nil }.count
		guard suppliedButtonKeyCount == 0 || suppliedButtonKeyCount == buttonKeys.count else {
			return nil
		}
		let enableButtons: Bool
		let buttonLabel: String
		let buttonUrl: String
		if suppliedButtonKeyCount == buttonKeys.count {
			guard let importedEnableButtons = dict["enableButtons"] as? Bool,
			      let importedButtonLabel = dict["buttonLabel"] as? String,
			      let importedButtonURL = dict["buttonUrl"] as? String
			else { return nil }
			enableButtons = importedEnableButtons
			buttonLabel = importedButtonLabel
			buttonUrl = importedButtonURL
		} else {
			enableButtons = false
			buttonLabel = ""
			buttonUrl = ""
		}

		return DiscordIntegration(
			isEnabled: isEnabled,
			applicationId: applicationId,
			showProcessInfo: showProcessInfo,
			showMediaInfo: showMediaInfo,
			prioritizeMedia: prioritizeMedia,
			useListeningForMedia: useListeningForMedia,
			showTimestamps: showTimestamps,
			customLargeImageKey: customLargeImageKey,
			customLargeImageText: customLargeImageText,
			brandSmallImageKey: brandSmallImageKey,
			enableButtons: enableButtons,
			buttonLabel: buttonLabel,
			buttonUrl: buttonUrl
		)
	}
}

extension PreferencesDataModel {
    @UserDefaultsRelay("discordIntegration", defaultValue: DiscordIntegration())
    static var discordIntegration: BehaviorRelay<DiscordIntegration>
}

extension EmojiConditionList.EmojiCondition {
	enum Condition: String, CaseIterable {
		case equals
		case startsWith
		case endsWith
		case contains

		func fromString(_ string: String) -> Condition? {
			return Condition.allCases.first { $0.rawValue == string }
		}
	}

	enum Variable: String, CaseIterable {
		case processApplicationIdentifier = "process_application_identifier"
		case mediaProcessName = "media_process_name"
		case mediaProcessApplicationIdentifier = "media_process_application_identifier"

		case processName = "process_name"
		case mediaName = "media_name"
		case artist

		func fromString(_ string: String) -> Variable? {
			return Variable.allCases.first { $0.rawValue == string }
		}

		func toCopyableString() -> String {
			switch self {
			case .processName:
				return "Process Name"
			case .mediaName:
				return "Media Name"
			case .artist:
				return "Artist"
			case .processApplicationIdentifier:
				return "Process Application Identifier"
			case .mediaProcessName:
				return "Media Process Name"
			case .mediaProcessApplicationIdentifier:
				return "Media Process Application Identifier"
			}
		}
	}

	struct ParsedCondition {
		let variable: Variable
		let condition: Condition
		let value: String
	}

	static func parseWhenString(for when: String) -> ParsedCondition? {
		// Find the first and last quote to extract the value
		guard let firstQuote = when.firstIndex(of: "\""),
		      let lastQuote = when.lastIndex(of: "\""),
		      lastQuote > firstQuote
		else {
			return nil
		}

		let value = String(when[when.index(after: firstQuote) ..< lastQuote])

		// Get the prefix before the first quote and trim whitespace
		let prefix = String(when[..<firstQuote]).trimmingCharacters(in: .whitespaces)

		// Split prefix into variable and condition parts
		let components = prefix.components(separatedBy: " ").filter { !$0.isEmpty }
		guard components.count == 2 else {
			NSLog("Prefix must contain exactly two components: {variable} and condition")
			return nil
		}

		let exprPart = components[0]
		let condPart = components[1]

		// Extract variable from within curly braces
		guard exprPart.hasPrefix("{"), exprPart.hasSuffix("}") else {
			NSLog("Variable must be enclosed in curly braces")
			return nil
		}
		let exprStr = String(exprPart.dropFirst().dropLast())

		// Map strings to enum cases
		guard let variable = Variable.allCases.first(where: { $0.rawValue == exprStr }) else {
			NSLog("Invalid variable value: \(exprStr)")
			return nil
		}
		guard let condition = Condition.allCases.first(where: { $0.rawValue == condPart }) else {
			NSLog("Invalid condition value: \(condPart)")
			return nil
		}

		return ParsedCondition(variable: variable, condition: condition, value: value)
	}
}
