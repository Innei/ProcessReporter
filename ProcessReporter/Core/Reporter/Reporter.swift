import Cocoa
import RxSwift

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
}

struct ReporterOptions {
	let onSend: (_ data: ReportModel) async -> Result<Void, ReporterError>
}

@MainActor
class Reporter {
	private var mapping = [String: ReporterOptions]()
	private var statusItemManager = ReporterStatusItemManager()

	// Add reporter extensions array
	private var reporterExtensions: [ReporterExtension] = []

	private var cachedFilteredProcessAppNames = [String]()
	private var cachedFilteredMediaAppNames = [String]()
	private var disposers: [Disposable] = []

	// Mapping cache
	private var mappingCache: [PreferencesDataModel.Mapping] = []

	// Clear all caches for memory cleanup
	public func clearCaches() {
		cachedFilteredProcessAppNames.removeAll()
		cachedFilteredMediaAppNames.removeAll()
		mappingCache.removeAll()
	}

	// Register a reporter extension
	public func registerExtension(_ extension: ReporterExtension) {
		reporterExtensions.append(`extension`)
		if `extension`.isEnabled {
			Task {
				await `extension`.register(to: self)
			}
		}
	}

	// Update the status of all extensions
	public func updateExtensions() async {
		for ext in reporterExtensions {
			if ext.isEnabled {
				await ext.register(to: self)
			} else {
				await ext.unregister(from: self)
			}
		}
	}

	public func register(name: String, options: ReporterOptions) {
		mapping[name] = options
	}

	public func unregister(name: String) {
		mapping.removeValue(forKey: name)
	}

	public func send(data: ReportModel) async -> Result<[String], SendError> {
		let results = await withTaskGroup(of: (String, Result<Void, ReporterError>).self) { group in
			for (name, options) in mapping {
				group.addTask {
					let result = await options.onSend(data)
					return (name, result)
				}
			}

			var allResults = [(String, Result<Void, ReporterError>)]()
			for await result in group {
				allResults.append(result)
			}
			return allResults
		}

		var successNames = [String]()
		var failureNames = [String]()

		let failures = results.filter { name, result in
			if case .success = result {
				successNames.append(name)
				return false
			}
			if case let .failure(error) = result {
				switch error {
				case .ignored, .ratelimitExceeded:
					successNames.append(name)
					return false
				case .databaseError(let message):
					failureNames.append(name)
					NSLog("\(name) database error: \(message)")
					return true
				default:
					failureNames.append(name)
					NSLog("\(name) failed: \(error)")
					return true
				}
			}
			return true
		}

		// Save to database using background context
		data.integrations = successNames
		do {
			try await Database.shared.performBackgroundTask { context in
				context.insert(data)
				try context.save()
			}
		} catch {
			NSLog("Failed to save report to database: \(error)")
		}
		let isAllFailed = successNames.isEmpty && !failures.isEmpty
		if !isAllFailed {
			statusItemManager.updateLastSendProcessNameItem(data)
		}

		if failures.isEmpty {
			statusItemManager.toggleStatusItemIcon(.syncing)
			return .success(successNames)
		} else {
			statusItemManager.toggleStatusItemIcon(isAllFailed ? .error : .partialError)
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
					mediaInfo.processName = rule.to
					data.mediaProcessName = rule.to
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
		ApplicationMonitor.shared.startMouseMonitoring()
		ApplicationMonitor.shared.startWindowFocusMonitoring()
		ApplicationMonitor.shared.onWindowFocusChanged = { [weak self] info in
			guard let self = self else { return }
			if PreferencesDataModel.shared.focusReport.value
				&& PreferencesDataModel.shared.enabledTypes.value.types.contains(.process)
			{
				self.prepareSend(windowInfo: info)
			}
		}

		MediaInfoManager.startMonitoringPlaybackChanges { [weak self] mediaInfo in
			guard let self = self else { return }
			if PreferencesDataModel.shared.enabledTypes.value.types.contains(.media) {
				self.prepareSend(
					windowInfo: ApplicationMonitor.shared.getFocusedWindowInfo(),
					mediaInfo: mediaInfo
				)
			}
		}
		statusItemManager.toggleStatusItemIcon(.syncing)
	}

	private var reporterInitializedTime: Date

	private func prepareSend(
		windowInfo optionalWindowInfo: FocusedWindowInfo?,
		mediaInfo optionalMediaInfo: MediaInfo? = nil
	) {

		var windowInfo: FocusedWindowInfo!
		if let optionalWindowInfo = optionalWindowInfo {
			windowInfo = optionalWindowInfo
		} else {
			windowInfo = ApplicationMonitor.shared.getFocusedWindowInfo()
			if windowInfo == nil {
				return
			}
		}

		var mediaInfo: MediaInfo?
		if let optionalMediaInfo = optionalMediaInfo {
			mediaInfo = optionalMediaInfo
		} else {
			mediaInfo = MediaInfoManager.getMediaInfo()
		}

		let appName = windowInfo.appName
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
			return
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

			if !cachedFilteredMediaAppNames.contains(mediaInfo.processName),
				!shouldIgnoreArtistNull
					|| (mediaInfo.artist != nil && !mediaInfo.artist!.isEmpty)
			{
				dataModel.setMediaInfo(mediaInfo)
			}
		}
		// Filter process name
		if enabledTypes.contains(.process), !cachedFilteredProcessAppNames.contains(appName) {
			dataModel.setProcessInfo(windowInfo)
		}
		if let mediaInfo = mediaInfo, mediaInfo.playing {
			statusItemManager.updateCurrentMediaItem(mediaInfo)
		}

		// Apply mapping rules to the data model before sending
		applyMappingRules(to: &dataModel)

		Task { @MainActor in
			//            debugPrint(dataModel)
			_ = await self.send(data: dataModel)
		}
	}

