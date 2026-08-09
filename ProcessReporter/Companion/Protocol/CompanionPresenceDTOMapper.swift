import Foundation

enum CompanionPresenceMappingError: Error, Equatable, Sendable {
    case invalidIdentifier(field: String)
    case sequenceOutOfRange
    case textTooLong(field: String, maximumUnicodeScalars: Int)
    case invalidActivityKey
    case invalidIconURL
    case invalidNumber(field: String)
    case invalidPlaybackRate
}

struct CompanionPresenceDTOMapper: Sendable {
    private let allowedAssetHosts: Set<String>
    private let minimumLeaseSeconds: Int
    private let maximumLeaseSeconds: Int

    init(
        allowedAssetHosts: Set<String> = [],
        minimumLeaseSeconds: Int = 30,
        maximumLeaseSeconds: Int = 120
    ) {
        self.allowedAssetHosts = Set(allowedAssetHosts.map { $0.lowercased() })
        self.minimumLeaseSeconds = minimumLeaseSeconds
        self.maximumLeaseSeconds = max(minimumLeaseSeconds, maximumLeaseSeconds)
    }

    func makePresenceRequest(
        snapshot: SanitizedPresenceSnapshot,
        deviceID: String,
        sequence: Int,
        requestedLeaseSeconds: Int = 90,
        requestID: String = UUID().uuidString
    ) throws -> CompanionPresenceRequestV2 {
        try validateIdentifier(requestID, field: "meta.requestId")
        try validateIdentifier(deviceID, field: "meta.deviceId")
        try validateSequence(sequence)

        let application = try snapshot.application.map(makeApplicationContext)
        let media = try snapshot.media.map(makeMediaContext)
        let availability: LiveDeskAvailability = application == nil && media == nil
            ? .idle
            : .active

        return CompanionPresenceRequestV2(
            meta: CompanionPresenceRequestMetaV2(
                requestID: requestID,
                deviceID: deviceID,
                sequence: sequence,
                observedAt: snapshot.observedAt
            ),
            data: CompanionPresenceDataV2(
                availability: availability,
                lease: CompanionLeaseV2(
                    ttlSeconds: min(
                        max(requestedLeaseSeconds, minimumLeaseSeconds),
                        maximumLeaseSeconds
                    )
                ),
                application: application,
                media: media
            )
        )
    }

    func makeClearRequest(
        reason: CompanionPresenceClearReasonV2,
        observedAt: Date,
        deviceID: String,
        sequence: Int,
        requestID: String = UUID().uuidString
    ) throws -> CompanionPresenceClearRequestV2 {
        try validateIdentifier(requestID, field: "meta.requestId")
        try validateIdentifier(deviceID, field: "meta.deviceId")
        try validateSequence(sequence)

        return CompanionPresenceClearRequestV2(
            meta: CompanionPresenceRequestMetaV2(
                requestID: requestID,
                deviceID: deviceID,
                sequence: sequence,
                observedAt: observedAt
            ),
            data: CompanionPresenceClearDataV2(reason: reason)
        )
    }

    private func makeApplicationContext(
        _ application: SanitizedApplicationPresence
    ) throws -> CompanionApplicationContextV2 {
        try validateLength(
            application.displayName,
            field: "data.application.displayName",
            maximum: 120
        )

        let activity = try application.activity.map { activity in
            if let key = activity.key {
                guard key.range(
                    of: "^[a-z][a-z0-9.-]{0,63}$",
                    options: .regularExpression
                ) != nil else {
                    throw CompanionPresenceMappingError.invalidActivityKey
                }
            }
            if let customLabel = activity.customLabel {
                try validateLength(
                    customLabel,
                    field: "data.application.activity.customLabel",
                    maximum: 80
                )
            }
            return CompanionActivityV2(key: activity.key, customLabel: activity.customLabel)
        }

        let window = try application.windowTitle.map { title in
            try validateLength(title, field: "data.application.window.title", maximum: 500)
            return CompanionWindowV2(title: title)
        }

        let icon = try application.iconURL.map { url in
            guard
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                components.scheme?.lowercased() == "https",
                components.user == nil,
                components.password == nil,
                let host = components.host?.lowercased(),
                allowedAssetHosts.contains(host),
                url.absoluteString.utf8.count <= 2_048
            else {
                throw CompanionPresenceMappingError.invalidIconURL
            }
            return CompanionIconV2(url: url.absoluteString)
        }

        return CompanionApplicationContextV2(
            displayName: application.displayName,
            activity: activity,
            window: window,
            icon: icon
        )
    }

