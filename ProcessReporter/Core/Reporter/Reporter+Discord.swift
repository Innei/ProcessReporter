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
        clearReportedState()
        DiscordClientProvider.shared.shutdown()
        initializedApplicationId = nil
    }

    func clearReportedState() {
        DiscordClientProvider.shared.clearActivity()
        currentProcessName = nil
        processStartTimestamp = nil
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

    private func recordDebug(
        data: ReportModel,
        presence: DiscordPresence?,
        outcome: String,
        reason: String? = nil
    ) {
        let reportSummary = Self.formatReportSummary(data)
        let presenceSummary = presence.map(Self.formatPresenceSummary)
        let clientKind = DiscordClientProvider.shared is NoopDiscordClient ? "noop" : "sdk"
        let connected = DiscordClientProvider.shared.isConnected

        DiscordDebugStore.shared.update { snapshot in
            snapshot.lastOutcome = outcome
            snapshot.lastReason = reason
            snapshot.lastReportSummary = reportSummary
            snapshot.lastPresenceSummary = presenceSummary
            snapshot.clientKind = clientKind
            snapshot.isConnected = connected
        }
    }

    private static func formatReportSummary(_ data: ReportModel) -> String {
        let processName = data.processName ?? "N/A"
        let windowTitle = data.windowTitle ?? "N/A"
        let mediaName = data.mediaName ?? "N/A"
        let artist = data.artist ?? "N/A"
        let mediaProcess = data.mediaProcessName ?? "N/A"
        let duration = data.mediaDuration.map { String(format: "%.2f", $0) } ?? "N/A"
        let elapsed = data.mediaElapsedTime.map { String(format: "%.2f", $0) } ?? "N/A"

        return """
        processName=\(processName)
        windowTitle=\(windowTitle)
        mediaName=\(mediaName)
        artist=\(artist)
        mediaProcess=\(mediaProcess)
        duration=\(duration)
        elapsed=\(elapsed)
        """
    }

    private static func formatPresenceSummary(_ presence: DiscordPresence) -> String {
        let details = presence.details ?? "N/A"
        let state = presence.state ?? "N/A"
        let typeName = activityTypeName(presence.activityType)
        let start = presence.startTimestamp.map(String.init) ?? "N/A"
        let end = presence.endTimestamp.map(String.init) ?? "N/A"
        let largeKey = presence.largeImageKey ?? "N/A"
        let largeText = presence.largeImageText ?? "N/A"
        let smallKey = presence.smallImageKey ?? "N/A"
        let smallText = presence.smallImageText ?? "N/A"
        let buttons = presence.buttons?.map { "\($0.label)=\($0.url)" }.joined(separator: ", ")
            ?? "N/A"

        return """
        details=\(details)
        state=\(state)
        activityType=\(typeName)
        startTimestamp=\(start)
        endTimestamp=\(end)
        largeImageKey=\(largeKey)
        largeImageText=\(largeText)
        smallImageKey=\(smallKey)
        smallImageText=\(smallText)
        buttons=\(buttons)
        """
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
    private func sendDiscordPresence(_ data: ReportModel) async -> Result<Void, ReporterError> {
        let cfg = PreferencesDataModel.shared.discordIntegration.value
        guard cfg.isEnabled else {
            recordDebug(data: data, presence: nil, outcome: "ignored", reason: "disabled")
            return .failure(.ignored)
        }
        guard !cfg.applicationId.isEmpty else {
            recordDebug(data: data, presence: nil, outcome: "ignored", reason: "missing applicationId")
            return .failure(.ignored)
        }
        guard let applicationId = Int64(cfg.applicationId), applicationId > 0 else {
            recordDebug(data: data, presence: nil, outcome: "error", reason: "invalid applicationId")
            return .failure(.cancelled(message: "Discord applicationId must be a positive integer"))
        }

        ensureInitialized()
        guard DiscordClientProvider.shared.isConnected else {
            let reason = DiscordClientProvider.shared is NoopDiscordClient
                ? "Discord SDK is unavailable" : "Discord client not connected"
            recordDebug(data: data, presence: nil, outcome: "error", reason: reason)
            return .failure(.cancelled(message: reason))
        }

        guard let p = computePresence(from: data) else {
            clearReportedState()
            recordDebug(data: data, presence: nil, outcome: "ignored", reason: "no presence to show")
            return .failure(.ignored)
        }

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
            recordDebug(data: data, presence: p, outcome: "success")
            return .success(())
        } catch {
            if Task.isCancelled {
                recordDebug(data: data, presence: p, outcome: "cancelled")
                return .failure(.cancelled(message: "Discord activity update was cancelled"))
            }
            let reason = error.localizedDescription
            recordDebug(data: data, presence: p, outcome: "error", reason: reason)
            return .failure(.networkError("Discord activity update failed: \(reason)"))
        }
    }
}
