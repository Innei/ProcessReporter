//
//  PreferencesDataModel+Integration.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/8.
//

import Foundation
import RxCocoa
import RxSwift

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
	static func fromDictionary(_ dict: Any) -> MixSpaceIntegration {
		guard let dict = dict as? [String: Any] else { return MixSpaceIntegration() }
		var integration = MixSpaceIntegration()
		integration.isEnabled = dict["isEnabled"] as? Bool ?? false
		integration.apiToken = dict["apiToken"] as? String ?? ""
		integration.endpoint = dict["endpoint"] as? String ?? ""
		integration.requestMethod = dict["requestMethod"] as? String ?? "POST"
		return integration
	}
}

extension SlackIntegration {
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
}

extension S3Integration {
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
}

extension PreferencesDataModel {
    @UserDefaultsRelay("s3Integration", defaultValue: S3Integration())
    static var s3Integration: BehaviorRelay<S3Integration>
}

// MARK: - Discord Integration Model

struct DiscordIntegration: UserDefaultsJSONStorable, DictionaryConvertible {
    var isEnabled: Bool = false
    var applicationId: String = ""
    var showProcessInfo: Bool = true
    var showMediaInfo: Bool = true
    var prioritizeMedia: Bool = true
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
    static func fromDictionary(_ dict: Any) -> DiscordIntegration {
        guard let dict = dict as? [String: Any] else { return DiscordIntegration() }
        var integration = DiscordIntegration()
        integration.isEnabled = dict["isEnabled"] as? Bool ?? false
        integration.applicationId = dict["applicationId"] as? String ?? ""
        integration.showProcessInfo = dict["showProcessInfo"] as? Bool ?? true
        integration.showMediaInfo = dict["showMediaInfo"] as? Bool ?? true
        integration.prioritizeMedia = dict["prioritizeMedia"] as? Bool ?? true
        integration.showTimestamps = dict["showTimestamps"] as? Bool ?? true
        integration.customLargeImageKey = dict["customLargeImageKey"] as? String ?? ""
        integration.customLargeImageText = dict["customLargeImageText"] as? String ?? ""
        integration.brandSmallImageKey = dict["brandSmallImageKey"] as? String ?? "processreporter"
        integration.enableButtons = dict["enableButtons"] as? Bool ?? false
        integration.buttonLabel = dict["buttonLabel"] as? String ?? ""
        integration.buttonUrl = dict["buttonUrl"] as? String ?? ""
        return integration
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
