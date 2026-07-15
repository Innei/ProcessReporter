//
//  Reporter+Discord.swift
//  ProcessReporter
//
//  Created by Codex on 2025/8/27.
//

import Foundation

private struct DiscordPresence {
    var details: String?
    var state: String?
    var activityType: DiscordActivityType?
    var startTimestamp: Int64?
    var endTimestamp: Int64?
    var largeImageKey: String?
    var largeImageText: String?
    var smallImageKey: String?
    var smallImageText: String?
    var buttons: [DiscordButton]? = nil
}

class DiscordReporterExtension: ReporterExtension {
    var name: String = "Discord"
    private var initializedApplicationId: String?
    private var currentProcessName: String?
    private var processStartTimestamp: Int64?
    private var activityClearTask: Task<Void, Never>?
    private var activityClearPending = false
    private var activityClearGeneration: UInt64 = 0
    private var shutdownAfterActivityClear = false

    var isEnabled: Bool {
        return PreferencesDataModel.shared.discordIntegration.value.isEnabled
    }

    func createReporterOptions() -> ReporterOptions {
        return ReporterOptions { data in
            await self.sendDiscordPresence(data)
        }
    }

    func unregister(from reporter: Reporter) {
        reporter.unregister(name: name)
        scheduleActivityClear(shutdownAfterCompletion: true)
        currentProcessName = nil
        processStartTimestamp = nil
    }

    func clearReportedState() {
        scheduleActivityClear(shutdownAfterCompletion: false)
        currentProcessName = nil
        processStartTimestamp = nil
    }

    func waitForPendingCleanup(until deadline: ContinuousClock.Instant) async {
        let clock = ContinuousClock()
        while activityClearPending, clock.now < deadline {
            guard !Task.isCancelled else { break }
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                break
            }
        }

