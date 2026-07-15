import Cocoa
import RxCocoa
@preconcurrency import RxSwift

enum ReporterError: Error, Sendable {
	case networkError(String)
	case cancelled(message: String)
	case unknown(message: String, successIntegrations: [String])
	case ratelimitExceeded(message: String)
	case ignored
	case databaseError(String)
}

extension ReporterError {
	var presenceUserFacingMessage: String {
		switch self {
		case .networkError:
			return "The destination could not be reached."
		case .cancelled(let message):
			return message
		case .unknown:
			return "The destination returned an unexpected response."
		case .ratelimitExceeded:
			return "The destination rate limit was reached."
		case .ignored:
			return "This Presence did not require an update."
		case .databaseError:
			return "Local Presence data could not be updated."
		}
	}

	var persistenceCode: String {
		switch self {
		case .networkError:
			return "network_error"
		case .cancelled:
			return "cancelled"
		case .unknown:
			return "unexpected_response"
		case .ratelimitExceeded:
			return "rate_limited"
		case .ignored:
			return "not_applicable"
		case .databaseError:
			return "local_database"
		}
	}

	var persistenceMessage: String {
		switch self {
		case .networkError:
			return "The destination could not be reached."
		case .cancelled:
			return "The destination delivery was cancelled."
		case .unknown:
			return "The destination returned an unexpected response."
		case .ratelimitExceeded:
			return "The destination rate limit was reached."
		case .ignored:
			return "This Presence did not require an update."
		case .databaseError:
			return "The destination could not update its local state."
		}
	}
}

enum SendError: Error {
	case failure([String])
	case persistenceFailure(message: String, successfulIntegrations: [String])
}

struct ReporterDeliveryReceipt: Sendable {
	let outputSummary: SyncOutputSummary
}

typealias ReporterDeliveryResult = Result<ReporterDeliveryReceipt, ReporterError>

struct ReporterOptions {
	let priority: Int
	let assetCapability: PresenceAssetCapability
	let onSend: @MainActor @Sendable (
		_ data: ReportModel,
		_ assetResolution: PresenceAssetResolution
	) async -> ReporterDeliveryResult

	init(
		priority: Int = 100,
		assetCapability: PresenceAssetCapability = .unsupported,
		onSend: @escaping @MainActor @Sendable (
			_ data: ReportModel
		) async -> ReporterDeliveryResult
	) {
		self.priority = priority
		self.assetCapability = assetCapability
		self.onSend = { data, _ in await onSend(data) }
	}

	init(
		priority: Int = 100,
		assetCapability: PresenceAssetCapability,
		onSendWithAsset: @escaping @MainActor @Sendable (
			_ data: ReportModel,
			_ assetResolution: PresenceAssetResolution
		) async -> ReporterDeliveryResult
	) {
		self.priority = priority
		self.assetCapability = assetCapability
		self.onSend = onSendWithAsset
	}
}

@MainActor
class Reporter {
	private struct PendingPresence {
		let report: ReportModel
		let trigger: SyncEventTrigger
	}

	private struct DestinationDeliveryExecution: Sendable {
		let name: String
		let destinationID: PresenceDestinationID?
		let storedDestinationID: String
		let storedDestinationName: String
		let startedAt: Date
		let completedAt: Date
		let assetResolution: PresenceAssetResolution
		let result: ReporterDeliveryResult
	}

	private var mapping = [String: ReporterOptions]()
	private var statusItemManager = ReporterStatusItemManager()
	private let assetHostingService: any AssetHostingService

	// Add reporter extensions array
	private var reporterExtensions: [ReporterExtension] = []

	private var cachedFilteredProcessBundleIDs = Set<String>()
	private var cachedFilteredMediaBundleIDs = Set<String>()
	private var cachedFilteredMediaAppNames = Set<String>()
	private var privacyConfigurationCache = PresencePrivacyConfiguration.newInstallation
	private let disposeBag = DisposeBag()
	private var isMonitoring = false
	private var isProcessMonitoring = false
	private var isMediaMonitoring = false
	private var preparationGeneration = 0
	private var hasPendingNetworkRefresh = false
	private var pendingPresence: PendingPresence?
	private var sendGeneration = 0
	private var sendTask: Task<Void, Never>?
	private var activeDestinationTasks = [
		UUID: Task<DestinationDeliveryExecution?, Never>
	]()
	private var activeAssetResolutionTask: Task<PresenceAssetResolution, Never>?
	private var activeSendTaskCount = 0
	private var isSuspendedForSleep = false

	// Mapping cache
	private var mappingCache: [PreferencesDataModel.Mapping] = []

	// Clear all caches for memory cleanup
	public func clearCaches() {
		refreshFilterCaches()
		mappingCache = PreferencesDataModel.mappingList.value.getList()
	}

	// Handle wake from sleep - reinitialize components if needed
	public func handleWakeFromSleep() {
		print("[Reporter] Handling wake from sleep - reinitializing components...")

		// Clear caches that might be stale after sleep
		clearCaches()

		guard isSuspendedForSleep else { return }
		isSuspendedForSleep = false
		guard PreferencesDataModel.shared.reportingAllowed else { return }

		// Recreate each source from the current preferences. Waiting is owned by
		// AppDelegate, so no pre-sleep callback or missed Timer event can leak into
		// the new monitoring session.
		monitor()
		if !PreferencesDataModel.shared.enabledTypes.value.types.isEmpty {
			setupTimer()
			prepareSend(
				windowInfo: ApplicationMonitor.shared.getFocusedWindowInfo(),
				resolveMissingMedia: false,
				trigger: .settingsChanged
			)
		}

		print("[Reporter] Wake from sleep handling completed")
	}

