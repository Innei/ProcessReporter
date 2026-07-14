//
//  Reporter+Slack.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/16.
//

import Alamofire
import Foundation

private let stackEndpoint = "https://slack.com/api/users.profile.set"

private struct ProfileData: Codable, Sendable {
	var status_text: String
	var status_emoji: String
	var status_expiration: Int
}

private struct SlackAPIResponse: Decodable, Sendable {
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

@MainActor
private final class SlackDeliveryQueue {
	private var tail: Task<Void, Never>?

	func enqueue(
		profile: ProfileData,
		token: String,
		requiresReportingAllowed: Bool
	) -> Task<Result<Void, ReporterError>, Never> {
		let previous = tail
		let operation = Task { @MainActor in
			await previous?.value
			return await Self.deliver(
				profile: profile,
				token: token,
				requiresReportingAllowed: requiresReportingAllowed
			)
		}
		tail = Task { @MainActor in
			_ = await operation.value
		}
		return operation
	}

	private static func deliver(
		profile: ProfileData,
		token: String,
		requiresReportingAllowed: Bool
	) async -> Result<Void, ReporterError> {
		guard !PreferencesDataModel.integrationCredentialStoreUnavailable else {
			return .failure(.ignored)
		}
		guard !requiresReportingAllowed || PreferencesDataModel.reportingAllowed else {
			return .failure(.ignored)
		}
		// Every queued operation waits for a limiter slot. In particular, a publish
		// queued immediately after a clear must not fail simply because the clear
		// consumed the previous slot.
		var remainingWaitAttempts = 12
		while !slackRatelimiter.tryAcquire() {
			guard !requiresReportingAllowed || PreferencesDataModel.reportingAllowed else {
				return .failure(.ignored)
			}
			guard remainingWaitAttempts > 0 else {
				return .failure(
					.ratelimitExceeded(message: "Slack integration is rate limited")
				)
			}
			remainingWaitAttempts -= 1
			do {
				try await Task.sleep(nanoseconds: 1_000_000_000)
			} catch {
				return .failure(.cancelled(message: "Slack delivery was cancelled"))
			}
		}
		guard !PreferencesDataModel.integrationCredentialStoreUnavailable else {
			return .failure(.ignored)
		}
		guard !requiresReportingAllowed || PreferencesDataModel.reportingAllowed else {
			return .failure(.ignored)
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
			return .success(())
		} catch {
			NSLog(
				"Slack request failed: \(error.asAFError?.localizedDescription ?? error.localizedDescription)"
			)
			return .failure(.networkError(error.localizedDescription))
		}
	}
}

class SlackReporterExtension: ReporterExtension {
	var name: String = "Slack"
	private let deliveryQueue = SlackDeliveryQueue()
	private var potentialStatusGenerationByToken: [String: UInt64] = [:]
	private var pendingClearGenerationByToken: [String: UInt64] = [:]
	private var retryClearGenerationByToken: [String: UInt64] = [:]
	private var statusGeneration: UInt64 = 0
	private var observedConfigurationToken: String?

	var isEnabled: Bool {
		return PreferencesDataModel.shared.slackIntegration.value.isEnabled
			&& !PreferencesDataModel.integrationCredentialStoreUnavailable
	}

	func createReporterOptions() -> ReporterOptions {
		return ReporterOptions { data in
			guard !PreferencesDataModel.integrationCredentialStoreUnavailable else {
				return .failure(.ignored)
			}
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

			// Record the token before enqueueing. Because both operations run on the
			// main actor without an intervening suspension, a later sleep/disable clear
			// is guaranteed to be queued behind this possibly successful publish.
			self.markPotentialStatus(for: token, isPublish: true)
			return await self.deliveryQueue.enqueue(
				profile: profile,
				token: token,
				requiresReportingAllowed: true
			).value
		}
	}

