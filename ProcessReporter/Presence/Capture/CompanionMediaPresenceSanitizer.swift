import Foundation

enum CompanionMediaKindResolver {
    private static let knownMusicPlayers: Set<String> = [
        "com.apple.Music",
        "com.netease.163music",
        "com.spotify.client",
        "com.tencent.QQMusicMac",
    ]

    static func kind(applicationIdentifier: String?) -> CompanionMediaKind {
        guard let applicationIdentifier,
              knownMusicPlayers.contains(applicationIdentifier)
        else {
            return .unknown
        }
        return .music
    }
}

enum CompanionMediaPresenceSanitizer {
    static func sanitize(
        sessionID: UUID,
        kind: CompanionMediaKind,
        capturedTitle: String?,
        capturedArtist: String?,
        capturedAlbum: String?,
        playerDisplayName: String?,
        durationSeconds: Double?,
        positionSeconds: Double?,
        sampledAt: Date,
        isPlaying: Bool,
        sharesMedia: Bool,
        requiresArtist: Bool
    ) throws -> SanitizedMediaPresence? {
        guard sharesMedia else { return nil }

        let title = normalizedText(capturedTitle)
        let artist = normalizedText(capturedArtist)
        guard !requiresArtist || artist != nil else { return nil }
        guard title != nil || artist != nil else { return nil }

        let duration = normalizedTime(durationSeconds)
        var position = normalizedTime(positionSeconds)
        if let duration, let positionValue = position {
            position = min(positionValue, duration)
        }

        return try SanitizedMediaPresence(
            sessionID: sessionID,
            kind: kind,
            title: title,
            artist: artist,
            album: normalizedText(capturedAlbum),
            playerDisplayName: normalizedText(playerDisplayName),
            playback: SanitizedMediaPlayback(
                state: isPlaying ? .playing : .paused,
                durationSeconds: duration,
                positionSeconds: position,
                sampledAt: sampledAt,
                rate: isPlaying ? 1 : 0
            )
        )
    }

    static func normalizedText(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        return normalized.isEmpty ? nil : normalized
    }

    static func normalizedTime(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
}