	public func handleSleep() {
		guard !isSuspendedForSleep else { return }
		isSuspendedForSleep = true
		isMonitoring = false
		isProcessMonitoring = false
		isMediaMonitoring = false
		ApplicationMonitor.shared.stopWindowFocusMonitoring()
		ApplicationMonitor.shared.onWindowFocusChanged = nil
		MediaInfoManager.stopMonitoringPlaybackChanges()
		disposeTimer()
		cancelPendingReportWork()
		updateExtensions()
	}

	public func shutdown(pendingCleanupTimeout: Duration = .seconds(5)) async {
		// handleSleep cancels all publish work and asks every extension to clear its
		// remote state. Invoke clear again so termination while already suspended
		// still retries cleanup that may have been deferred while offline.
		handleSleep()
		clearReportedState()

		let clock = ContinuousClock()
		let deadline = clock.now.advanced(by: pendingCleanupTimeout)
		_ = await waitForPendingReportWork(until: deadline)
		for reporterExtension in reporterExtensions {
			await reporterExtension.waitForPendingCleanup(until: deadline)
		}
	}

	/// Waits only for local delivery and History work to become quiescent.
	/// Remote destination cleanup has a separate lifecycle so database ownership
	/// can be released as soon as no cancelled send can still roll back a row.
	public func waitForPendingReportWork(
		until deadline: ContinuousClock.Instant
	) async -> Bool {
		let clock = ContinuousClock()
		while activeSendTaskCount > 0, clock.now < deadline {
			guard !Task.isCancelled else { break }
			do {
				try await Task.sleep(for: .milliseconds(25))
			} catch {
				break
			}
		}
		return activeSendTaskCount == 0
	}

	// Register a reporter extension
	public func registerExtension(_ extension: ReporterExtension) {
		reporterExtensions.append(`extension`)
		if shouldActivateExtensions, `extension`.isEnabled {
			`extension`.register(to: self)
		}
	}

	// Update the status of all extensions
	public func updateExtensions() {
		for ext in reporterExtensions {
			if shouldActivateExtensions, ext.isEnabled {
				ext.register(to: self)
			} else {
				ext.unregister(from: self)
			}
		}
	}

	private var shouldActivateExtensions: Bool {
		isMonitoring && !isSuspendedForSleep
			&& PreferencesDataModel.shared.reportingAllowed
			&& !PreferencesDataModel.shared.enabledTypes.value.types.isEmpty
	}

	private func clearReportedState() {
		for ext in reporterExtensions {
			ext.clearReportedState()
		}
	}

	public func register(name: String, options: ReporterOptions) {
		mapping[name] = options
	}

	public func unregister(name: String) {
		mapping.removeValue(forKey: name)
	}

