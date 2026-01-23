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

    var isEnabled: Bool {
        return PreferencesDataModel.shared.discordIntegration.value.isEnabled
    }

    func createReporterOptions() -> ReporterOptions {
        return ReporterOptions { data in
            await self.sendDiscordPresence(data)
        }
    }

    func unregister(from reporter: Reporter) async {
        await reporter.unregister(name: name)
        DiscordClientProvider.shared.clearActivity()
        DiscordClientProvider.shared.shutdown()
    }

    private func ensureInitialized() {
        let cfg = PreferencesDataModel.shared.discordIntegration.value
        guard !cfg.applicationId.isEmpty else { return }
        if !DiscordClientProvider.shared.isConnected {
            DiscordClientProvider.shared.initialize(applicationId: cfg.applicationId)
        }
    }

    private func computePresence(from data: ReportModel) -> DiscordPresence? {
        let cfg = PreferencesDataModel.shared.discordIntegration.value

        var presence = DiscordPresence()

        let now = Int64(Date().timeIntervalSince1970)

        // Decide whether to show media or process
        let hasMedia = (data.mediaName != nil)
        let showMedia = cfg.showMediaInfo && hasMedia && (cfg.prioritizeMedia || !cfg.showProcessInfo)

        if showMedia {
            presence.details = data.mediaName
            presence.state = data.artist
            if cfg.useListeningForMedia {
                presence.activityType = .listening
            }

            if let elapsed = data.mediaElapsedTime, let duration = data.mediaDuration {
                presence.startTimestamp = now - Int64(elapsed)
                if duration > 0 {
                    presence.endTimestamp = now + Int64(duration - elapsed)
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
                presence.startTimestamp = now
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
        if presence.smallImageKey == nil || presence.smallImageKey!.isEmpty {
            presence.smallImageKey = cfg.brandSmallImageKey.isEmpty ? "processreporter" : cfg.brandSmallImageKey
        }
        presence.smallImageText = "ProcessReporter"

        // Optional buttons
        if cfg.enableButtons, !cfg.buttonLabel.isEmpty, !cfg.buttonUrl.isEmpty {
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
        let presenceSummary = presence == nil ? nil : Self.formatPresenceSummary(presence!)
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
        let duration = data.mediaDuration == nil ? "N/A" : String(format: "%.2f", data.mediaDuration!)
        let elapsed = data.mediaElapsedTime == nil ? "N/A" : String(format: "%.2f", data.mediaElapsedTime!)

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
        let start = presence.startTimestamp == nil ? "N/A" : "\(presence.startTimestamp!)"
        let end = presence.endTimestamp == nil ? "N/A" : "\(presence.endTimestamp!)"
        let largeKey = presence.largeImageKey ?? "N/A"
        let largeText = presence.largeImageText ?? "N/A"
        let smallKey = presence.smallImageKey ?? "N/A"
        let smallText = presence.smallImageText ?? "N/A"
        let buttons = presence.buttons == nil ? "N/A" : presence.buttons!.map { "\($0.label)=\($0.url)" }.joined(separator: ", ")

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
        // Known mappings -> asset keys that user should upload in Discord Dev Portal
        let map: [String: String] = [
            "spotify": "spotify",
            "music": "applemusic",       // Apple Music app on macOS
            "itunes": "applemusic",
            "neteasemusic": "netease",
            "网易云音乐": "netease",
            "qqmusic": "qqmusic",
            "qq 音乐": "qqmusic",
            "youtube music": "youtubemusic",
            "yt music": "youtubemusic",
            "vlc": "vlc"
        ]
        // Find first mapping whose key is contained in the process name
        for (k, v) in map {
            if name.contains(k) { return v }
        }
        return nil
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

        ensureInitialized()
        guard DiscordClientProvider.shared.isConnected else {
            recordDebug(data: data, presence: nil, outcome: "error", reason: "discord client not connected")
            return .failure(.networkError("Discord client not connected"))
        }

        guard let p = computePresence(from: data) else {
            recordDebug(data: data, presence: nil, outcome: "ignored", reason: "no presence to show")
            return .failure(.ignored)
        }

        DiscordClientProvider.shared.setActivity(
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

        recordDebug(data: data, presence: p, outcome: "success")
        return .success(())
    }
}
