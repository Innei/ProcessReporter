//
//  Reporter+Slack.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/16.
//

import Alamofire
import Foundation

private let stackEndpoint = "https://slack.com/api/users.profile.set"

private struct ProfileData: Codable {
	var status_text: String
	var status_emoji: String
	var status_expiration: Int
}

private struct SlackAPIResponse: Decodable {
	let ok: Bool
	let error: String?
}

private let slackRatelimiter = Ratelimiter(
	capacity: 1,
	refillRate: 10.0 / 60.0,  // 每分钟十个请求
	minimumInterval: 10  // 最小间隔 10 秒
)

private let allowedTemplateVariants: Set<String> = [
	"{media_process_name}",
	"{media_name}",
	"{artist}",
	"{media_name_artist}",
	"{process_name}",
]

private let maximumSlackStatusDuration = 366 * 24 * 60 * 60

class SlackReporterExtension: ReporterExtension {
	var name: String = "Slack"

	var isEnabled: Bool {
		return PreferencesDataModel.shared.slackIntegration.value.isEnabled
	}

	func createReporterOptions() -> ReporterOptions {
		return ReporterOptions { data in
			let slackConfig = PreferencesDataModel.shared.slackIntegration.value
			guard slackConfig.isEnabled else {
				return .failure(.ignored)
			}
			var statusText = slackConfig.statusTextTemplateString
			if let mediaProcessName = data.mediaProcessName {
				statusText = slackConfig.statusTextTemplateString.replacingOccurrences(
					of: "{media_process_name}", with: mediaProcessName)
			}

			if let mediaName = data.mediaName {
				statusText = statusText.replacingOccurrences(of: "{media_name}", with: mediaName)
			}

			if let artistName = data.artist {
				statusText = statusText.replacingOccurrences(of: "{artist}", with: artistName)
			}

			if let mediaName = data.mediaName, let artistName = data.artist {
				statusText = statusText.replacingOccurrences(
					of: "{media_name_artist}", with: "\(artistName) - \(mediaName)")
			}

			if let processName = data.processName {
				statusText = statusText.replacingOccurrences(
					of: "{process_name}", with: processName)
			}
			let statusExpiration = Self.expirationTimestamp(
				data: data,
				fallbackDuration: slackConfig.expiration
			)

			let hasUnreplacedTemplate = allowedTemplateVariants.contains { template in
				statusText.contains(template)
			}

			var profile: ProfileData = .init(
				status_text: statusText, status_emoji: slackConfig.globalCustomEmoji,
				status_expiration: statusExpiration)

			// Apply custom emoji conditions if available
			let conditions = slackConfig.customEmojiConditionList.getConditions()
			if !conditions.isEmpty {
				for condition in conditions {
					if let parsedCondition = EmojiConditionList.EmojiCondition.parseWhenString(
						for: condition.when),
						!condition.emoji.isEmpty
					{
						let matches = self.checkConditionMatch(
							variable: parsedCondition.variable,
							condition: parsedCondition.condition,
							value: parsedCondition.value,
							data: data)

						if matches {
							// Apply custom emoji from the matched condition
							profile.status_emoji = condition.emoji
							break
						}
					}
				}
			}

			if hasUnreplacedTemplate {
				if slackConfig.defaultEmoji.isEmpty {
					return .failure(.ignored)
				}
				profile.status_text = slackConfig.defaultStatusText
				profile.status_emoji = slackConfig.defaultEmoji
				profile.status_expiration = Self.expirationTimestamp(
					duration: Double(
						min(max(1, slackConfig.expiration), maximumSlackStatusDuration)
					)
				)
			}

			let token = slackConfig.apiToken

			if token.isEmpty {
				return .failure(
					.unknown(message: "Missing Slack Api Token", successIntegrations: []))
			}
			guard slackRatelimiter.tryAcquire() else {
				return .failure(.ratelimitExceeded(message: "Slack integration is rate limited"))
			}
			do {
				let headers: HTTPHeaders = [
					"Authorization": "Bearer " + token,
					"Content-Type": "application/json; charset=utf-8",
				]
				let response = try await AF.request(
					URL(string: stackEndpoint)!,
					method: .post,
					parameters: ["profile": profile],
					encoder: JSONParameterEncoder.default,
					headers: headers,
					requestModifier: { request in
						request.timeoutInterval = 10
					}
				)
				.validate()
				.serializingDecodable(SlackAPIResponse.self)
				.value
				guard response.ok else {
					let reason = response.error ?? "unknown_error"
					return .failure(.networkError("Slack API rejected request: \(reason)"))
				}

			} catch {
				NSLog(
					"Slack request failed: \(error.asAFError?.localizedDescription ?? error.localizedDescription)"
				)
				return .failure(.networkError(error.localizedDescription))
			}

			return .success(())
		}
	}

	private static func expirationTimestamp(
		data: ReportModel,
		fallbackDuration: Int
	) -> Int {
		let fallback = min(max(1, fallbackDuration), maximumSlackStatusDuration)
		var duration = Double(fallback)

		if let mediaDuration = data.mediaDuration, mediaDuration.isFinite, mediaDuration > 0 {
			let elapsed = data.mediaElapsedTime.flatMap { value in
				value.isFinite ? max(0, value) : nil
			} ?? 0
			duration = min(
				Double(maximumSlackStatusDuration),
				max(1, mediaDuration - elapsed)
			)
		}

		return expirationTimestamp(duration: duration)
	}

	private static func expirationTimestamp(duration: Double) -> Int {
		let boundedDuration = min(
			Double(maximumSlackStatusDuration),
			max(1, duration.isFinite ? duration : 1)
		)
		let now = Int(Date().timeIntervalSince1970.rounded(.down))
		let seconds = Int(boundedDuration.rounded(.up))
		let result = now.addingReportingOverflow(seconds)
		return result.overflow ? Int.max : result.partialValue
	}

	private func checkConditionMatch(
		variable: EmojiConditionList.EmojiCondition.Variable,
		condition: EmojiConditionList.EmojiCondition.Condition,
		value: String,
		data: ReportModel
	) -> Bool {
		// Get the actual value based on the variable type
		let actualValue: String?

		switch variable {
		case .processName:
			actualValue = data.processName
		case .mediaName:
			actualValue = data.mediaName
		case .artist:
			actualValue = data.artist
		case .processApplicationIdentifier:
			actualValue = data.processInfoRaw?.applicationIdentifier
		case .mediaProcessName:
			actualValue = data.mediaProcessName
		case .mediaProcessApplicationIdentifier:
			actualValue = data.mediaInfoRaw?.applicationIdentifier
		}

		// If the value is nil, we can't match
		guard let actualValue = actualValue else {
			return false
		}

		// Check if the condition is satisfied
		switch condition {
		case .equals:
			return actualValue == value
		case .startsWith:
			return actualValue.hasPrefix(value)
		case .endsWith:
			return actualValue.hasSuffix(value)
		case .contains:
			return actualValue.contains(value)
		}
	}
}
