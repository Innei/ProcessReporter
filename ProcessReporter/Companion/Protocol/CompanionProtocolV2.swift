import Foundation

enum CompanionProtocolV2 {
    static let presenceSchema = "yohaku.companion.presence"
    static let presenceSchemaVersion = 2
    static let maximumSafeInteger = 9_007_199_254_740_991
}

enum CompanionProtocolDecodingError: Error, Equatable, Sendable {
    case incompatibleSchema
    case incompatibleSchemaVersion
    case invalidIdentifier(field: String)
    case invalidSafeInteger(field: String)
}

enum CompanionIdentifier {
    static func isValid(_ value: String) -> Bool {
        if UUID(uuidString: value) != nil {
            return true
        }
        return value.range(
            of: #"^[0-9A-HJKMNP-TV-Z]{26}$"#,
            options: .regularExpression
        ) != nil
    }
}

enum CompanionJSON {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(CompanionWireDate.string(from: date))
        }
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = CompanionWireDate.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an RFC 3339 UTC timestamp with milliseconds."
                )
            }
            return date
        }
        return decoder
    }
}

private enum CompanionWireDate {
    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    static func date(from value: String) -> Date? {
        guard value.range(
            of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#,
            options: .regularExpression
        ) != nil else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        guard let date = formatter.date(from: value), string(from: date) == value else {
            return nil
        }
        return date
    }
}

struct CompanionPresenceRequestMetaV2: Codable, Equatable, Sendable {
    let schema: String
    let schemaVersion: Int
    let requestID: String
    let deviceID: String
    let sequence: Int
    let observedAt: Date

    init(
        requestID: String,
        deviceID: String,
        sequence: Int,
        observedAt: Date
    ) {
        schema = CompanionProtocolV2.presenceSchema
        schemaVersion = CompanionProtocolV2.presenceSchemaVersion
        self.requestID = requestID
        self.deviceID = deviceID
        self.sequence = sequence
        self.observedAt = observedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case schemaVersion
        case requestID = "requestId"
        case deviceID = "deviceId"
        case sequence
        case observedAt
    }
}

struct CompanionLeaseV2: Codable, Equatable, Sendable {
    let ttlSeconds: Int
}

struct CompanionActivityV2: Codable, Equatable, Sendable {
    let key: String?
    let customLabel: String?

    init(key: String?, customLabel: String?) {
        self.key = key
        self.customLabel = customLabel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decodeRequiredNullable(String.self, forKey: .key)
        customLabel = try container.decodeRequiredNullable(String.self, forKey: .customLabel)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeNullable(key, forKey: .key)
        try container.encodeNullable(customLabel, forKey: .customLabel)
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case customLabel
    }
}

struct CompanionWindowV2: Codable, Equatable, Sendable {
    let title: String
}

struct CompanionIconV2: Codable, Equatable, Sendable {
    let url: String
}

struct CompanionPlayerV2: Codable, Equatable, Sendable {
    let displayName: String
}

struct CompanionApplicationContextV2: Codable, Equatable, Sendable {
    let displayName: String
    let activity: CompanionActivityV2?
    let window: CompanionWindowV2?
    let icon: CompanionIconV2?

    init(
        displayName: String,
        activity: CompanionActivityV2?,
        window: CompanionWindowV2?,
        icon: CompanionIconV2?
    ) {
        self.displayName = displayName
        self.activity = activity
        self.window = window
        self.icon = icon
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try container.decode(String.self, forKey: .displayName)
        activity = try container.decodeRequiredNullable(CompanionActivityV2.self, forKey: .activity)
        window = try container.decodeRequiredNullable(CompanionWindowV2.self, forKey: .window)
        icon = try container.decodeRequiredNullable(CompanionIconV2.self, forKey: .icon)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeNullable(activity, forKey: .activity)
        try container.encodeNullable(window, forKey: .window)
        try container.encodeNullable(icon, forKey: .icon)
    }

    private enum CodingKeys: String, CodingKey {
        case displayName
        case activity
        case window
        case icon
    }
}

struct CompanionMediaPlaybackV2: Codable, Equatable, Sendable {
    let state: CompanionMediaPlaybackState
    let durationMilliseconds: Int?
    let positionMilliseconds: Int?
    let sampledAt: Date
    let rate: Double

