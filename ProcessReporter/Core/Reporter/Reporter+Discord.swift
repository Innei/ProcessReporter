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
    var startTimestamp: Int64?
    var endTimestamp: Int64?
    var largeImageKey: String?
    var largeImageText: String?
    var smallImageKey: String?
    var smallImageText: String?
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

        // Always attach branding small image (asset key)
        presence.smallImageKey = cfg.brandSmallImageKey.isEmpty ? "processreporter" : cfg.brandSmallImageKey
        presence.smallImageText = "ProcessReporter"

        return presence
    }

    @MainActor
    private func sendDiscordPresence(_ data: ReportModel) async -> Result<Void, ReporterError> {
        let cfg = PreferencesDataModel.shared.discordIntegration.value
        guard cfg.isEnabled else { return .failure(.ignored) }
        guard !cfg.applicationId.isEmpty else { return .failure(.ignored) }

        ensureInitialized()
        guard DiscordClientProvider.shared.isConnected else {
            return .failure(.networkError("Discord client not connected"))
        }

        guard let p = computePresence(from: data) else {
            return .failure(.ignored)
        }

        DiscordClientProvider.shared.setActivity(
            details: p.details,
            state: p.state,
            startTimestamp: p.startTimestamp,
            endTimestamp: p.endTimestamp,
            largeImageKey: p.largeImageKey,
            largeImageText: p.largeImageText,
            smallImageKey: p.smallImageKey,
            smallImageText: p.smallImageText
        )

        return .success(())
    }
}
