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
	"{media_name}",
]

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
			guard slackRatelimiter.tryAcquire() else {
				return .failure(.ratelimitExceeded(message: "Slack integration is rate limited"))
			}

			var statusText = slackConfig.statusTextTemplateString
			if let mediaProcessName = data.mediaProcessName {
				statusText = slackConfig.statusTextTemplateString.replacingOccurrences(
					of: "{media_process_name}", with: mediaProcessName)
			}

			if let mediaName = data.mediaName {
				statusText = statusText.replacingOccurrences(of: "{media_name}", with: mediaName)
			}

			if let artistName = data.mediaInfoRaw?.artist {
				statusText = statusText.replacingOccurrences(of: "{artist}", with: artistName)
			}

			if let mediaName = data.mediaName, let artistName = data.mediaInfoRaw?.artist {
				statusText = statusText.replacingOccurrences(
					of: "{media_name_artist}", with: "\(artistName) - \(mediaName)")
			}

			if let processName = data.processName {
				statusText = statusText.replacingOccurrences(
					of: "{process_name}", with: processName)
			}
			let statusExpiration = {
				let currentDate = Date()
				let duration = Int(data.mediaDuration ?? Double(slackConfig.expiration))
				return Calendar.current.date(
					byAdding: .second, value: duration, to: currentDate)!
					.timeIntervalSince1970
			}()

			let hasUnreplacedTemplate = allowedTemplateVariants.contains { template in
				statusText.contains(template)
			}

			var profile: ProfileData = .init(
				status_text: statusText, status_emoji: slackConfig.globalCustomEmoji,
				status_expiration: Int(statusExpiration))

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
				profile.status_expiration = 3600
			}

			let token = slackConfig.apiToken

			if token.isEmpty {
				return .failure(
					.unknown(message: "Missing Slack Api Token", successIntegrations: []))
			}
			do {
				let headers: HTTPHeaders = [
					"Authorization": "Bearer " + token,
					"Content-Type": "application/json; charset=utf-8",
				]
				_ = try await AF.request(
					URL(string: stackEndpoint)!,
					method: .post,
					parameters: ["profile": profile],
					encoder: JSONParameterEncoder.default,
					headers: headers
				)
				.validate()
				.serializingData()
				.value

			} catch {
				NSLog(
					"Slack request failed: \(error.asAFError?.localizedDescription ?? error.localizedDescription)"
				)
				return .failure(.networkError(error.localizedDescription))
			}

			return .success(())
		}
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
			actualValue = data.mediaInfoRaw?.artist
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