    init(
        state: CompanionMediaPlaybackState,
        durationMilliseconds: Int?,
        positionMilliseconds: Int?,
        sampledAt: Date,
        rate: Double
    ) {
        self.state = state
        self.durationMilliseconds = durationMilliseconds
        self.positionMilliseconds = positionMilliseconds
        self.sampledAt = sampledAt
        self.rate = rate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decode(CompanionMediaPlaybackState.self, forKey: .state)
        durationMilliseconds = try container.decodeRequiredNullable(
            Int.self,
            forKey: .durationMilliseconds
        )
        positionMilliseconds = try container.decodeRequiredNullable(
            Int.self,
            forKey: .positionMilliseconds
        )
        sampledAt = try container.decode(Date.self, forKey: .sampledAt)
        rate = try container.decode(Double.self, forKey: .rate)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(state, forKey: .state)
        try container.encodeNullable(durationMilliseconds, forKey: .durationMilliseconds)
        try container.encodeNullable(positionMilliseconds, forKey: .positionMilliseconds)
        try container.encode(sampledAt, forKey: .sampledAt)
        try container.encode(rate, forKey: .rate)
    }

    private enum CodingKeys: String, CodingKey {
        case state
        case durationMilliseconds = "durationMs"
        case positionMilliseconds = "positionMs"
        case sampledAt
        case rate
    }
}

struct CompanionMediaContextV2: Codable, Equatable, Sendable {
    let sessionID: String
    let kind: CompanionMediaKind
    let title: String?
    let artist: String?
    let album: String?
    let player: CompanionPlayerV2?
    let playback: CompanionMediaPlaybackV2

    init(
        sessionID: String,
        kind: CompanionMediaKind,
        title: String?,
        artist: String?,
        album: String?,
        player: CompanionPlayerV2?,
        playback: CompanionMediaPlaybackV2
    ) {
        self.sessionID = sessionID
        self.kind = kind
        self.title = title
        self.artist = artist
        self.album = album
        self.player = player
        self.playback = playback
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        kind = try container.decode(CompanionMediaKind.self, forKey: .kind)
        title = try container.decodeRequiredNullable(String.self, forKey: .title)
        artist = try container.decodeRequiredNullable(String.self, forKey: .artist)
        album = try container.decodeRequiredNullable(String.self, forKey: .album)
        player = try container.decodeRequiredNullable(CompanionPlayerV2.self, forKey: .player)
        playback = try container.decode(CompanionMediaPlaybackV2.self, forKey: .playback)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(kind, forKey: .kind)
        try container.encodeNullable(title, forKey: .title)
        try container.encodeNullable(artist, forKey: .artist)
        try container.encodeNullable(album, forKey: .album)
        try container.encodeNullable(player, forKey: .player)
        try container.encode(playback, forKey: .playback)
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case kind
        case title
        case artist
        case album
        case player
        case playback
    }
}

struct CompanionPresenceDataV2: Codable, Equatable, Sendable {
    let availability: LiveDeskAvailability
    let lease: CompanionLeaseV2
    let application: CompanionApplicationContextV2?
    let media: CompanionMediaContextV2?

    init(
        availability: LiveDeskAvailability,
        lease: CompanionLeaseV2,
        application: CompanionApplicationContextV2?,
        media: CompanionMediaContextV2?
    ) {
        self.availability = availability
        self.lease = lease
        self.application = application
        self.media = media
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        availability = try container.decode(LiveDeskAvailability.self, forKey: .availability)
        lease = try container.decode(CompanionLeaseV2.self, forKey: .lease)
        application = try container.decodeRequiredNullable(
            CompanionApplicationContextV2.self,
            forKey: .application
        )
        media = try container.decodeRequiredNullable(CompanionMediaContextV2.self, forKey: .media)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(availability, forKey: .availability)
        try container.encode(lease, forKey: .lease)
        try container.encodeNullable(application, forKey: .application)
        try container.encodeNullable(media, forKey: .media)
    }

    private enum CodingKeys: String, CodingKey {
        case availability
        case lease
        case application
        case media
    }
}

struct CompanionPresenceRequestV2: Codable, Equatable, Sendable {
    let meta: CompanionPresenceRequestMetaV2
    let data: CompanionPresenceDataV2
}

enum CompanionPresenceClearReasonV2: String, Codable, Sendable {
    case paused
    case sleep
    case shutdown
    case privacyChanged
    case connectionRemoved
}

struct CompanionPresenceClearDataV2: Codable, Equatable, Sendable {
    let reason: CompanionPresenceClearReasonV2
}

struct CompanionPresenceClearRequestV2: Codable, Equatable, Sendable {
    let meta: CompanionPresenceRequestMetaV2
    let data: CompanionPresenceClearDataV2
}