	private func send(
		data: ReportModel,
		generation: Int,
		trigger: SyncEventTrigger
	) async -> Result<[String], SendError> {
		var successNames = [String]()
		var failureNames = [String]()
		var skippedNames = [String]()
		var deliveryResults = [PresenceDestinationDeliveryResult]()
		var storedDeliveryResults = [SyncDeliveryResult]()
		guard isDeliveryCurrent(generation) else { return .success([]) }

		// Snapshot the registry before awaiting. Every delivery task remains
		// MainActor-isolated, so the SwiftData-backed ReportModel is never transferred
		// across executors. Starting the tasks together prevents a slow or failing
		// destination from delaying the initial delivery to every other destination.
		let registeredReporters = mapping.sorted { lhs, rhs in
			if lhs.value.priority == rhs.value.priority {
				return lhs.key < rhs.key
			}
			return lhs.value.priority < rhs.value.priority
		}
		guard !registeredReporters.isEmpty else {
			statusItemManager.toggleStatusItemIcon(.ready)
			return .success([])
		}
		let destinationIDs = registeredReporters.compactMap {
			PresenceDestinationID(reporterName: $0.key)
		}
		let deliveryID = statusItemManager.beginDelivery(to: destinationIDs)

		let assetCapability: PresenceAssetCapability
		if registeredReporters.contains(where: { $0.value.assetCapability == .requiredPublicURL }) {
			assetCapability = .requiredPublicURL
		} else if registeredReporters.contains(where: {
			$0.value.assetCapability == .optionalPublicURL
		}) {
			assetCapability = .optionalPublicURL
		} else {
			assetCapability = .unsupported
		}
		var assetResolution = PresenceAssetResolution.notRequested
		var deliveryWasCancelled = false
		let sharedAssetTask: Task<PresenceAssetResolution, Never>?
		if assetCapability == .unsupported {
			sharedAssetTask = nil
		} else {
			let task = Task { @MainActor [assetHostingService] in
				await assetHostingService.resolveApplicationIcon(
					for: data,
					capability: assetCapability
				)
			}
			sharedAssetTask = task
			activeAssetResolutionTask = task
		}

		let deliveryTasks = registeredReporters.map { name, options in
			let taskID = UUID()
			let task = Task<DestinationDeliveryExecution?, Never> {
				@MainActor [weak self] in
				guard let self, self.isDeliveryCurrent(generation) else { return nil }

				let destinationAssetResolution: PresenceAssetResolution
				if options.assetCapability == .unsupported {
					destinationAssetResolution = .notRequested
				} else if let sharedAssetTask {
					destinationAssetResolution = await sharedAssetTask.value
				} else {
					destinationAssetResolution = .notRequested
				}
				guard self.isDeliveryCurrent(generation) else { return nil }

				let startedAt = Date()
				let result = await options.onSend(data, destinationAssetResolution)
				let completedAt = Date()
				guard self.isDeliveryCurrent(generation) else { return nil }

				let destinationID = PresenceDestinationID(reporterName: name)
				return DestinationDeliveryExecution(
					name: name,
					destinationID: destinationID,
					storedDestinationID: destinationID?.rawValue
						?? name.lowercased().replacingOccurrences(of: " ", with: "-"),
					storedDestinationName: destinationID?.displayName ?? name,
					startedAt: startedAt,
					completedAt: completedAt,
					assetResolution: destinationAssetResolution,
					result: result
				)
			}
			activeDestinationTasks[taskID] = task
			return (taskID, task)
		}

		for (taskID, task) in deliveryTasks {
			let execution = await task.value
			activeDestinationTasks.removeValue(forKey: taskID)
			guard let execution else {
				deliveryWasCancelled = true
				continue
			}
			if execution.assetResolution != .notRequested {
				assetResolution = execution.assetResolution
			}
			let name = execution.name
			let destinationID = execution.destinationID
			let storedDestinationID = execution.storedDestinationID
			let storedDestinationName = execution.storedDestinationName
			let startedAt = execution.startedAt
			let completedAt = execution.completedAt
			let result = execution.result
			if case let .success(receipt) = result {
				successNames.append(name)
				storedDeliveryResults.append(
					SyncDeliveryResult(
						destinationID: storedDestinationID,
						destinationDisplayName: storedDestinationName,
						status: .succeeded,
						startedAt: startedAt,
						finishedAt: completedAt,
						outputSummary: receipt.outputSummary,
						errorCode: nil,
						message: nil
					)
				)
				if let destinationID {
					deliveryResults.append(
						.init(id: destinationID, state: .succeeded(completedAt))
					)
				}
				continue
			}
			if case let .failure(error) = result {
				PresenceDiagnosticsState.shared.record(
					code: error.persistenceCode,
					message: error.persistenceMessage
				)
				let storedStatus: SyncDeliveryStatus
				if case .ignored = error {
					storedStatus = .skipped
				} else {
					storedStatus = .failed
				}
				storedDeliveryResults.append(
					SyncDeliveryResult(
						destinationID: storedDestinationID,
						destinationDisplayName: storedDestinationName,
						status: storedStatus,
						startedAt: startedAt,
						finishedAt: completedAt,
						outputSummary: nil,
						errorCode: error.persistenceCode,
						message: error.persistenceMessage
					)
				)
				switch error {
				case .ignored:
					skippedNames.append(name)
					if let destinationID {
						deliveryResults.append(
							.init(
								id: destinationID,
								state: .skipped(
									message: error.presenceUserFacingMessage,
									date: completedAt
								)
							)
						)
					}
				case .databaseError(let message):
					failureNames.append(name)
					NSLog("\(name) database error: \(message)")
					if let destinationID {
						deliveryResults.append(
							.init(
								id: destinationID,
								state: .failed(
									message: error.presenceUserFacingMessage,
									date: completedAt
								)
							)
						)
					}
				default:
					failureNames.append(name)
					NSLog("\(name) failed: \(error)")
					if let destinationID {
						deliveryResults.append(
							.init(
								id: destinationID,
								state: .failed(
									message: error.presenceUserFacingMessage,
									date: completedAt
								)
							)
						)
					}
				}
			}
		}
		activeAssetResolutionTask = nil
		if deliveryWasCancelled {
			let completedDestinationIDs = Set(deliveryResults.map(\.id))
			let cancellationDate = Date()
			for destinationID in destinationIDs where !completedDestinationIDs.contains(destinationID) {
				deliveryResults.append(
					.init(
						id: destinationID,
						state: .skipped(
							message: "Delivery was cancelled because Presence settings changed.",
							date: cancellationDate
						)
					)
				)
			}

			// A stale generation must never persist its snapshot after a privacy,
			// source, destination, pause, or sleep transition.
			statusItemManager.completeDelivery(
				deliveryID: deliveryID,
				results: deliveryResults,
				assetResolution: assetResolution
			)
			return failureNames.isEmpty
				? .success(successNames)
				: .failure(.failure(failureNames))
		}

		// A skipped integration is not a successful delivery. The activity itself
		// is still persisted below because History is a local activity log, not only
		// a delivery log.
		if !skippedNames.isEmpty {
			NSLog("Report skipped by integrations: \(skippedNames.joined(separator: ", "))")
		}
		guard isDeliveryCurrent(generation) else {
			statusItemManager.completeDelivery(
				deliveryID: deliveryID,
				results: deliveryResults,
				assetResolution: assetResolution
			)
			return .success(successNames)
		}

		// Persist only the already-sanitized scalar snapshot and normalized audit
		// metadata. Provider payloads, responses, endpoints, and credentials never
		// cross this boundary.
		let storedPayload = StoredSyncEventPayload(
			trigger: trigger,
			assetResult: storedAssetResult(for: assetResolution),
			deliveryResults: storedDeliveryResults
		)
		let reportValue = ReportValue(
			id: data.id,
			processName: data.processName,
			windowTitle: data.windowTitle,
			timeStamp: data.timeStamp,
			artist: data.artist,
			mediaName: data.mediaName,
			mediaProcessName: data.mediaProcessName,
			mediaDuration: data.mediaDuration,
			mediaElapsedTime: data.mediaElapsedTime,
			integrations: successNames,
			decodedSyncPayload: .modern(storedPayload)
		)
		// The durable suppression marker is installed synchronously before the
		// database write. History cannot observe this row until the generation
		// gate below explicitly publishes it.
		DataStore.shared.stageReportForPublication(id: reportValue.id)
		do {
			try await DataStore.shared.saveStagedReport(reportValue)
		} catch {
			let rollbackError = await rollbackStagedReport(id: reportValue.id)
			if !isDeliveryCurrent(generation) {
				if let rollbackError {
					return staleHistoryRollbackFailure(
						rollbackError,
						deliveryID: deliveryID,
						deliveryResults: deliveryResults,
						assetResolution: assetResolution,
						successfulIntegrations: successNames
					)
				}
				statusItemManager.completeDelivery(
					deliveryID: deliveryID,
					results: deliveryResults,
					assetResolution: assetResolution
				)
				return .success(successNames)
			}
			if let rollbackError {
				NSLog(
					"Failed to remove an ambiguously saved report history row: \(rollbackError.localizedDescription)"
				)
			}
			NSLog("Failed to persist report history: \(error.localizedDescription)")
			PresenceDiagnosticsState.shared.record(
				code: "history_persistence_failed",
				message: "The local Sync Event could not be saved."
			)
			statusItemManager.completeDelivery(
				deliveryID: deliveryID,
				results: deliveryResults,
				assetResolution: assetResolution,
				persistenceError: error.localizedDescription
			)
			if PreferencesDataModel.shared.reportingAllowed {
				statusItemManager.toggleStatusItemIcon(.error)
			}
			return .failure(
				.persistenceFailure(
					message: error.localizedDescription,
					successfulIntegrations: successNames
				)
			)
		}
		guard publishStagedReportIfCurrent(id: reportValue.id, generation: generation) else {
			if let rollbackError = await rollbackStagedReport(id: reportValue.id) {
				return staleHistoryRollbackFailure(
					rollbackError,
					deliveryID: deliveryID,
					deliveryResults: deliveryResults,
					assetResolution: assetResolution,
					successfulIntegrations: successNames
				)
			}
			statusItemManager.completeDelivery(
				deliveryID: deliveryID,
				results: deliveryResults,
				assetResolution: assetResolution
			)
			return .success(successNames)
		}

		let isAllFailed = successNames.isEmpty && !failureNames.isEmpty
		statusItemManager.completeDelivery(
			deliveryID: deliveryID,
			results: deliveryResults,
			assetResolution: assetResolution
		)

		if failureNames.isEmpty {
			if PreferencesDataModel.shared.reportingAllowed {
				statusItemManager.toggleStatusItemIcon(
					assetResolution.isFailure ? .partialError : .ready
				)
			}
			return .success(successNames)
		} else {
			if PreferencesDataModel.shared.reportingAllowed {
				statusItemManager.toggleStatusItemIcon(isAllFailed ? .error : .partialError)
			}
			return .failure(.failure(failureNames))
		}
	}

