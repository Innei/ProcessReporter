import Foundation

/// Builds a fresh, privacy-sanitized Live Desk snapshot. Application capture
/// remains synchronous, while media is resolved through a bounded provider
/// lookup so heartbeat and semantic events never replay an old timeline anchor
/// as if it had just been sampled.
@MainActor
final class CompanionPresenceCapture {
    private let mediaSessionTracker: CompanionMediaSessionTracker
    private let pausedRetentionInterval: TimeInterval

    private var continuityGeneration: Int?
    private var currentMediaIdentity: CompanionMediaSemanticIdentity?
    private var pausedSince: Date?

    init(
        mediaSessionTracker: CompanionMediaSessionTracker = CompanionMediaSessionTracker(),
        pausedRetentionInterval: TimeInterval = 5 * 60
    ) {
        self.mediaSessionTracker = mediaSessionTracker
        self.pausedRetentionInterval = pausedRetentionInterval
    }

    func capture(
        mediaTimelineEnabled: Bool,
        continuityGeneration: Int
    ) async throws -> SanitizedPresenceSnapshot {
        try Task.checkCancellation()
        await resetContinuityIfNeeded(generation: continuityGeneration)

        let enabledTypes = PreferencesDataModel.enabledTypes.value.types
        let application = captureApplication(enabledTypes: enabledTypes)
        let media: SanitizedMediaPresence?
        if mediaTimelineEnabled, enabledTypes.contains(.media) {
            media = try await captureMedia()
        } else {
            await clearMediaContinuity()
            media = nil
        }

        return SanitizedPresenceSnapshot(
            observedAt: .now,
            application: application,
            media: media
        )
    }

    private func captureApplication(
        enabledTypes: Set<Reporter.Types>
    ) -> SanitizedApplicationPresence? {
        guard enabledTypes.contains(.process),
              let process = ApplicationMonitor.shared.getFocusedWindowInfo()
        else {
            return nil
        }

        let evaluator = privacyEvaluator()
        let decision = evaluator.processDecision(
            applicationIdentifier: process.applicationIdentifier
        )
        let mappedName = PreferencesDataModel.mappingList.value.getList().first {
            $0.type == .processName && $0.from == process.appName
        }?.to

        return try? CompanionApplicationPresenceSanitizer.sanitize(
            capturedDisplayName: process.appName,
            mappedDisplayName: mappedName,
            displayAlias: decision.displayAlias,
            capturedWindowTitle: process.title,
            sharesApplication: decision.sharesApplication,
            sharesWindowTitle: decision.sharesWindowTitle,
            globalWindowTitleSharingEnabled: PreferencesDataModel.shareWindowTitles.value
        )
    }

    private func captureMedia() async throws -> SanitizedMediaPresence? {
        let mediaInfo: MediaInfo?
        let hasFreshTimeline: Bool
        do {
            switch try await MediaInfoManager.getMediaInfoFetchResultAsync(timeout: 2) {
            case .resolved(let resolved):
                mediaInfo = resolved
                hasFreshTimeline = true
            case .unavailable:
                mediaInfo = MediaInfoManager.getMediaInfo()
                hasFreshTimeline = false
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            mediaInfo = MediaInfoManager.getMediaInfo()
            hasFreshTimeline = false
        }

        guard let mediaInfo else {
            await clearMediaContinuity()
            return nil
        }

        let evaluator = privacyEvaluator()
        let decision = evaluator.mediaDecision(
            applicationIdentifier: mediaInfo.applicationIdentifier,
            processName: mediaInfo.processName
        )
        let mappings = PreferencesDataModel.mappingList.value.getList()
        let mappedPlayerName = mappings.first {
            $0.type == .mediaProcessName && $0.from == mediaInfo.processName
        }?.to ?? mediaInfo.processName
        let playerDisplayName = decision.displayAlias ?? mappedPlayerName
        let kind = CompanionMediaKindResolver.kind(
            applicationIdentifier: mediaInfo.applicationIdentifier
        )
        let identity = CompanionMediaSemanticIdentity(
            kind: kind,
            title: CompanionMediaPresenceSanitizer.normalizedText(mediaInfo.name),
            artist: CompanionMediaPresenceSanitizer.normalizedText(mediaInfo.artist),
            album: CompanionMediaPresenceSanitizer.normalizedText(mediaInfo.album),
            playerDisplayName: CompanionMediaPresenceSanitizer.normalizedText(playerDisplayName),
            durationSeconds: CompanionMediaPresenceSanitizer.normalizedTime(mediaInfo.duration)
        )
        let sampledAt = Date()

        if currentMediaIdentity != identity {
            currentMediaIdentity = identity
            pausedSince = mediaInfo.playing ? nil : sampledAt
        } else if mediaInfo.playing {
            pausedSince = nil
        } else if pausedSince == nil {
            pausedSince = sampledAt
        }

        if let pausedSince,
           !mediaInfo.playing,
           sampledAt.timeIntervalSince(pausedSince) > pausedRetentionInterval
        {
            await clearMediaContinuity()
            return nil
        }

        let sessionID = await mediaSessionTracker.sessionID(for: identity)
        do {
            let sanitized = try CompanionMediaPresenceSanitizer.sanitize(
                sessionID: sessionID,
                kind: kind,
                capturedTitle: mediaInfo.name,
                capturedArtist: mediaInfo.artist,
                capturedAlbum: mediaInfo.album,
                playerDisplayName: playerDisplayName,
                durationSeconds: mediaInfo.duration,
                positionSeconds: hasFreshTimeline ? mediaInfo.elapsedTime : nil,
                sampledAt: sampledAt,
                isPlaying: mediaInfo.playing,
                sharesMedia: decision.sharesMedia,
                requiresArtist: PreferencesDataModel.ignoreNullArtist.value
            )
            if sanitized == nil {
                await clearMediaContinuity()
            }
            return sanitized
        } catch {
            await clearMediaContinuity()
            return nil
        }
    }

    private func privacyEvaluator() -> PresencePrivacyEvaluator {
        let hiddenMediaApplications = Set(PreferencesDataModel.filteredMediaProcesses.value)
        return PresencePrivacyEvaluator(
            configuration: PreferencesDataModel.presencePrivacyConfiguration.value,
            legacyHiddenApplications: Set(PreferencesDataModel.filteredProcesses.value),
            legacyHiddenMediaApplications: hiddenMediaApplications,
            legacyHiddenMediaNames: Set(
                hiddenMediaApplications.map { identifier in
                    AppUtility.shared.getAppInfo(for: identifier).displayName
                }
            )
        )
    }

    private func resetContinuityIfNeeded(generation: Int) async {
        guard continuityGeneration != generation else { return }
        continuityGeneration = generation
        await clearMediaContinuity()
    }

    private func clearMediaContinuity() async {
        currentMediaIdentity = nil
        pausedSince = nil
        await mediaSessionTracker.reset()
    }
}