	private func dispose() {
		ApplicationMonitor.shared.stopMouseMonitoring()
		ApplicationMonitor.shared.stopWindowFocusMonitoring()

		statusItemManager.toggleStatusItemIcon(.paused)
	}

	private var timer: Timer?
	private func setupTimer() {
		disposeTimer()

		let interval = PreferencesDataModel.shared.sendInterval.value
		timer = Timer.scheduledTimer(
			withTimeInterval: TimeInterval(interval.rawValue), repeats: true
		) { [weak self] _ in
			Task { @MainActor in
				guard let self = self else { return }
				if let info = ApplicationMonitor.shared.getFocusedWindowInfo() {
					self.prepareSend(windowInfo: info)
				}
			}
		}
		RunLoop.main.add(timer!, forMode: .common)
	}

	private func disposeTimer() {
		timer?.invalidate()
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
		]

		for ext in extensions {
			registerExtension(ext)
		}
	}

	deinit {
		for disposer in disposers {
			disposer.dispose()
		}
	}
}

extension Reporter {
	private func subscribeSettingsChanged() {
		subscribeGeneralSettingsChanged()
		subscribeFilterSettingsChanged()
		subscribeMappingSettingsChanged()
	}

	private func subscribeMappingSettingsChanged() {
		let disposer = PreferencesDataModel.mappingList.subscribe { [weak self] mappingList in
			self?.mappingCache = mappingList.getList()
		}
		disposers.append(disposer)
	}

	private func subscribeFilterSettingsChanged() {
		let d1 = PreferencesDataModel.filteredProcesses.subscribe { [weak self] appIds in
			self?.cachedFilteredProcessAppNames.removeAll()
			for appId in appIds {
				let appInfo = AppUtility.shared.getAppInfo(for: appId)
				self?.cachedFilteredProcessAppNames.append(appInfo.displayName)
			}
		}
		let d2 = PreferencesDataModel.filteredMediaProcesses.subscribe { [weak self] appIds in
			self?.cachedFilteredMediaAppNames.removeAll()
			for appId in appIds {
				let appInfo = AppUtility.shared.getAppInfo(for: appId)
				self?.cachedFilteredMediaAppNames.append(appInfo.displayName)
			}
		}
		disposers.append(contentsOf: [d1, d2])
	}

	private func subscribeGeneralSettingsChanged() {
		let preferences = PreferencesDataModel.shared

		let d1 = preferences.isEnabled.subscribe { [weak self] enabled in
			guard let self = self else { return }
			if enabled {
				self.monitor()
			} else {
				self.dispose()
				self.disposeTimer()
			}
		}

		if preferences.isEnabled.value {
			if let info = ApplicationMonitor.shared.getFocusedWindowInfo() {
				prepareSend(windowInfo: info)
			}
		}

		let d2 = preferences.sendInterval.subscribe { [weak self] _ in
			guard let self = self else { return }
			if preferences.isEnabled.value {
				self.setupTimer()
			} else {
				self.disposeTimer()
			}
		}

		// Subscribe to extension configuration changes
		let d3 = Observable.combineLatest(
			preferences.mixSpaceIntegration,
			preferences.s3Integration,
			preferences.slackIntegration
		).subscribe { [weak self] _ in
			guard let self = self else { return }
			Task {
				await self.updateExtensions()
			}
		}

		disposers.append(contentsOf: [d1, d2, d3])
	}
}