	/// Linearization point for History publication.
	///
	/// Reporter and every generation invalidation are MainActor-isolated. The
	/// generation check and DataStore's synchronous suppression removal therefore
	/// execute as one uninterrupted main-actor operation.
	private func publishStagedReportIfCurrent(id: UUID, generation: Int) -> Bool {
		guard isDeliveryCurrent(generation) else { return false }
		DataStore.shared.publishStagedReport(id: id)
		return true
	}

	private func rollbackStagedReport(id: UUID) async -> Error? {
		do {
			try await DataStore.shared.quarantineAndDeleteReport(id: id)
			return nil
		} catch {
			// DataStore deliberately retains the durable marker on failure. History
			// remains fail-closed and initialization retries physical deletion.
			return error
		}
	}

	private func staleHistoryRollbackFailure(
		_ error: Error,
		deliveryID: UUID,
		deliveryResults: [PresenceDestinationDeliveryResult],
		assetResolution: PresenceAssetResolution,
		successfulIntegrations: [String]
	) -> Result<[String], SendError> {
		let rollbackMessage = "A privacy-stale Sync Event could not be removed."
		NSLog("Failed to roll back stale report history: \(error.localizedDescription)")
		PresenceDiagnosticsState.shared.record(
			code: "history_privacy_rollback_failed",
			message: rollbackMessage
		)
		statusItemManager.completeDelivery(
			deliveryID: deliveryID,
			results: deliveryResults,
			assetResolution: assetResolution,
			persistenceError: rollbackMessage
		)
		if PreferencesDataModel.shared.reportingAllowed {
			statusItemManager.toggleStatusItemIcon(.error)
		}
		return .failure(
			.persistenceFailure(
				message: rollbackMessage,
				successfulIntegrations: successfulIntegrations
			)
		)
	}

	private func isDeliveryCurrent(_ generation: Int) -> Bool {
		generation == sendGeneration
			&& !Task.isCancelled
			&& PreferencesDataModel.shared.reportingAllowed
	}