	func register(to reporter: Reporter) {
		guard !PreferencesDataModel.integrationCredentialStoreUnavailable else {
			reporter.unregister(name: name)
			return
		}
		let token = PreferencesDataModel.shared.slackIntegration.value.apiToken
		// A token that was previously active can still own a remote status after a
		// configuration change. Clear every older token before publishing with the
		// newly configured token.
		enqueuePendingClears(excluding: token)
		observeConfigurationToken(token)
		reporter.register(name: name, options: createReporterOptions())
	}

	func unregister(from reporter: Reporter) {
		reporter.unregister(name: name)
		guard !PreferencesDataModel.integrationCredentialStoreUnavailable else { return }
		observeConfigurationToken(
			PreferencesDataModel.shared.slackIntegration.value.apiToken
		)
		clearReportedState()
	}

	func clearReportedState() {
		guard !PreferencesDataModel.integrationCredentialStoreUnavailable else { return }
		enqueuePendingClears()
	}

	private func markPotentialStatusIfNeeded(for token: String) {
		guard !token.isEmpty, potentialStatusGenerationByToken[token] == nil else { return }
		markPotentialStatus(for: token, isPublish: false)
	}

	private func observeConfigurationToken(_ token: String) {
		guard observedConfigurationToken != token else { return }
		observedConfigurationToken = token
		// On first observation, the token may own a status left by an earlier app
		// run. On a later transition it becomes the token whose future publishes
		// must be tracked, without re-seeding it after a confirmed clear.
		markPotentialStatusIfNeeded(for: token)
	}

	private func markPotentialStatus(for token: String, isPublish: Bool) {
		guard !token.isEmpty else { return }
		if !isPublish, potentialStatusGenerationByToken[token] != nil {
			return
		}
		statusGeneration &+= 1
		potentialStatusGenerationByToken[token] = statusGeneration
	}

	private func enqueuePendingClears(excluding retainedToken: String? = nil) {
		guard !PreferencesDataModel.integrationCredentialStoreUnavailable else { return }
		let candidates = potentialStatusGenerationByToken
			.filter { token, _ in
				token != retainedToken
			}
			.sorted { lhs, rhs in lhs.value < rhs.value }

		for (token, generation) in candidates {
			if pendingClearGenerationByToken[token] == generation {
				// A later clear request is already covered by this operation. Remember
				// that request so a failed operation receives one follow-up attempt.
				retryClearGenerationByToken[token] = generation
				continue
			}
			enqueueClear(for: token, generation: generation)
		}
	}

	private func enqueueClear(for token: String, generation: UInt64) {
		guard !PreferencesDataModel.integrationCredentialStoreUnavailable else { return }
		pendingClearGenerationByToken[token] = generation
		let operation = deliveryQueue.enqueue(
			profile: ProfileData(
				status_text: "",
				status_emoji: "",
				status_expiration: 0
			),
			token: token,
			requiresReportingAllowed: false
		)
		Task { @MainActor [weak self] in
			let result = await operation.value
			guard let self else { return }
			let isLatestPendingClear =
				self.pendingClearGenerationByToken[token] == generation
			if isLatestPendingClear {
				self.pendingClearGenerationByToken.removeValue(forKey: token)
			}
			let shouldRetry = self.retryClearGenerationByToken[token] == generation
			if shouldRetry {
				self.retryClearGenerationByToken.removeValue(forKey: token)
			}

			if case .success = result {
				// Preserve the token when another publish was enqueued after this
				// clear. Its newer generation may still own a remote status.
				if self.potentialStatusGenerationByToken[token] == generation {
					self.potentialStatusGenerationByToken.removeValue(forKey: token)
				}
				return
			}

			NSLog("Slack status clear was deferred: \(String(describing: result))")
			guard isLatestPendingClear,
				shouldRetry,
				self.potentialStatusGenerationByToken[token] == generation
			else { return }
			self.enqueueClear(for: token, generation: generation)
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