        if activityClearPending {
            activityClearGeneration &+= 1
            activityClearTask?.cancel()
            activityClearTask = nil
            activityClearPending = false
            shutdownAfterActivityClear = false
            NSLog("[Discord] Activity clear did not finish before the cleanup deadline")
        }
        DiscordClientProvider.shared.shutdown()
        initializedApplicationId = nil
    }

    private func scheduleActivityClear(shutdownAfterCompletion: Bool) {
        shutdownAfterActivityClear = shutdownAfterActivityClear || shutdownAfterCompletion
        guard !activityClearPending else { return }

        activityClearPending = true
        activityClearGeneration &+= 1
        if activityClearGeneration == 0 {
            activityClearGeneration = 1
        }
        let generation = activityClearGeneration
        let connectionGeneration = DiscordClientProvider.shared.connectionGeneration
        activityClearTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var clearFailed = false
            if DiscordClientProvider.shared.connectionGeneration == connectionGeneration {
                do {
                    try await DiscordClientProvider.shared.clearActivity()
                } catch {
                    clearFailed = true
                    NSLog("[Discord] Activity clear failed: \(error.localizedDescription)")
                }
            }

            guard self.activityClearGeneration == generation else { return }
            self.activityClearPending = false
            self.activityClearTask = nil
            // A timed-out SDK clear cannot safely share a connection with a new
            // publish. Destroy the old core before any later send reinitializes it.
            if (self.shutdownAfterActivityClear || clearFailed),
               DiscordClientProvider.shared.connectionGeneration == connectionGeneration
            {
                DiscordClientProvider.shared.shutdown()
                self.initializedApplicationId = nil
            }
            self.shutdownAfterActivityClear = false
        }
    }

    private func waitForScheduledActivityClear() async {
        if let activityClearTask {
            await activityClearTask.value
        }
    }

    private func ensureInitialized() {
        let cfg = PreferencesDataModel.shared.discordIntegration.value
        guard !cfg.applicationId.isEmpty else { return }

        if initializedApplicationId != cfg.applicationId {
            if initializedApplicationId != nil {
                DiscordClientProvider.shared.shutdown()
            }
            initializedApplicationId = cfg.applicationId
        }
        if !DiscordClientProvider.shared.isConnected {
            DiscordClientProvider.shared.initialize(applicationId: cfg.applicationId)
        }
    }

    private func computePresence(from data: ReportModel) -> DiscordPresence? {
        let cfg = PreferencesDataModel.shared.discordIntegration.value

        var presence = DiscordPresence()

        let now = Int64(Date().timeIntervalSince1970)

        // Decide whether to show media or process
        let hasMedia = !(data.mediaName?.isEmpty ?? true)
        let hasProcess = !(data.processName?.isEmpty ?? true)
        let showMedia = cfg.showMediaInfo && hasMedia
            && (cfg.prioritizeMedia || !cfg.showProcessInfo || !hasProcess)

        if showMedia {
            presence.details = data.mediaName
            presence.state = data.artist
            if cfg.useListeningForMedia {
                presence.activityType = .listening
            }

            if cfg.showTimestamps, let rawElapsed = data.mediaElapsedTime, rawElapsed.isFinite {
                let maximumDelta = Double(Int64.max / 4)
                let elapsed = min(maximumDelta, max(0, rawElapsed))
                presence.startTimestamp = now - Int64(elapsed.rounded(.down))
                if let duration = data.mediaDuration, duration.isFinite, duration > 0 {
                    let remaining = duration - elapsed
                    if remaining.isFinite, remaining > 0 {
                        let boundedRemaining = min(maximumDelta, remaining)
                        presence.endTimestamp = now + Int64(boundedRemaining.rounded(.up))
                    }
                }
            }

            if !cfg.customLargeImageKey.isEmpty {
                presence.largeImageKey = cfg.customLargeImageKey
                presence.largeImageText = cfg.customLargeImageText.isEmpty ? data.mediaProcessName : cfg.customLargeImageText
            }

            // Dynamic player icon on small image, fallback to brand
            if let dynamicKey = Self.dynamicSmallImageKey(for: data.mediaProcessName) {
                presence.smallImageKey = dynamicKey
            }
        } else if cfg.showProcessInfo, let processName = data.processName {
            presence.details = processName
            presence.state = data.windowTitle

            if cfg.showTimestamps {
                if currentProcessName != processName || processStartTimestamp == nil {
                    currentProcessName = processName
                    processStartTimestamp = now
                }
                presence.startTimestamp = processStartTimestamp
            }

            if !cfg.customLargeImageKey.isEmpty {
                presence.largeImageKey = cfg.customLargeImageKey
                presence.largeImageText = cfg.customLargeImageText.isEmpty ? processName : cfg.customLargeImageText
            }
        } else {
            // Nothing to show
            return nil
        }

        // Attach branding small image if not already set by dynamic mapping
        if presence.smallImageKey?.isEmpty ?? true {
            presence.smallImageKey = cfg.brandSmallImageKey.isEmpty ? "processreporter" : cfg.brandSmallImageKey
        }
        presence.smallImageText = "ProcessReporter"

        // Optional buttons
        if cfg.enableButtons, !cfg.buttonLabel.isEmpty,
            Self.isValidButtonURL(cfg.buttonUrl)
        {
            presence.buttons = [DiscordButton(label: cfg.buttonLabel, url: cfg.buttonUrl)]
        }

        return presence
    }

    /// Mirrors the concrete transport contract implemented by
    /// `DiscordSDKBridge`. Every C activity string is a 128-byte buffer, the
    /// zero-initialized activity type is `playing`, and the vendored C SDK has
    /// no button fields. Normalizing once here keeps the SDK call and persisted
    /// output receipt derived from the same final payload.
    private static func transportPresence(_ presence: DiscordPresence) -> DiscordPresence {
        DiscordPresence(
            details: DiscordTransportContract.text(presence.details),
            state: DiscordTransportContract.text(presence.state),
            activityType: presence.activityType ?? .playing,
            startTimestamp: presence.startTimestamp,
            endTimestamp: presence.endTimestamp,
            largeImageKey: DiscordTransportContract.assetIdentifier(presence.largeImageKey),
            largeImageText: DiscordTransportContract.text(presence.largeImageText),
            smallImageKey: DiscordTransportContract.assetIdentifier(presence.smallImageKey),
            smallImageText: DiscordTransportContract.text(presence.smallImageText),
            buttons: nil
        )
    }

    private func recordDebug(
        outcome: String,
        reason: String? = nil
    ) {
        let clientKind = DiscordClientProvider.shared is NoopDiscordClient ? "noop" : "sdk"
        let connected = DiscordClientProvider.shared.isConnected

        DiscordDebugStore.shared.update { snapshot in
            snapshot.lastOutcome = outcome
            snapshot.lastReason = reason
            snapshot.clientKind = clientKind
            snapshot.isConnected = connected
        }
    }

    private static func deliveryOutputSummary(
        for presence: DiscordPresence
    ) -> SyncOutputSummary {
        var detailComponents = [String]()
        if let startTimestamp = presence.startTimestamp {
            detailComponents.append("Start: \(startTimestamp)")
        }
        if let endTimestamp = presence.endTimestamp {
            detailComponents.append("End: \(endTimestamp)")
        }
        if let largeImageKey = presence.largeImageKey, !largeImageKey.isEmpty {
            detailComponents.append("Large image: \(largeImageKey)")
        }
        if let largeImageText = presence.largeImageText, !largeImageText.isEmpty {
            detailComponents.append("Large image text: \(largeImageText)")
        }
        if let smallImageKey = presence.smallImageKey, !smallImageKey.isEmpty {
            detailComponents.append("Small image: \(smallImageKey)")
        }
        if let smallImageText = presence.smallImageText, !smallImageText.isEmpty {
            detailComponents.append("Small image text: \(smallImageText)")
        }
        let buttonLabels = presence.buttons?
            .map(\.label)
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        if let buttonLabels, !buttonLabels.isEmpty {
            // URLs are deliberately excluded from local History.
            detailComponents.append("Buttons: \(buttonLabels)")
        }

        return SyncOutputSummary(
            title: presence.details,
            subtitle: presence.state,
            detail: detailComponents.isEmpty ? nil : detailComponents.joined(separator: " · "),
            activityKind: presence.activityType.map { activityTypeName($0) }
        )
    }

    private static func activityTypeName(_ type: DiscordActivityType?) -> String {
        guard let type else { return "N/A" }
        switch type {
        case .playing: return "playing"
        case .streaming: return "streaming"
        case .listening: return "listening"
        case .watching: return "watching"
        case .custom: return "custom"
        case .competing: return "competing"
        }
    }

    private static func dynamicSmallImageKey(for mediaProcessName: String?) -> String? {
        guard let name = mediaProcessName?.lowercased(), !name.isEmpty else { return nil }
        // Keep specific names before generic "music"; Dictionary iteration order
        // previously made YouTube Music nondeterministically use the Apple key.
        let mappings: [(String, String)] = [
            ("youtube music", "youtubemusic"),
            ("yt music", "youtubemusic"),
            ("neteasemusic", "netease"),
            ("网易云音乐", "netease"),
            ("qqmusic", "qqmusic"),
            ("qq 音乐", "qqmusic"),
            ("spotify", "spotify"),
            ("itunes", "applemusic"),
            ("music", "applemusic"),
            ("vlc", "vlc"),
        ]
        for (candidate, key) in mappings {
            if name.contains(candidate) { return key }
        }
        return nil
    }

    private static func isValidButtonURL(_ rawValue: String) -> Bool {
        guard let components = URLComponents(string: rawValue),
            let scheme = components.scheme?.lowercased(),
            scheme == "https" || scheme == "http",
            components.host != nil
        else { return false }
        return true
    }

    @MainActor
    private func sendDiscordPresence(_ data: ReportModel) async -> ReporterDeliveryResult {
        let cfg = PreferencesDataModel.shared.discordIntegration.value
        guard cfg.isEnabled else {
            recordDebug(outcome: "ignored", reason: "disabled")
            return .failure(.ignored)
        }
        guard !cfg.applicationId.isEmpty else {
            recordDebug(outcome: "ignored", reason: "missing applicationId")
            return .failure(.ignored)
        }
        guard let applicationId = Int64(cfg.applicationId), applicationId > 0 else {
            recordDebug(outcome: "error", reason: "invalid applicationId")
            return .failure(.cancelled(message: "Discord applicationId must be a positive integer"))
        }

        await waitForScheduledActivityClear()
        ensureInitialized()
        guard DiscordClientProvider.shared.isConnected else {
            let reason = DiscordClientProvider.shared is NoopDiscordClient
                ? "Discord SDK is unavailable" : "Discord client not connected"
            recordDebug(outcome: "error", reason: reason)
            return .failure(.cancelled(message: reason))
        }

        guard let computedPresence = computePresence(from: data) else {
            clearReportedState()
            recordDebug(outcome: "ignored", reason: "no presence to show")
            return .failure(.ignored)
        }
        let p = Self.transportPresence(computedPresence)

        do {
            try await DiscordClientProvider.shared.setActivity(
                details: p.details,
                state: p.state,
                activityType: p.activityType,
                startTimestamp: p.startTimestamp,
                endTimestamp: p.endTimestamp,
                largeImageKey: p.largeImageKey,
                largeImageText: p.largeImageText,
                smallImageKey: p.smallImageKey,
                smallImageText: p.smallImageText,
                buttons: p.buttons
            )
            try Task.checkCancellation()
            recordDebug(outcome: "success")
            return .success(
                ReporterDeliveryReceipt(outputSummary: Self.deliveryOutputSummary(for: p))
            )
        } catch {
            if Task.isCancelled {
                // Some Discord SDK transports complete setActivity even after the
                // enclosing task is cancelled. Clear again so a stale generation
                // cannot restore an activity after privacy or lifecycle invalidation.
                clearReportedState()
                recordDebug(outcome: "cancelled")
                return .failure(.cancelled(message: "Discord activity update was cancelled"))
            }
            let reason = error.localizedDescription
            recordDebug(outcome: "error", reason: reason)
            return .failure(.networkError("Discord activity update failed: \(reason)"))
        }
    }
}