	private func storedAssetResult(
		for resolution: PresenceAssetResolution
	) -> SyncAssetResult {
		switch resolution {
		case .notRequested:
			return SyncAssetResult(
				status: .notRequested,
				usedFallback: false,
				errorCode: nil,
				message: nil
			)
		case .notConfigured:
			return SyncAssetResult(
				status: .notConfigured,
				usedFallback: false,
				errorCode: nil,
				message: "Application Icon Hosting was not configured."
			)
		case .cached:
			return SyncAssetResult(
				status: .cached,
				usedFallback: false,
				errorCode: nil,
				message: nil
			)
		case .uploaded:
			return SyncAssetResult(
				status: .uploaded,
				usedFallback: false,
				errorCode: nil,
				message: nil
			)
		case .failed(_, let fallbackPublicURL):
			return SyncAssetResult(
				status: .failed,
				usedFallback: fallbackPublicURL != nil,
				errorCode: "asset_hosting_failed",
				message: "The application icon could not be hosted."
			)
		}
	}

	// Apply mapping rules to the data model
	private func applyMappingRules(to data: inout ReportModel) {
		// Skip if no mapping rules or no data to map
		if mappingCache.isEmpty || (data.processInfoRaw == nil && data.mediaInfoRaw == nil) {
			return
		}

		// Apply process name mapping
		if var windowInfo = data.processInfoRaw {
			// Process application identifier mapping
			for rule in mappingCache where rule.type == .processApplicationIdentifier {
				if windowInfo.applicationIdentifier == rule.from {
					windowInfo.applicationIdentifier = rule.to
					break
				}
			}

			// Process name mapping
			for rule in mappingCache where rule.type == .processName {
				if windowInfo.appName == rule.from {
					windowInfo.appName = rule.to
					data.processName = rule.to
					break
				}
			}

			data.processInfoRaw = windowInfo
		}

		// Apply media name mapping
		if var mediaInfo = data.mediaInfoRaw {
			// Media process application identifier mapping
			for rule in mappingCache where rule.type == .mediaProcessApplicationIdentifier {
				if mediaInfo.applicationIdentifier == rule.from {
					mediaInfo = MediaInfo(
						name: mediaInfo.name,
						artist: mediaInfo.artist,
						album: mediaInfo.album,
						image: mediaInfo.image,
						duration: mediaInfo.duration,
						elapsedTime: mediaInfo.elapsedTime,
						processID: mediaInfo.processID,
						processName: mediaInfo.processName,
						executablePath: mediaInfo.executablePath,
						playing: mediaInfo.playing,
						applicationIdentifier: rule.to
					)
					break
				}
			}

			// Media process name mapping
			for rule in mappingCache where rule.type == .mediaProcessName {
				if mediaInfo.processName == rule.from {
					mediaInfo.processName = rule.to
					data.mediaProcessName = rule.to
					break
				}
			}

			data.mediaInfoRaw = mediaInfo
		}
	}

	private func applyPrivacyAliases(
		processAlias: String?,
		mediaAlias: String?,
		to data: inout ReportModel
	) {
		if let processAlias, !processAlias.isEmpty {
			data.processName = processAlias
			if var processInfo = data.processInfoRaw {
				processInfo.appName = processAlias
				data.processInfoRaw = processInfo
			}
		}

		if let mediaAlias, !mediaAlias.isEmpty {
			data.mediaProcessName = mediaAlias
			if var mediaInfo = data.mediaInfoRaw {
				mediaInfo.processName = mediaAlias
				data.mediaInfoRaw = mediaInfo
			}
		}
	}

	private func monitor() {
		guard !isSuspendedForSleep else { return }
		isMonitoring = true
		configureMonitoringSources()
		updateExtensions()
	}

	private func configureMonitoringSources() {
		guard !isSuspendedForSleep, isMonitoring,
			PreferencesDataModel.shared.reportingAllowed
		else { return }
		let enabledTypes = PreferencesDataModel.shared.enabledTypes.value.types

		if enabledTypes.contains(.process) {
			if !isProcessMonitoring {
				isProcessMonitoring = true
				ApplicationMonitor.shared.onWindowFocusChanged = { [weak self] info in
					guard let self,
						PreferencesDataModel.shared.reportingAllowed,
						PreferencesDataModel.shared.focusReport.value,
						PreferencesDataModel.shared.enabledTypes.value.types.contains(.process)
					else { return }
					self.prepareSend(windowInfo: info, trigger: .focusChanged)
				}
				ApplicationMonitor.shared.startWindowFocusMonitoring()
			}
		} else if isProcessMonitoring {
			isProcessMonitoring = false
			ApplicationMonitor.shared.stopWindowFocusMonitoring()
			ApplicationMonitor.shared.onWindowFocusChanged = nil
		}

		if enabledTypes.contains(.media) {
			if !isMediaMonitoring {
				isMediaMonitoring = true
				MediaInfoManager.startMonitoringPlaybackChanges { [weak self] mediaInfo in
					guard let self,
						PreferencesDataModel.shared.reportingAllowed,
						PreferencesDataModel.shared.enabledTypes.value.types.contains(.media)
					else { return }
					guard let mediaInfo else {
						let processEnabled = PreferencesDataModel.shared.enabledTypes.value.types
							.contains(.process)
						if processEnabled {
							self.prepareSend(
								windowInfo: ApplicationMonitor.shared.getFocusedWindowInfo(),
								resolveMissingMedia: false,
								trigger: .mediaChanged
							)
						} else {
							self.clearReportedState()
							self.statusItemManager.clearCurrentPresence()
							self.statusItemManager.toggleStatusItemIcon(.ready)
						}
						return
					}
					let windowInfo = PreferencesDataModel.shared.enabledTypes.value.types.contains(.process)
						? ApplicationMonitor.shared.getFocusedWindowInfo() : nil
					self.prepareSend(
						windowInfo: windowInfo,
						mediaInfo: mediaInfo,
						trigger: .mediaChanged
					)
				}
			}
		} else if isMediaMonitoring {
			isMediaMonitoring = false
			MediaInfoManager.stopMonitoringPlaybackChanges()
		}

		if enabledTypes.isEmpty {
			statusItemManager.clearCurrentPresence()
		}
		statusItemManager.toggleStatusItemIcon(.ready)
	}

