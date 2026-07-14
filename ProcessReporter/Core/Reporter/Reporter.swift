import Cocoa
@preconcurrency import RxSwift

enum ReporterError: Error {
	case networkError(String)
	case cancelled(message: String)
	case unknown(message: String, successIntegrations: [String])
	case ratelimitExceeded(message: String)
	case ignored
	case databaseError(String)
}

enum SendError: Error {
	case failure([String])
	case persistenceFailure(message: String, successfulIntegrations: [String])
}

struct ReporterOptions {
	let priority: Int
	let onSend: @MainActor (_ data: ReportModel) async -> Result<Void, ReporterError>

	init(
		priority: Int = 100,
		onSend: @escaping @MainActor (_ data: ReportModel) async -> Result<Void, ReporterError>
	) {
		self.priority = priority
		self.onSend = onSend
	}
}

@MainActor
class Reporter {
	private var mapping = [String: ReporterOptions]()
	private var statusItemManager = ReporterStatusItemManager()

	// Add reporter extensions array
	private var reporterExtensions: [ReporterExtension] = []

	private var cachedFilteredProcessBundleIDs = Set<String>()
	private var cachedFilteredMediaBundleIDs = Set<String>()
	private var cachedFilteredMediaAppNames = Set<String>()
	private let disposeBag = DisposeBag()
	private var isMonitoring = false
	private var isProcessMonitoring = false
	private var isMediaMonitoring = false
	private var preparationGeneration = 0
	private var preparationTask: Task<Void, Never>?
	private var pendingReport: ReportModel?
	private var sendGeneration = 0
	private var sendTask: Task<Void, Never>?
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
		guard PreferencesDataModel.shared.isEnabled.value else { return }

		// Recreate each source from the current preferences. Waiting is owned by
		// AppDelegate, so no pre-sleep callback or missed Timer event can leak into
		// the new monitoring session.
		reporterInitializedTime = .now
		monitor()
		if !PreferencesDataModel.shared.enabledTypes.value.types.isEmpty {
			setupTimer()
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
			&& PreferencesDataModel.shared.isEnabled.value
			&& !PreferencesDataModel.shared.enabledTypes.value.types.isEmpty
	}

	private func clearReportedState() {
		for ext in reporterExtensions where ext.isEnabled {
			ext.clearReportedState()
		}
	}

	public func register(name: String, options: ReporterOptions) {
		mapping[name] = options
	}

	public func unregister(name: String) {
		mapping.removeValue(forKey: name)
	}

	public func send(data: ReportModel) async -> Result<[String], SendError> {
		let maximumReportAge: TimeInterval = 20
		var successNames = [String]()
		var failureNames = [String]()
		var skippedNames = [String]()

		// Snapshot the registry before awaiting. Integrations are intentionally run
		// in sequence: ReportModel is a SwiftData reference type and is not safe to
		// read concurrently from child tasks. The send queue coalesces newer reports
		// so this does not create an unbounded backlog.
		let registeredReporters = mapping.sorted { lhs, rhs in
			if lhs.value.priority == rhs.value.priority {
				return lhs.key < rhs.key
			}
			return lhs.value.priority < rhs.value.priority
		}
		for (name, options) in registeredReporters {
			guard !Task.isCancelled, PreferencesDataModel.shared.isEnabled.value else {
				break
			}
			guard Date().timeIntervalSince(data.timeStamp) <= maximumReportAge else {
				NSLog("Dropping remaining integrations for a stale report older than 20 seconds")
				break
			}

			let result = await options.onSend(data)
			if case .success = result {
				successNames.append(name)
				continue
			}
			if case let .failure(error) = result {
				switch error {
				case .ignored, .ratelimitExceeded:
					skippedNames.append(name)
				case .databaseError(let message):
					failureNames.append(name)
					NSLog("\(name) database error: \(message)")
				default:
					failureNames.append(name)
					NSLog("\(name) failed: \(error)")
				}
			}
		}
		guard !Task.isCancelled, PreferencesDataModel.shared.isEnabled.value else {
			return .success(successNames)
		}

		// A skipped integration is not a successful delivery. The activity itself
		// is still persisted below because History is a local activity log, not only
		// a delivery log.
		if !skippedNames.isEmpty {
			NSLog("Report skipped by integrations: \(skippedNames.joined(separator: ", "))")
		}

		// Persist via DataStore (value-only, no SwiftData leakage)
		data.integrations = successNames
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
			integrations: data.integrations
		)
		do {
			try await DataStore.shared.saveReport(reportValue)
		} catch {
			NSLog("Failed to persist report history: \(error.localizedDescription)")
			if PreferencesDataModel.shared.isEnabled.value {
				if !successNames.isEmpty {
					statusItemManager.updateLastSendProcessNameItem(data)
				}
				statusItemManager.toggleStatusItemIcon(successNames.isEmpty ? .error : .partialError)
			}
			return .failure(
				.persistenceFailure(
					message: error.localizedDescription,
					successfulIntegrations: successNames
				)
			)
		}