struct CompanionResponseMetaV2: Decodable, Equatable, Sendable {
    let schema: String
    let schemaVersion: Int
    let requestID: String
    let serverTime: Date

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(String.self, forKey: .schema)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        requestID = try container.decode(String.self, forKey: .requestID)
        serverTime = try container.decode(Date.self, forKey: .serverTime)

        guard schema == CompanionProtocolV2.presenceSchema else {
            throw CompanionProtocolDecodingError.incompatibleSchema
        }
        guard schemaVersion == CompanionProtocolV2.presenceSchemaVersion else {
            throw CompanionProtocolDecodingError.incompatibleSchemaVersion
        }
        guard CompanionIdentifier.isValid(requestID) else {
            throw CompanionProtocolDecodingError.invalidIdentifier(field: "meta.requestId")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case schemaVersion
        case requestID = "requestId"
        case serverTime
    }
}

protocol CompanionResponseEnvelopeV2: Decodable, Sendable {
    var meta: CompanionResponseMetaV2 { get }
}

struct PublicMediaPlaybackV2: Decodable, Equatable, Sendable {
    let state: CompanionMediaPlaybackState
    let durationMilliseconds: Int?
    let positionMilliseconds: Int?
    let anchorAt: Date
    let rate: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decode(CompanionMediaPlaybackState.self, forKey: .state)
        durationMilliseconds = try container.decodeRequiredNullable(
            Int.self,
            forKey: .durationMilliseconds
        )
        positionMilliseconds = try container.decodeRequiredNullable(
            Int.self,
            forKey: .positionMilliseconds
        )
        anchorAt = try container.decode(Date.self, forKey: .anchorAt)
        rate = try container.decode(Double.self, forKey: .rate)
    }

    private enum CodingKeys: String, CodingKey {
        case state
        case durationMilliseconds = "durationMs"
        case positionMilliseconds = "positionMs"
        case anchorAt
        case rate
    }
}

struct PublicMediaPresenceV2: Decodable, Equatable, Sendable {
    let sessionID: String
    let kind: CompanionMediaKind
    let title: String?
    let artist: String?
    let album: String?
    let player: CompanionPlayerV2?
    let playback: PublicMediaPlaybackV2

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        kind = try container.decode(CompanionMediaKind.self, forKey: .kind)
        title = try container.decodeRequiredNullable(String.self, forKey: .title)
        artist = try container.decodeRequiredNullable(String.self, forKey: .artist)
        album = try container.decodeRequiredNullable(String.self, forKey: .album)
        player = try container.decodeRequiredNullable(CompanionPlayerV2.self, forKey: .player)
        playback = try container.decode(PublicMediaPlaybackV2.self, forKey: .playback)

        guard CompanionIdentifier.isValid(sessionID) else {
            throw CompanionProtocolDecodingError.invalidIdentifier(
                field: "data.state.projection.media.sessionId"
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case kind
        case title
        case artist
        case album
        case player
        case playback
    }
}

struct PublicLiveDeskProjectionV2: Decodable, Equatable, Sendable {
    let availability: LiveDeskAvailability
    let updatedAt: Date
    let expiresAt: Date
    let application: CompanionApplicationContextV2?
    let media: PublicMediaPresenceV2?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        availability = try container.decode(LiveDeskAvailability.self, forKey: .availability)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        application = try container.decodeRequiredNullable(
            CompanionApplicationContextV2.self,
            forKey: .application
        )
        media = try container.decodeRequiredNullable(PublicMediaPresenceV2.self, forKey: .media)
    }

    private enum CodingKeys: String, CodingKey {
        case availability
        case updatedAt
        case expiresAt
        case application
        case media
    }
}

struct PublicLiveDeskStateV2: Decodable, Equatable, Sendable {
    let schemaVersion: Int
    let epoch: String
    let revision: Int
    let projection: PublicLiveDeskProjectionV2?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        epoch = try container.decode(String.self, forKey: .epoch)
        revision = try container.decode(Int.self, forKey: .revision)
        projection = try container.decodeRequiredNullable(
            PublicLiveDeskProjectionV2.self,
            forKey: .projection
        )

        guard schemaVersion == CompanionProtocolV2.presenceSchemaVersion else {
            throw CompanionProtocolDecodingError.incompatibleSchemaVersion
        }
        guard CompanionIdentifier.isValid(epoch) else {
            throw CompanionProtocolDecodingError.invalidIdentifier(field: "data.state.epoch")
        }
        guard revision >= 0, revision <= CompanionProtocolV2.maximumSafeInteger else {
            throw CompanionProtocolDecodingError.invalidSafeInteger(
                field: "data.state.revision"
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case epoch
        case revision
        case projection
    }
}

struct CompanionPresenceMutationDataV2: Decodable, Equatable, Sendable {
    let acceptedSequence: Int
    let receivedAt: Date
    let state: PublicLiveDeskStateV2

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        acceptedSequence = try container.decode(Int.self, forKey: .acceptedSequence)
        receivedAt = try container.decode(Date.self, forKey: .receivedAt)
        state = try container.decode(PublicLiveDeskStateV2.self, forKey: .state)