	private func prepareSend(
		windowInfo optionalWindowInfo: FocusedWindowInfo?,
		mediaInfo optionalMediaInfo: MediaInfo? = nil,
		resolveMissingMedia: Bool = true,
		trigger: SyncEventTrigger
	) {
		guard !isSuspendedForSleep, PreferencesDataModel.shared.reportingAllowed else { return }
		let observedAt = Date()
		let enabledTypes = PreferencesDataModel.shared.enabledTypes.value.types
		guard !enabledTypes.isEmpty else { return }
		let windowInfo = enabledTypes.contains(.process)
			? (optionalWindowInfo ?? ApplicationMonitor.shared.getFocusedWindowInfo()) : nil
		// A media snapshot remains valid without Accessibility permission or a
		// readable focused window. Process-only sends still require a window.
		guard enabledTypes.contains(.media) || windowInfo != nil else { return }

		preparationGeneration += 1
		let generation = preparationGeneration
		let mediaInfo = enabledTypes.contains(.media)
			? (optionalMediaInfo ?? (resolveMissingMedia ? MediaInfoManager.getMediaInfo() : nil))
			: nil
		finishPreparingSend(
			windowInfo: windowInfo,
			mediaInfo: mediaInfo,
			observedAt: observedAt,
			generation: generation,
			trigger: trigger
		)
	}

	private func finishPreparingSend(
		windowInfo: FocusedWindowInfo?,
		mediaInfo: MediaInfo?,
		observedAt: Date,
		generation: Int,
		trigger: SyncEventTrigger
	) {
		guard generation == preparationGeneration,
			PreferencesDataModel.shared.reportingAllowed
		else { return }

		let enabledTypes = PreferencesDataModel.shared.enabledTypes.value.types
		if enabledTypes.isEmpty {
			statusItemManager.clearCurrentPresence()
			statusItemManager.toggleStatusItemIcon(.ready)
			return
		}
		var dataModel = ReportModel(
			windowInfo: nil,
			integrations: [],
			mediaInfo: nil,
			timeStamp: observedAt)

		let shouldIgnoreArtistNull = PreferencesDataModel.shared.ignoreNullArtist.value
		let privacyEvaluator = PresencePrivacyEvaluator(
			configuration: privacyConfigurationCache,
			legacyHiddenApplications: cachedFilteredProcessBundleIDs,
			legacyHiddenMediaApplications: cachedFilteredMediaBundleIDs,
			legacyHiddenMediaNames: cachedFilteredMediaAppNames
		)
		var processAlias: String?
		var mediaAlias: String?

		if enabledTypes.contains(.media), let mediaInfo = mediaInfo, mediaInfo.playing {
			let mediaDecision = privacyEvaluator.mediaDecision(
				applicationIdentifier: mediaInfo.applicationIdentifier,
				processName: mediaInfo.processName
			)
			let hasArtist = !(mediaInfo.artist?.isEmpty ?? true)
			if mediaDecision.sharesMedia && (!shouldIgnoreArtistNull || hasArtist) {
				dataModel.setMediaInfo(mediaInfo)
				mediaAlias = mediaDecision.displayAlias
			}
		}
		if enabledTypes.contains(.process), let windowInfo {
			let processDecision = privacyEvaluator.processDecision(
				applicationIdentifier: windowInfo.applicationIdentifier
			)
			if processDecision.sharesApplication {
				dataModel.setProcessInfo(windowInfo)
				processAlias = processDecision.displayAlias
				if !PreferencesDataModel.shareWindowTitles.value
					|| !processDecision.sharesWindowTitle
				{
					dataModel.windowTitle = nil
					if var sanitizedProcessInfo = dataModel.processInfoRaw {
						sanitizedProcessInfo.title = nil
						dataModel.processInfoRaw = sanitizedProcessInfo
					}
				}
			}
		}
		// Apply mapping rules to the data model before sending
		applyMappingRules(to: &dataModel)
		applyPrivacyAliases(
			processAlias: processAlias,
			mediaAlias: mediaAlias,
			to: &dataModel
		)
		statusItemManager.publishCurrentPresence(dataModel)

		// Both sources may have been filtered. Do not send an empty payload to every
		// integration or create an empty history row.
		guard dataModel.processInfoRaw != nil || dataModel.mediaInfoRaw != nil else {
			hasPendingNetworkRefresh = false
			clearReportedState()
			statusItemManager.clearCurrentPresence()
			statusItemManager.toggleStatusItemIcon(.ready)
			return
		}
		guard isNetworkAvailable() else {
			// Do not retain a sanitized model while offline: mappings, privacy rules,
			// enabled sources, and credentials may all change before connectivity
			// returns. A single marker is enough to request a fresh capture later.
			hasPendingNetworkRefresh = true
			cancelPendingReportWork(preservingNetworkRefresh: true)
			statusItemManager.toggleStatusItemIcon(.offline)
			return
		}
		hasPendingNetworkRefresh = false
		statusItemManager.toggleStatusItemIcon(.syncing)
		enqueueSend(dataModel, trigger: trigger)
	}