		let isAllFailed = successNames.isEmpty && !failureNames.isEmpty
		if !successNames.isEmpty, PreferencesDataModel.shared.isEnabled.value {
			statusItemManager.updateLastSendProcessNameItem(data)
		}

		if failureNames.isEmpty {
			if PreferencesDataModel.shared.isEnabled.value {
				statusItemManager.toggleStatusItemIcon(.ready)
			}
			return .success(successNames)
		} else {
			if PreferencesDataModel.shared.isEnabled.value {
				statusItemManager.toggleStatusItemIcon(isAllFailed ? .error : .partialError)
			}
			return .failure(.failure(failureNames))
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

	private func monitor() {
		guard !isSuspendedForSleep else { return }
		isMonitoring = true
		configureMonitoringSources()
		updateExtensions()
	}

	private func configureMonitoringSources() {
		guard !isSuspendedForSleep, isMonitoring,
			PreferencesDataModel.shared.isEnabled.value
		else { return }
		let enabledTypes = PreferencesDataModel.shared.enabledTypes.value.types

		if enabledTypes.contains(.process) {
			if !isProcessMonitoring {
				isProcessMonitoring = true
				ApplicationMonitor.shared.onWindowFocusChanged = { [weak self] info in
					guard let self,
						PreferencesDataModel.shared.isEnabled.value,
						PreferencesDataModel.shared.focusReport.value,
						PreferencesDataModel.shared.enabledTypes.value.types.contains(.process)
					else { return }
					self.prepareSend(windowInfo: info)
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
						PreferencesDataModel.shared.isEnabled.value,
						PreferencesDataModel.shared.enabledTypes.value.types.contains(.media)
					else { return }
					guard let mediaInfo else {
						self.statusItemManager.updateCurrentMediaItem(nil)
						let processEnabled = PreferencesDataModel.shared.enabledTypes.value.types
							.contains(.process)
						if processEnabled {
							self.prepareSend(
								windowInfo: ApplicationMonitor.shared.getFocusedWindowInfo(),
								resolveMissingMedia: false
							)
						} else {
							self.clearReportedState()
						}
						return
					}
					self.statusItemManager.updateCurrentMediaItem(mediaInfo)
					let windowInfo = PreferencesDataModel.shared.enabledTypes.value.types.contains(.process)
						? ApplicationMonitor.shared.getFocusedWindowInfo() : nil
					self.prepareSend(windowInfo: windowInfo, mediaInfo: mediaInfo)
				}
			}
		} else if isMediaMonitoring {
			isMediaMonitoring = false
			MediaInfoManager.stopMonitoringPlaybackChanges()
			statusItemManager.updateCurrentMediaItem(nil)
		}

		statusItemManager.toggleStatusItemIcon(enabledTypes.isEmpty ? .paused : .ready)
	}

	private var reporterInitializedTime: Date

	private func prepareSend(
		windowInfo optionalWindowInfo: FocusedWindowInfo?,
		mediaInfo optionalMediaInfo: MediaInfo? = nil,
		resolveMissingMedia: Bool = true
	) {
		guard !isSuspendedForSleep, PreferencesDataModel.shared.isEnabled.value else { return }
		let enabledTypes = PreferencesDataModel.shared.enabledTypes.value.types
		guard !enabledTypes.isEmpty else { return }
		let windowInfo = enabledTypes.contains(.process)
			? (optionalWindowInfo ?? ApplicationMonitor.shared.getFocusedWindowInfo()) : nil
		// A media snapshot remains valid without Accessibility permission or a
		// readable focused window. Process-only sends still require a window.
		guard enabledTypes.contains(.media) || windowInfo != nil else { return }

		preparationGeneration += 1
		let generation = preparationGeneration
		preparationTask?.cancel()

		if let optionalMediaInfo, enabledTypes.contains(.media) {
			preparationTask = nil
			finishPreparingSend(
				windowInfo: windowInfo,
				mediaInfo: optionalMediaInfo,
				generation: generation
			)
			return
		}
		if !enabledTypes.contains(.media) || !resolveMissingMedia {
			preparationTask = nil
			finishPreparingSend(windowInfo: windowInfo, mediaInfo: nil, generation: generation)
			return
		}

		preparationTask = Task { @MainActor [weak self] in
			let mediaInfo = try? await MediaInfoManager.getMediaInfoAsync(timeout: 3.0)
			guard let self, !Task.isCancelled else { return }
			self.finishPreparingSend(
				windowInfo: windowInfo,
				mediaInfo: mediaInfo,
				generation: generation
			)
		}
	}

	private func finishPreparingSend(
		windowInfo: FocusedWindowInfo?,
		mediaInfo: MediaInfo?,
		generation: Int
	) {
		guard generation == preparationGeneration,
			PreferencesDataModel.shared.isEnabled.value
		else { return }
		preparationTask = nil

		let now = Date()
		// Ignore the first 2 seconds after initialization to wait for the setting synchronization to complete
		if now.timeIntervalSince(reporterInitializedTime) < 2 {
			return
		}

		let enabledTypes = PreferencesDataModel.shared.enabledTypes.value.types
		if enabledTypes.isEmpty {
			statusItemManager.toggleStatusItemIcon(.paused)
			return
		}
		if !isNetworkAvailable() {
			statusItemManager.toggleStatusItemIcon(.offline)
		} else {
			statusItemManager.toggleStatusItemIcon(.syncing)
		}

		var dataModel = ReportModel(
			windowInfo: nil,
			integrations: [],
			mediaInfo: nil)

		let shouldIgnoreArtistNull = PreferencesDataModel.shared.ignoreNullArtist.value

		if enabledTypes.contains(.media), let mediaInfo = mediaInfo, mediaInfo.playing {
			// Filter media name
			let isFiltered: Bool
			if let applicationIdentifier = mediaInfo.applicationIdentifier {
				isFiltered = cachedFilteredMediaBundleIDs.contains(applicationIdentifier)
			} else {
				isFiltered = cachedFilteredMediaAppNames.contains(mediaInfo.processName)
			}

			let hasArtist = !(mediaInfo.artist?.isEmpty ?? true)
			if !isFiltered && (!shouldIgnoreArtistNull || hasArtist) {
				dataModel.setMediaInfo(mediaInfo)
			}
		}
		// Filter process name
		if enabledTypes.contains(.process), let windowInfo,
			!cachedFilteredProcessBundleIDs.contains(windowInfo.applicationIdentifier)
		{
			dataModel.setProcessInfo(windowInfo)
		}
		if let mediaInfo = mediaInfo, mediaInfo.playing {
			statusItemManager.updateCurrentMediaItem(mediaInfo)
		}

		// Apply mapping rules to the data model before sending
		applyMappingRules(to: &dataModel)

		// Both sources may have been filtered. Do not send an empty payload to every
		// integration or create an empty history row.
		guard dataModel.processInfoRaw != nil || dataModel.mediaInfoRaw != nil else {
			clearReportedState()
			statusItemManager.toggleStatusItemIcon(.ready)
			return
		}

		enqueueSend(dataModel)
	}

	private func enqueueSend(_ report: ReportModel) {
		pendingReport = report
		guard sendTask == nil else { return }

		sendGeneration += 1
		let generation = sendGeneration
		sendTask = Task { @MainActor [weak self] in
			guard let self else { return }
			while !Task.isCancelled, PreferencesDataModel.shared.isEnabled.value,
				let report = self.pendingReport
			{
				self.pendingReport = nil
				_ = await self.send(data: report)
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

	private func cancelPendingReportWork() {
		preparationGeneration += 1
		preparationTask?.cancel()
		preparationTask = nil
		pendingReport = nil
		sendGeneration += 1
		sendTask?.cancel()
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
				self.prepareSend(windowInfo: nil)
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

	init() {
		reporterInitializedTime = Date()

		// Register all available extensions
		initializeExtensions()

		subscribeSettingsChanged()
	}

	private func initializeExtensions() {
		// Register all reporter extensions
		let extensions: [ReporterExtension] = [
			MixSpaceReporterExtension(),
			S3ReporterExtension(),
			SlackReporterExtension(),
			DiscordReporterExtension(),
		]

		for ext in extensions {
			registerExtension(ext)
		}
	}

	deinit {
		preparationTask?.cancel()
		sendTask?.cancel()
	}
}

extension Reporter {
	private func subscribeSettingsChanged() {
		subscribeGeneralSettingsChanged()
		subscribeFilterSettingsChanged()
		subscribeMappingSettingsChanged()
	}

	private func subscribeMappingSettingsChanged() {
		PreferencesDataModel.mappingList.subscribe { [weak self] mappingList in
			self?.mappingCache = mappingList.getList()
		}.disposed(by: disposeBag)
	}

	private func subscribeFilterSettingsChanged() {
		let d1 = PreferencesDataModel.filteredProcesses.subscribe { [weak self] appIds in
			self?.cachedFilteredProcessBundleIDs = Set(appIds)
		}
		let d2 = PreferencesDataModel.filteredMediaProcesses.subscribe { [weak self] appIds in
			guard let self else { return }
			self.cachedFilteredMediaBundleIDs = Set(appIds)
			self.cachedFilteredMediaAppNames = Set(
				appIds.map { AppUtility.shared.getAppInfo(for: $0).displayName }
			)
		}
		d1.disposed(by: disposeBag)
		d2.disposed(by: disposeBag)
	}

	private func refreshFilterCaches() {
		let processIDs = PreferencesDataModel.filteredProcesses.value
		let mediaIDs = PreferencesDataModel.filteredMediaProcesses.value
		cachedFilteredProcessBundleIDs = Set(processIDs)
		cachedFilteredMediaBundleIDs = Set(mediaIDs)
		cachedFilteredMediaAppNames = Set(
			mediaIDs.map { AppUtility.shared.getAppInfo(for: $0).displayName }
		)
	}

	private func subscribeGeneralSettingsChanged() {
		let preferences = PreferencesDataModel.shared

		let d1 = preferences.isEnabled.subscribe { [weak self] enabled in
			guard let self = self else { return }
			if enabled {
				self.monitor()
				if !preferences.enabledTypes.value.types.isEmpty {
					self.setupTimer()
					self.prepareSend(windowInfo: nil)
				}
			} else {
				self.dispose()
				self.disposeTimer()
			}
		}

		let d2 = preferences.sendInterval.subscribe { [weak self] _ in
			guard let self = self else { return }
			if preferences.isEnabled.value, !preferences.enabledTypes.value.types.isEmpty {
				self.setupTimer()
			} else {
				self.disposeTimer()
			}
		}

		// Subscribe to extension configuration changes
		let d3 = Observable.combineLatest(
			preferences.mixSpaceIntegration,
			preferences.s3Integration,
			preferences.slackIntegration,
			preferences.discordIntegration
		).subscribe { [weak self] _ in
			guard let self = self else { return }
			self.updateExtensions()
		}

		let d4 = preferences.enabledTypes.subscribe { [weak self] enabledTypes in
			guard let self, preferences.isEnabled.value else { return }
			self.cancelPendingReportWork()
			self.configureMonitoringSources()
			self.updateExtensions()
			if enabledTypes.types.isEmpty {
				self.disposeTimer()
			} else {
				self.setupTimer()
			}
		}

		d1.disposed(by: disposeBag)
		d2.disposed(by: disposeBag)
		d3.disposed(by: disposeBag)
		d4.disposed(by: disposeBag)
	}
}
