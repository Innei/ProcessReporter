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

	var deliveryOutputSummary: SyncOutputSummary {
		SyncOutputSummary(
			title: status_text.isEmpty ? nil : status_text,
			subtitle: status_emoji.isEmpty ? nil : status_emoji,
			detail: status_expiration > 0 ? "Expiration: \(status_expiration)" : nil,
			activityKind: "status"
		)
	}
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

private final class SlackNetworkObservation: @unchecked Sendable {
	let token: NSObjectProtocol

	init(token: NSObjectProtocol) {
		self.token = token
	}

	deinit {
		NotificationCenter.default.removeObserver(token)
	}
}

@MainActor
private final class SlackDeliveryQueue {
	private struct QueuedOperation {
		let requiresReportingAllowed: Bool
		let task: Task<Result<Void, ReporterError>, Never>
	}

	private var tail: Task<Void, Never>?
	private var operations: [UUID: QueuedOperation] = [:]

	func enqueue(
		profile: ProfileData,
		token: String,
		requiresReportingAllowed: Bool
	) -> Task<Result<Void, ReporterError>, Never> {
		let previous = tail
		let operationID = UUID()
		let operation = Task<Result<Void, ReporterError>, Never> { @MainActor [weak self] in
			await previous?.value
			guard !Task.isCancelled else {
				self?.operations.removeValue(forKey: operationID)
				return .failure(.cancelled(message: "Slack delivery was cancelled"))
			}
			let result = await Self.deliver(
				profile: profile,
				token: token,
				requiresReportingAllowed: requiresReportingAllowed
			)
			self?.operations.removeValue(forKey: operationID)
			return result
		}
		operations[operationID] = QueuedOperation(
			requiresReportingAllowed: requiresReportingAllowed,
			task: operation
		)
		tail = Task { @MainActor in
			_ = await operation.value
		}
		return operation
	}

	func cancelReportingOperations() {
		for operation in operations.values where operation.requiresReportingAllowed {
			operation.task.cancel()
		}
	}