	private func enqueueSend(_ report: ReportModel, trigger: SyncEventTrigger) {
		pendingPresence = PendingPresence(report: report, trigger: trigger)
		guard sendTask == nil else { return }

		sendGeneration += 1
		let generation = sendGeneration
		activeSendTaskCount += 1
		sendTask = Task { @MainActor [weak self] in
			guard let self else { return }
			defer { self.activeSendTaskCount -= 1 }
			while !Task.isCancelled, PreferencesDataModel.shared.reportingAllowed,
				let pending = self.pendingPresence
			{
				self.pendingPresence = nil
				_ = await self.send(
					data: pending.report,
					generation: generation,
					trigger: pending.trigger
				)
			}

			if self.sendGeneration == generation {
				self.sendTask = nil
			}
		}
	}

	private func dispose() {
		isMonitoring = false
		isProcessMonitoring = false
		isMediaMonitoring = false
		ApplicationMonitor.shared.stopWindowFocusMonitoring()
		ApplicationMonitor.shared.onWindowFocusChanged = nil
		MediaInfoManager.stopMonitoringPlaybackChanges()

		cancelPendingReportWork()
		updateExtensions()

		statusItemManager.toggleStatusItemIcon(.paused)
	}

	private func cancelPendingReportWork(preservingNetworkRefresh: Bool = false) {
		preparationGeneration += 1
		if !preservingNetworkRefresh {
			hasPendingNetworkRefresh = false
		}
		pendingPresence = nil
		sendGeneration += 1
		sendTask?.cancel()
		for task in activeDestinationTasks.values {
			task.cancel()
		}
		activeDestinationTasks.removeAll()
		activeAssetResolutionTask?.cancel()
		activeAssetResolutionTask = nil
		clearReportedState()
		sendTask = nil
	}

	private var timer: Timer?
	private func setupTimer() {
		disposeTimer()
		guard !isSuspendedForSleep else { return }

		let interval = PreferencesDataModel.shared.sendInterval.value
		timer = Timer.scheduledTimer(
			withTimeInterval: TimeInterval(interval.rawValue), repeats: true
		) { [weak self] _ in
			Task { @MainActor in
				guard let self = self else { return }
				self.prepareSend(windowInfo: nil, trigger: .interval)
			}
		}
		if let timer {
			RunLoop.main.add(timer, forMode: .common)
		}
	}

	private func disposeTimer() {
		timer?.invalidate()
		timer = nil
	}

	init(assetHostingService: (any AssetHostingService)? = nil) {
		self.assetHostingService = assetHostingService ?? S3AssetHostingService()

		// Register all available extensions
		initializeExtensions()
		// The first event is now published immediately, so privacy and mapping
		// caches must be complete before the initial preference emission starts
		// monitoring.
		clearCaches()

		subscribeSettingsChanged()
	}

	private func initializeExtensions() {
		// S3 is asset infrastructure and is intentionally not a Presence destination.
		let extensions: [ReporterExtension] = [
			MixSpaceReporterExtension(),
			SlackReporterExtension(),
			DiscordReporterExtension(),
		]

		for ext in extensions {
			registerExtension(ext)
		}
	}

	deinit {
		sendTask?.cancel()
		for task in activeDestinationTasks.values {
			task.cancel()
		}
		activeAssetResolutionTask?.cancel()
	}
}

extension Reporter {
	private func subscribeSettingsChanged() {
		subscribeGeneralSettingsChanged()
		subscribeFilterSettingsChanged()
		subscribeMappingSettingsChanged()
		subscribeNetworkAvailabilityChanged()
	}

	private func subscribeNetworkAvailabilityChanged() {
		NotificationCenter.default.rx.notification(
			.processReporterNetworkAvailabilityDidChange
		)
		.compactMap { notification in
			notification.userInfo?[NetworkAvailabilityNotificationKey.isAvailable] as? Bool
		}
		.distinctUntilChanged()
		.observe(on: MainScheduler.instance)
		.subscribe(onNext: { [weak self] isAvailable in
			self?.handleNetworkAvailabilityChanged(isAvailable: isAvailable)
		})
		.disposed(by: disposeBag)
	}

	private func handleNetworkAvailabilityChanged(isAvailable: Bool) {
		let preferences = PreferencesDataModel.shared
		guard preferences.reportingAllowed,
			!preferences.enabledTypes.value.types.isEmpty
		else {
			hasPendingNetworkRefresh = false
			return
		}

		guard isAvailable else {
			hasPendingNetworkRefresh = true
			cancelPendingReportWork(preservingNetworkRefresh: true)
			statusItemManager.toggleStatusItemIcon(.offline)
			return
		}
		guard hasPendingNetworkRefresh else { return }

		// Keep the marker until a fresh, sanitized snapshot either enters the
		// online queue or is found to contain nothing shareable.
		statusItemManager.toggleStatusItemIcon(.ready)
		prepareSend(
			windowInfo: ApplicationMonitor.shared.getFocusedWindowInfo(),
			trigger: .interval
		)
	}