    private func makeMediaContext(
        _ media: SanitizedMediaPresence
    ) throws -> CompanionMediaContextV2 {
        if let title = media.title {
            try validateLength(title, field: "data.media.title", maximum: 300)
        }
        if let artist = media.artist {
            try validateLength(artist, field: "data.media.artist", maximum: 300)
        }
        if let album = media.album {
            try validateLength(album, field: "data.media.album", maximum: 300)
        }
        if let playerDisplayName = media.playerDisplayName {
            try validateLength(
                playerDisplayName,
                field: "data.media.player.displayName",
                maximum: 120
            )
        }

        let playback = try makePlayback(media.playback)
        return CompanionMediaContextV2(
            sessionID: media.sessionID.uuidString,
            kind: media.kind,
            title: media.title,
            artist: media.artist,
            album: media.album,
            player: media.playerDisplayName.map(CompanionPlayerV2.init(displayName:)),
            playback: playback
        )
    }

    private func makePlayback(
        _ playback: SanitizedMediaPlayback
    ) throws -> CompanionMediaPlaybackV2 {
        guard playback.rate.isFinite, (0...4).contains(playback.rate) else {
            throw CompanionPresenceMappingError.invalidPlaybackRate
        }
        switch playback.state {
        case .paused where playback.rate != 0:
            throw CompanionPresenceMappingError.invalidPlaybackRate
        case .playing where playback.rate <= 0:
            throw CompanionPresenceMappingError.invalidPlaybackRate
        default:
            break
        }

        let durationMilliseconds = try playback.durationSeconds.map {
            try milliseconds(from: $0, field: "data.media.playback.durationMs")
        }
        var positionMilliseconds = try playback.positionSeconds.map {
            try milliseconds(from: $0, field: "data.media.playback.positionMs")
        }
        if let durationMilliseconds, let position = positionMilliseconds {
            positionMilliseconds = min(position, durationMilliseconds)
        }

        return CompanionMediaPlaybackV2(
            state: playback.state,
            durationMilliseconds: durationMilliseconds,
            positionMilliseconds: positionMilliseconds,
            sampledAt: playback.sampledAt,
            rate: playback.rate
        )
    }

    private func milliseconds(from seconds: Double, field: String) throws -> Int {
        guard seconds.isFinite, seconds >= 0 else {
            throw CompanionPresenceMappingError.invalidNumber(field: field)
        }
        let scaled = (seconds * 1_000).rounded()
        guard scaled <= Double(CompanionProtocolV2.maximumSafeInteger) else {
            throw CompanionPresenceMappingError.invalidNumber(field: field)
        }
        return Int(scaled)
    }

    private func validateIdentifier(_ value: String, field: String) throws {
        guard CompanionIdentifier.isValid(value) else {
            throw CompanionPresenceMappingError.invalidIdentifier(field: field)
        }
    }

    private func validateSequence(_ sequence: Int) throws {
        guard sequence >= 0, sequence <= CompanionProtocolV2.maximumSafeInteger else {
            throw CompanionPresenceMappingError.sequenceOutOfRange
        }
    }

    private func validateLength(_ value: String, field: String, maximum: Int) throws {
        guard value.unicodeScalars.count <= maximum else {
            throw CompanionPresenceMappingError.textTooLong(
                field: field,
                maximumUnicodeScalars: maximum
            )
        }
    }
}