	func cancelAllOperations() {
		for operation in operations.values {
			operation.task.cancel()
		}
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
		// User-visible publishes remain locally rate limited. Remote cleanup is a
		// lifecycle safety operation and must be able to run within the bounded app
		// termination window instead of waiting behind the publish interval.
		if requiresReportingAllowed {
			// Do not let Slack's local rate limit hold the global Presence batch for
			// an entire reporting interval. A later event or heartbeat retries the
			// latest state.
			var remainingWaitAttempts = 1
			while !slackRatelimiter.tryAcquire() {
				guard PreferencesDataModel.reportingAllowed else {
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
		}
		guard !PreferencesDataModel.integrationCredentialStoreUnavailable else {
			return .failure(.ignored)
		}
		guard !requiresReportingAllowed || PreferencesDataModel.reportingAllowed else {
			return .failure(.ignored)
		}

		do {
			try Task.checkCancellation()
			let headers: HTTPHeaders = [
				"Authorization": "Bearer " + token,
				"Content-Type": "application/json; charset=utf-8",
			]
			let request = AF.request(
				URL(string: stackEndpoint)!,
				method: .post,
				parameters: ["profile": profile],
				encoder: JSONParameterEncoder.default,
				headers: headers,
				requestModifier: { request in
					request.timeoutInterval = requiresReportingAllowed ? 2 : 3
				}
			).validate()
			let response = try await withTaskCancellationHandler(
				operation: {
					try await request
						.serializingDecodable(SlackAPIResponse.self)
						.value
				},
				onCancel: {
					request.cancel()
				}
			)
			guard response.ok else {
				let reason = response.error ?? "unknown_error"
				return .failure(.networkError("Slack API rejected request: \(reason)"))
			}
			return .success(())
		} catch is CancellationError {
			return .failure(.cancelled(message: "Slack delivery was cancelled"))
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
	private var statusGeneration: UInt64 = 0
	private var observedConfigurationToken: String?
	private let maximumClearRetryCount = 3
	private var networkAvailabilityObservation: SlackNetworkObservation?
	private var cleanupDeadlineExpired = false

	init() {
		let token = NotificationCenter.default.addObserver(
			forName: .processReporterNetworkAvailabilityDidChange,
			object: nil,
			queue: .main
		) { [weak self] notification in
			guard notification.userInfo?[NetworkAvailabilityNotificationKey.isAvailable]
				as? Bool == true
			else { return }
			Task { @MainActor [weak self] in
				self?.enqueuePendingClears()
			}
		}
		networkAvailabilityObservation = SlackNetworkObservation(token: token)
		// Seed cleanup ownership even when sharing is paused and this extension is
		// never registered during the current process. A later token deletion must
		// still clear a status left by the previous app run.
		observeConfigurationToken(
			PreferencesDataModel.shared.slackIntegration.value.apiToken
		)
	}

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
					),
					referenceDate: data.timeStamp
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
			let deliveryResult = await self.deliveryQueue.enqueue(
				profile: profile,
				token: token,
				requiresReportingAllowed: true
			).value
			switch deliveryResult {
			case .success:
				return .success(
					ReporterDeliveryReceipt(outputSummary: profile.deliveryOutputSummary)
				)
			case .failure(let error):
				return .failure(error)
			}
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
		deliveryQueue.cancelReportingOperations()
		guard !PreferencesDataModel.integrationCredentialStoreUnavailable else { return }
		enqueuePendingClears()
	}

	func waitForPendingCleanup(until deadline: ContinuousClock.Instant) async {
		let clock = ContinuousClock()
		while !pendingClearGenerationByToken.isEmpty, clock.now < deadline {
			guard !Task.isCancelled else { break }
			do {
				try await Task.sleep(for: .milliseconds(100))
			} catch {
				break
			}
		}
		guard !pendingClearGenerationByToken.isEmpty else { return }
		cleanupDeadlineExpired = true
		deliveryQueue.cancelAllOperations()
		pendingClearGenerationByToken.removeAll()
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
		guard !cleanupDeadlineExpired,
			!PreferencesDataModel.integrationCredentialStoreUnavailable
		else { return }
		let candidates = potentialStatusGenerationByToken
			.filter { token, _ in
				token != retainedToken
			}
			.sorted { lhs, rhs in lhs.value < rhs.value }

		for (token, generation) in candidates {
			if pendingClearGenerationByToken[token] == generation {
				continue
			}
			enqueueClear(for: token, generation: generation)
		}
	}

	private func enqueueClear(
		for token: String,
		generation: UInt64,
		retryCount: Int = 0
	) {
		guard !cleanupDeadlineExpired,
			!PreferencesDataModel.integrationCredentialStoreUnavailable
		else { return }
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
			guard !self.cleanupDeadlineExpired else {
				if isLatestPendingClear {
					self.pendingClearGenerationByToken.removeValue(forKey: token)
				}
				return
			}
			if case .success = result {
				if isLatestPendingClear {
					self.pendingClearGenerationByToken.removeValue(forKey: token)
				}
				// Preserve the token when another publish was enqueued after this
				// clear. Its newer generation may still own a remote status.
				if self.potentialStatusGenerationByToken[token] == generation {
					self.potentialStatusGenerationByToken.removeValue(forKey: token)
				}
				return
			}

			NSLog("Slack status clear was deferred: \(String(describing: result))")
			guard isLatestPendingClear,
				self.potentialStatusGenerationByToken[token] == generation
			else {
				if isLatestPendingClear {
					self.pendingClearGenerationByToken.removeValue(forKey: token)
				}
				return
			}

			guard retryCount < self.maximumClearRetryCount else {
				// Keep the potential status generation. A later network recovery or
				// lifecycle transition can enqueue another bounded retry sequence.
				self.pendingClearGenerationByToken.removeValue(forKey: token)
				return
			}
			let retryDelay = Duration.seconds(1 << retryCount)
			do {
				try await Task.sleep(for: retryDelay)
			} catch {
				self.pendingClearGenerationByToken.removeValue(forKey: token)
				return
			}
			guard self.pendingClearGenerationByToken[token] == generation,
				self.potentialStatusGenerationByToken[token] == generation
			else {
				if self.pendingClearGenerationByToken[token] == generation {
					self.pendingClearGenerationByToken.removeValue(forKey: token)
				}
				return
			}
			self.enqueueClear(
				for: token,
				generation: generation,
				retryCount: retryCount + 1
			)
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

		return expirationTimestamp(duration: duration, referenceDate: data.timeStamp)
	}

	private static func expirationTimestamp(
		duration: Double,
		referenceDate: Date = .now
	) -> Int {
		let boundedDuration = min(
			Double(maximumSlackStatusDuration),
			max(1, duration.isFinite ? duration : 1)
		)
		let now = Int(referenceDate.timeIntervalSince1970.rounded(.down))
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