	private func subscribeMappingSettingsChanged() {
		let values = PreferencesDataModel.mappingList.share(replay: 1)
		values.subscribe { [weak self] mappingList in
			self?.mappingCache = mappingList.getList()
		}.disposed(by: disposeBag)

		values.skip(1)
			.debounce(.milliseconds(50), scheduler: MainScheduler.instance)
			.subscribe { [weak self] _ in
				self?.invalidatePreparedPresenceForPrivacyChange()
			}
			.disposed(by: disposeBag)
	}

	private func subscribeFilterSettingsChanged() {
		let values = Observable.combineLatest(
			PreferencesDataModel.filteredProcesses,
			PreferencesDataModel.filteredMediaProcesses,
			PreferencesDataModel.presencePrivacyConfiguration
		).share(replay: 1)

		values.subscribe { [weak self] processIDs, mediaIDs, configuration in
			guard let self else { return }
			self.cachedFilteredProcessBundleIDs = Set(processIDs)
			self.cachedFilteredMediaBundleIDs = Set(mediaIDs)
			self.cachedFilteredMediaAppNames = Set(
				mediaIDs.map { AppUtility.shared.getAppInfo(for: $0).displayName }
			)
			self.privacyConfigurationCache = configuration
		}
		.disposed(by: disposeBag)

		values.skip(1)
			.debounce(.milliseconds(50), scheduler: MainScheduler.instance)
			.subscribe { [weak self] _ in
				self?.invalidatePreparedPresenceForPrivacyChange()
			}
			.disposed(by: disposeBag)
	}

	private func refreshFilterCaches() {
		let processIDs = PreferencesDataModel.filteredProcesses.value
		let mediaIDs = PreferencesDataModel.filteredMediaProcesses.value
		cachedFilteredProcessBundleIDs = Set(processIDs)
		cachedFilteredMediaBundleIDs = Set(mediaIDs)
		cachedFilteredMediaAppNames = Set(
			mediaIDs.map { AppUtility.shared.getAppInfo(for: $0).displayName }
		)
		privacyConfigurationCache = PreferencesDataModel.presencePrivacyConfiguration.value
	}

	private func invalidatePreparedPresenceForPrivacyChange() {
		guard PreferencesDataModel.shared.reportingAllowed,
			!PreferencesDataModel.shared.enabledTypes.value.types.isEmpty
		else { return }
		cancelPendingReportWork()
		prepareSend(
			windowInfo: ApplicationMonitor.shared.getFocusedWindowInfo(),
			trigger: .settingsChanged
		)
	}

	private func subscribeGeneralSettingsChanged() {
		let preferences = PreferencesDataModel.shared

		let d1 = preferences.isEnabled.subscribe { [weak self] enabled in
			guard let self = self else { return }
			if enabled, preferences.reportingAllowed {
				self.monitor()
				if !preferences.enabledTypes.value.types.isEmpty {
					self.setupTimer()
					self.prepareSend(windowInfo: nil, trigger: .settingsChanged)
				}
			} else {
				self.dispose()
				self.disposeTimer()
			}
		}

		let d2 = preferences.sendInterval.skip(1).subscribe { [weak self] _ in
			guard let self = self else { return }
			if preferences.reportingAllowed, !preferences.enabledTypes.value.types.isEmpty {
				self.setupTimer()
			} else {
				self.disposeTimer()
			}
		}

		// Subscribe to extension configuration changes
		let d3 = Observable.combineLatest(
			preferences.mixSpaceIntegration,
			preferences.slackIntegration,
			preferences.discordIntegration,
			preferences.s3Integration
		).skip(1).subscribe { [weak self] _ in
			guard let self = self else { return }
			self.cancelPendingReportWork()
			PreferencesDataModel.pauseReportingIfDestinationUnavailable()
			self.updateExtensions()
			if preferences.reportingAllowed,
				!preferences.enabledTypes.value.types.isEmpty
			{
				self.prepareSend(windowInfo: nil, trigger: .settingsChanged)
			}
		}

		let d4 = preferences.enabledTypes.skip(1).subscribe { [weak self] enabledTypes in
			guard let self, preferences.reportingAllowed else { return }
			self.cancelPendingReportWork()
			self.configureMonitoringSources()
			self.updateExtensions()
			if enabledTypes.types.isEmpty {
				self.disposeTimer()
			} else {
				self.setupTimer()
				self.prepareSend(windowInfo: nil, trigger: .settingsChanged)
			}
		}
		let d5 = preferences.shareWindowTitles.skip(1).subscribe { [weak self] _ in
			guard let self, preferences.reportingAllowed,
				preferences.enabledTypes.value.types.contains(.process)
			else { return }
			self.cancelPendingReportWork()
			self.prepareSend(
				windowInfo: ApplicationMonitor.shared.getFocusedWindowInfo(),
				trigger: .settingsChanged
			)
		}
		let d6 = preferences.ignoreNullArtist.skip(1).subscribe { [weak self] _ in
			guard let self, preferences.reportingAllowed,
				preferences.enabledTypes.value.types.contains(.media)
			else { return }
			self.cancelPendingReportWork()
			self.prepareSend(
				windowInfo: ApplicationMonitor.shared.getFocusedWindowInfo(),
				trigger: .settingsChanged
			)
		}

		d1.disposed(by: disposeBag)
		d2.disposed(by: disposeBag)
		d3.disposed(by: disposeBag)
		d4.disposed(by: disposeBag)
		d5.disposed(by: disposeBag)
		d6.disposed(by: disposeBag)
	}
}