        guard
            acceptedSequence >= 0,
            acceptedSequence <= CompanionProtocolV2.maximumSafeInteger
        else {
            throw CompanionProtocolDecodingError.invalidSafeInteger(
                field: "data.acceptedSequence"
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case acceptedSequence
        case receivedAt
        case state
    }
}

struct CompanionPresenceMutationResponseV2: Decodable, Equatable, Sendable {
    let meta: CompanionResponseMetaV2
    let data: CompanionPresenceMutationDataV2
}

extension CompanionPresenceMutationResponseV2: CompanionResponseEnvelopeV2 {}

struct CompanionPublicPresenceDataV2: Decodable, Equatable, Sendable {
    let state: PublicLiveDeskStateV2
}

struct CompanionPublicPresenceResponseV2: Decodable, Equatable, Sendable {
    let meta: CompanionResponseMetaV2
    let data: CompanionPublicPresenceDataV2
}

extension CompanionPublicPresenceResponseV2: CompanionResponseEnvelopeV2 {}

struct CompanionAPIErrorV2: Decodable, Equatable, Sendable {
    let code: String
    let message: String
    let retryable: Bool
    let retryAfterMilliseconds: Int?
    let acceptedSequence: Int?
    let fields: [String]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(String.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
        retryable = try container.decode(Bool.self, forKey: .retryable)
        retryAfterMilliseconds = try container.decodeRequiredNullable(
            Int.self,
            forKey: .retryAfterMilliseconds
        )
        acceptedSequence = try container.decodeRequiredNullable(
            Int.self,
            forKey: .acceptedSequence
        )
        fields = try container.decode([String].self, forKey: .fields)

        if let retryAfterMilliseconds {
            guard
                retryAfterMilliseconds >= 0,
                retryAfterMilliseconds <= CompanionProtocolV2.maximumSafeInteger
            else {
                throw CompanionProtocolDecodingError.invalidSafeInteger(
                    field: "error.retryAfterMs"
                )
            }
        }
        if let acceptedSequence {
            guard
                acceptedSequence >= 0,
                acceptedSequence <= CompanionProtocolV2.maximumSafeInteger
            else {
                throw CompanionProtocolDecodingError.invalidSafeInteger(
                    field: "error.acceptedSequence"
                )
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case message
        case retryable
        case retryAfterMilliseconds = "retryAfterMs"
        case acceptedSequence
        case fields
    }
}

struct CompanionErrorResponseV2: Decodable, Equatable, Sendable {
    let meta: CompanionResponseMetaV2
    let error: CompanionAPIErrorV2
}

struct CompanionCapabilitiesV2: Decodable, Equatable, Sendable {
    struct Features: Decodable, Equatable, Sendable {
        let liveDesk: Bool
        let mediaTimeline: Bool
        let moments: Bool
        let readingSessions: Bool
    }

    struct Limits: Decodable, Equatable, Sendable {
        let presencePayloadBytes: Int
        let presenceRequestsPerMinute: Int
        let presenceLeaseMinSeconds: Int
        let presenceLeaseMaxSeconds: Int
        let recommendedHeartbeatSeconds: Int
        let maximumClockSkewSeconds: Int
    }

    let minimumClientVersion: String
    let presenceSchemaVersions: [Int]
    let momentSchemaVersions: [Int]
    let features: Features
    let limits: Limits
}

struct CompanionCapabilitiesResponseV2: Decodable, Equatable, Sendable {
    let meta: CompanionResponseMetaV2
    let data: CompanionCapabilitiesV2
}

extension CompanionCapabilitiesResponseV2: CompanionResponseEnvelopeV2 {}

private extension KeyedEncodingContainer {
    mutating func encodeNullable<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let value {
            try encode(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }
}

private extension KeyedDecodingContainer {
    func decodeRequiredNullable<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        guard contains(key) else {
            throw DecodingError.keyNotFound(
                key,
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Required nullable key is missing."
                )
            )
        }
        if try decodeNil(forKey: key) {
            return nil
        }
        return try decode(type, forKey: key)
    }
}
