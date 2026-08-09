import Foundation

private enum HarnessFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case .assertion(let message):
            return message
        }
    }
}

@main
private struct CompanionProtocolV2Harness {
    private static let deviceID = "01K0A4VDWYSH1JQH4PGY4QM8YT"
    private static let epoch = "01K0A5P1KD0QAFMZKVFNFC7AFN"

    private static func requestID(_ value: Int) -> String {
        String(format: "00000000-0000-4000-8000-%012d", value)
    }

    static func main() async throws {
        try verifiesExplicitNullForIdleSnapshot()
        try verifiesNestedNullableKeysAndNormalization()
        try verifiesMillisecondsAndPositionClamp()
        try verifiesInvalidPlaybackIsRejected()
        try verifiesUnapprovedIconHostIsRejected()
        try verifiesPublicStateRequiresNullableKeys()
        try verifiesResponseSchemaAndOrderingValuesAreValidated()
        try verifiesWireDatesRequireCanonicalMilliseconds()
        try verifiesCapabilitiesFailClosedAndRespectMinimumVersion()
        try await verifiesMediaSessionIdentityContinuity()
        try await verifiesSequenceReservationsAreDurableAndUnique()
        try await verifiesMismatchedResponseRequestIDIsRejected()
        try await verifiesAmbiguousTransportRetryReusesExactRequest()
        try await verifiesImmediateWakeRetainsTheOrderedPresenceAuthority()
        try await verifiesBoundedClearReturnsWhenTheRequestFinishes()
        try verifiesSchemaRejectionForcesCapabilityRefresh()
        print("Companion Protocol v2 behavior passed")
    }

    private static func verifiesExplicitNullForIdleSnapshot() throws {
        let mapper = CompanionPresenceDTOMapper()
        let request = try mapper.makePresenceRequest(
            snapshot: SanitizedPresenceSnapshot(
                observedAt: Date(timeIntervalSince1970: 1_721_131_200),
                application: nil,
                media: nil
            ),
            deviceID: deviceID,
            sequence: 1,
            requestID: requestID(1)
        )

        let object = try jsonObject(request)
        let data = try dictionary(object["data"], path: "data")
        let meta = try dictionary(object["meta"], path: "meta")
        try expect(data["availability"] as? String == "idle", "idle availability was not encoded")
        try expect(data.keys.contains("application"), "application key was omitted")
        try expect(data["application"] is NSNull, "application was not encoded as null")
        try expect(data.keys.contains("media"), "media key was omitted")
        try expect(data["media"] is NSNull, "media was not encoded as null")
        try expect(object["key"] == nil, "legacy credential key leaked into the request")
        try expect(object["process"] == nil, "legacy process payload leaked into the request")
        let observedAt = meta["observedAt"] as? String ?? ""
        try expect(
            observedAt.range(of: #"\.\d{3}Z$"#, options: .regularExpression) != nil,
            "observedAt did not retain RFC 3339 milliseconds"
        )
    }

    private static func verifiesNestedNullableKeysAndNormalization() throws {
        let application = try SanitizedApplicationPresence(
            displayName: "  Cafe\u{301}  ",
            activity: SanitizedApplicationActivity(key: nil, customLabel: nil),
            windowTitle: "  \n",
            iconURL: nil
        )
        let request = try CompanionPresenceDTOMapper().makePresenceRequest(
            snapshot: SanitizedPresenceSnapshot(
                observedAt: Date(timeIntervalSince1970: 1_721_131_200),
                application: application,
                media: nil
            ),
            deviceID: deviceID,
            sequence: 2,
            requestID: requestID(2)
        )

        let object = try jsonObject(request)
        let data = try dictionary(object["data"], path: "data")
        let encodedApplication = try dictionary(data["application"], path: "data.application")
        let activity = try dictionary(
            encodedApplication["activity"],
            path: "data.application.activity"
        )
        try expect(encodedApplication["displayName"] as? String == "Café", "text was not NFC-normalized")
        try expect(encodedApplication["window"] is NSNull, "empty window title was not encoded as null")
        try expect(encodedApplication["icon"] is NSNull, "icon key was omitted or non-null")
        try expect(activity["key"] is NSNull, "activity.key was not encoded as null")
        try expect(activity["customLabel"] is NSNull, "activity.customLabel was not encoded as null")
    }

    private static func verifiesMillisecondsAndPositionClamp() throws {
        let media = try SanitizedMediaPresence(
            sessionID: UUID(uuidString: "98A80CCB-1B86-4D21-A1AB-91D53D287A41")!,
            kind: .music,
            title: "Track",
            artist: nil,
            album: nil,
            playerDisplayName: nil,
            playback: SanitizedMediaPlayback(
                state: .playing,
                durationSeconds: 203,
                positionSeconds: 205.6,
                sampledAt: Date(timeIntervalSince1970: 1_721_131_199.6),
                rate: 1
            )
        )
        let request = try CompanionPresenceDTOMapper().makePresenceRequest(
            snapshot: SanitizedPresenceSnapshot(
                observedAt: Date(timeIntervalSince1970: 1_721_131_200),
                application: nil,
                media: media
            ),
            deviceID: deviceID,
            sequence: 3,
            requestID: requestID(3)
        )

        let object = try jsonObject(request)
        let data = try dictionary(object["data"], path: "data")
        let encodedMedia = try dictionary(data["media"], path: "data.media")
        let playback = try dictionary(encodedMedia["playback"], path: "data.media.playback")
        try expect(playback["durationMs"] as? Int == 203_000, "duration was not converted to milliseconds")
        try expect(playback["positionMs"] as? Int == 203_000, "position was not clamped to duration")
        try expect(encodedMedia.keys.contains("artist"), "nullable artist key was omitted")
        try expect(encodedMedia["artist"] is NSNull, "nullable artist was not encoded as null")
    }

    private static func verifiesInvalidPlaybackIsRejected() throws {
        let media = try SanitizedMediaPresence(
            sessionID: UUID(),
            kind: .unknown,
            title: nil,
            artist: "Artist",
            album: nil,
            playerDisplayName: nil,
            playback: SanitizedMediaPlayback(
                state: .paused,
                durationSeconds: nil,
                positionSeconds: .nan,
                sampledAt: .now,
                rate: 1
            )
        )

        do {
            _ = try CompanionPresenceDTOMapper().makePresenceRequest(
                snapshot: SanitizedPresenceSnapshot(
                    observedAt: .now,
                    application: nil,
                    media: media
                ),
                deviceID: deviceID,
                sequence: 4,
                requestID: requestID(4)
            )
            throw HarnessFailure.assertion("invalid paused playback was accepted")
        } catch CompanionPresenceMappingError.invalidPlaybackRate {
            return
        }
    }

    private static func verifiesUnapprovedIconHostIsRejected() throws {
        let application = try SanitizedApplicationPresence(
            displayName: "Xcode",
            iconURL: URL(string: "https://tracker.example/icon.png")
        )
        do {
            _ = try CompanionPresenceDTOMapper(allowedAssetHosts: ["assets.example.com"])
                .makePresenceRequest(
                    snapshot: SanitizedPresenceSnapshot(
                        observedAt: .now,
                        application: application,
                        media: nil
                    ),
                    deviceID: deviceID,
                    sequence: 5,
                    requestID: requestID(5)
                )
            throw HarnessFailure.assertion("unapproved icon host was accepted")
        } catch CompanionPresenceMappingError.invalidIconURL {
            return
        }
    }

    private static func verifiesPublicStateRequiresNullableKeys() throws {
        let validEmptyState = """
        {
          "schemaVersion": 2,
          "epoch": "\(epoch)",
          "revision": 1,
          "projection": null
        }
        """
        let decoded = try CompanionJSON.makeDecoder().decode(
            PublicLiveDeskStateV2.self,
            from: Data(validEmptyState.utf8)
        )
        try expect(decoded.projection == nil, "projection null did not decode")

        let missingProjection = """
        {
          "schemaVersion": 2,
          "epoch": "\(epoch)",
          "revision": 1
        }
        """
        do {
            _ = try CompanionJSON.makeDecoder().decode(
                PublicLiveDeskStateV2.self,
                from: Data(missingProjection.utf8)
            )
            throw HarnessFailure.assertion("missing projection key was accepted")
        } catch DecodingError.keyNotFound {
            return
        }
    }

    private static func verifiesResponseSchemaAndOrderingValuesAreValidated() throws {
        let unsupportedSchema = """
        {
          "meta": {
            "schema": "yohaku.companion.presence",
            "schemaVersion": 3,
            "requestId": "\(requestID(40))",
            "serverTime": "2026-07-16T12:00:00.180Z"
          },
          "data": {
            "acceptedSequence": 40,
            "receivedAt": "2026-07-16T12:00:00.180Z",
            "state": {
              "schemaVersion": 2,
              "epoch": "\(epoch)",
              "revision": 1,
              "projection": null
            }
          }
        }
        """
        do {
            _ = try CompanionJSON.makeDecoder().decode(
                CompanionPresenceMutationResponseV2.self,
                from: Data(unsupportedSchema.utf8)
            )
            throw HarnessFailure.assertion("unsupported response schema version was accepted")
        } catch CompanionProtocolDecodingError.incompatibleSchemaVersion {
            // Expected.
        }

        let invalidRevision = """
        {
          "schemaVersion": 2,
          "epoch": "\(epoch)",
          "revision": -1,
          "projection": null
        }
        """
        do {
            _ = try CompanionJSON.makeDecoder().decode(
                PublicLiveDeskStateV2.self,
                from: Data(invalidRevision.utf8)
            )
            throw HarnessFailure.assertion("negative public revision was accepted")
        } catch CompanionProtocolDecodingError.invalidSafeInteger {
            // Expected.
        }
    }

    private static func verifiesWireDatesRequireCanonicalMilliseconds() throws {
        let missingMilliseconds = """
        {
          "schemaVersion": 2,
          "epoch": "\(epoch)",
          "revision": 1,
          "projection": {
            "availability": "idle",
            "updatedAt": "2026-07-16T12:00:00Z",
            "expiresAt": "2026-07-16T12:01:30.000Z",
            "application": null,
            "media": null
          }
        }
        """
        do {
            _ = try CompanionJSON.makeDecoder().decode(
                PublicLiveDeskStateV2.self,
                from: Data(missingMilliseconds.utf8)
            )
            throw HarnessFailure.assertion("non-canonical wire timestamp was accepted")
        } catch DecodingError.dataCorrupted {
            // Expected.
        }
    }

    private static func verifiesCapabilitiesFailClosedAndRespectMinimumVersion() throws {
        let limits = CompanionCapabilitiesV2.Limits(
            presencePayloadBytes: 32_768,
            presenceRequestsPerMinute: 30,
            presenceLeaseMinSeconds: 30,
            presenceLeaseMaxSeconds: 120,
            recommendedHeartbeatSeconds: 30,
            maximumClockSkewSeconds: 30
        )
        let available = CompanionCapabilitiesV2(
            minimumClientVersion: "1.7.3",
            presenceSchemaVersions: [2],
            momentSchemaVersions: [],
            features: CompanionCapabilitiesV2.Features(
                liveDesk: true,
                mediaTimeline: true,
                moments: false,
                readingSessions: false
            ),
            limits: limits
        )
        let result = CompanionCapabilityNegotiator.negotiatePresence(
            available,
            clientVersion: "1.8.0"
        )
        guard case .available(let configuration) = result else {
            throw HarnessFailure.assertion("compatible capabilities were rejected")
        }
        try expect(configuration.maximumPayloadBytes == 32_768, "payload limit was lost")
        try expect(configuration.supportsMediaTimeline, "media timeline flag was lost")

        let updateRequired = CompanionCapabilityNegotiator.negotiatePresence(
            available,
            clientVersion: "1.7.3-beta.1"
        )
        try expect(
            updateRequired == .clientUpdateRequired(minimumVersion: "1.7.3"),
            "prerelease client bypassed the minimum stable version"
        )

        let disabled = CompanionCapabilitiesV2(
            minimumClientVersion: "1.7.3",
            presenceSchemaVersions: [2],
            momentSchemaVersions: [],
            features: CompanionCapabilitiesV2.Features(
                liveDesk: false,
                mediaTimeline: false,
                moments: false,
                readingSessions: false
            ),
            limits: limits
        )
        try expect(
            CompanionCapabilityNegotiator.negotiatePresence(
                disabled,
                clientVersion: "1.7.3"
            ) == .featureUnavailable,
            "disabled server feature was treated as available"
        )
    }

    private static func verifiesSequenceReservationsAreDurableAndUnique() async throws {
        let persistence = InMemorySequencePersistence()
        let sequencer = CompanionPresenceSequencer(
            deviceID: deviceID,
            pairingNextSequence: 20,
            persistence: persistence
        )
        let values = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<12 {
                group.addTask { try await sequencer.reserve() }
            }
            var values: [Int] = []
            for try await value in group {
                values.append(value)
            }
            return values.sorted()
        }
        try expect(values == Array(20..<32), "concurrent reservations reused or skipped a sequence")
        let persisted = await persistence.loadNextSequence(for: deviceID)
        try expect(persisted == 32, "next sequence was not persisted before completion")

        try await sequencer.reconcile(acceptedSequence: 50)
        let afterReconcile = try await sequencer.reserve()
        try expect(afterReconcile == 51, "server accepted sequence was not reconciled")
        let reconciledPersisted = await persistence.loadNextSequence(for: deviceID)
        try expect(reconciledPersisted == 52, "reconciled sequence was not persisted")
    }

    private static func verifiesMediaSessionIdentityContinuity() async throws {
        let tracker = CompanionMediaSessionTracker()
        let identity = CompanionMediaSemanticIdentity(
            kind: .music,
            title: "Track",
            artist: "Artist",
            album: "Album",
            playerDisplayName: "Music",
            durationSeconds: 203
        )
        let first = await tracker.sessionID(for: identity)
        let afterSeekOrPause = await tracker.sessionID(for: identity)
        try expect(first == afterSeekOrPause, "seek or pause would rotate the media session ID")

        let changedTrack = CompanionMediaSemanticIdentity(
            kind: .music,
            title: "Next Track",
            artist: "Artist",
            album: "Album",
            playerDisplayName: "Music",
            durationSeconds: 203
        )
        let second = await tracker.sessionID(for: changedTrack)
        try expect(first != second, "changed media identity reused the previous session ID")

        await tracker.reset()
        let afterDiscontinuity = await tracker.sessionID(for: changedTrack)
        try expect(second != afterDiscontinuity, "provider discontinuity did not rotate session ID")
    }

    private static func verifiesAmbiguousTransportRetryReusesExactRequest() async throws {
        let responseJSON = """
        {
          "meta": {
            "schema": "yohaku.companion.presence",
            "schemaVersion": 2,
            "requestId": "\(requestID(40))",
            "serverTime": "2026-07-16T12:00:00.180Z"
          },
          "data": {
            "acceptedSequence": 40,
            "receivedAt": "2026-07-16T12:00:00.180Z",
            "state": {
              "schemaVersion": 2,
              "epoch": "\(epoch)",
              "revision": 1,
              "projection": null
            }
          }
        }
        """
        let transport = RetryRecordingTransport(responseBody: Data(responseJSON.utf8))
        let server = try CompanionServerConfiguration(
            baseURL: URL(string: "https://example.com/api/v3")!
        )
        let httpClient = CompanionHTTPClient(
            server: server,
            transport: transport,
            clientVersion: "1.7.3"
        )
        let credential = try CompanionDeviceCredential(
            deviceID: deviceID,
            token: "secret-token"
        )
        let sequencer = CompanionPresenceSequencer(
            deviceID: credential.deviceID,
            pairingNextSequence: 40,
            persistence: InMemorySequencePersistence()
        )
        let client = YohakuPresenceClient(
            credential: credential,
            mapper: CompanionPresenceDTOMapper(),
            httpClient: httpClient,
            sequencer: sequencer
        )

        _ = try await client.replacePresence(
            with: SanitizedPresenceSnapshot(
                observedAt: Date(timeIntervalSince1970: 1_721_131_200),
                application: nil,
                media: nil
            )
        )
        let requests = await transport.recordedRequests()
        try expect(requests.count == 2, "ambiguous transport failure was not retried once")
        try expect(requests[0].httpBody == requests[1].httpBody, "retry changed the request body")
        try expect(
            requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer secret-token",
            "Device Token was not sent in the Authorization header"
        )
        try expect(
            requests.allSatisfy {
                $0.value(forHTTPHeaderField: CompanionClientVersion.headerName) == "1.7.3"
            },
            "Presence mutation omitted or changed the Companion version header"
        )
        let body = try JSONSerialization.jsonObject(with: requests[0].httpBody ?? Data())
        let object = try dictionary(body, path: "retry request")
        let meta = try dictionary(object["meta"], path: "retry request.meta")
        try expect(meta["sequence"] as? Int == 40, "retry did not preserve the sequence")
        try expect(meta["requestId"] != nil, "retry request ID was omitted")
        try expect(object["key"] == nil, "Device Token leaked into the JSON body")
    }

    private static func verifiesImmediateWakeRetainsTheOrderedPresenceAuthority() async throws {
        let transport = BlockingOrderedTransport()
        let server = try CompanionServerConfiguration(
            baseURL: URL(string: "https://example.com/api/v3")!
        )
        let credential = try CompanionDeviceCredential(
            deviceID: deviceID,
            token: "sleep-wake-token"
        )
        let activeClient = YohakuPresenceClient(
            credential: credential,
            mapper: CompanionPresenceDTOMapper(),
            httpClient: CompanionHTTPClient(
                server: server,
                transport: transport,
                clientVersion: "1.7.3"
            ),
            sequencer: CompanionPresenceSequencer(
                deviceID: deviceID,
                pairingNextSequence: 70,
                persistence: InMemorySequencePersistence()
            )
        )
        let replacementClient = YohakuPresenceClient(
            credential: credential,
            mapper: CompanionPresenceDTOMapper(),
            httpClient: CompanionHTTPClient(
                server: server,
                transport: StaticResponseTransport(responseBody: Data()),
                clientVersion: "1.7.3"
            ),
            sequencer: CompanionPresenceSequencer(
                deviceID: deviceID,
                pairingNextSequence: 70,
                persistence: InMemorySequencePersistence()
            )
        )
        let registry = await MainActor.run { CompanionPresenceAuthorityRegistry() }
        let key = CompanionPresenceAuthorityKey(baseURL: server.baseURL, deviceID: deviceID)
        let sleepAuthority = await MainActor.run {
            registry.resolve(for: key) { activeClient }
        }

        let cleanupStartGate = HarnessGate()
        let cleanupTask = Task {
            await cleanupStartGate.wait()
            await CompanionPresenceCleanup.clearBestEffort(
                using: sleepAuthority,
                reason: .sleep,
                timeout: .milliseconds(500)
            )
        }
        // Deliberately launch wake while cleanup is prevented from scheduling.
        // The explicit join must keep configuration/snapshot work behind the
        // cleanup task rather than relying on actor enqueue order.
        let wakeTask = Task {
            await cleanupTask.value
            let wakeAuthority = await MainActor.run {
                registry.resolve(for: key) { replacementClient }
            }
            return try await wakeAuthority.replacePresence(
                with: SanitizedPresenceSnapshot(
                    observedAt: Date(timeIntervalSince1970: 1_721_131_200),
                    application: nil,
                    media: nil
                ),
                requestedLeaseSeconds: 90
            )
        }
        for _ in 0..<100 {
            await Task.yield()
        }
        let beforeCleanupWasReleased = await transport.recordedMutations()
        try expect(
            beforeCleanupWasReleased.isEmpty,
            "wake snapshot ran before the cleanup task was allowed to schedule"
        )

        await cleanupStartGate.open()
        await transport.waitUntilFirstRequestStarts()
        for _ in 0..<100 {
            await Task.yield()
        }
        let beforeRelease = await transport.recordedMutations()
        try expect(
            beforeRelease.count == 1 && beforeRelease[0].path.hasSuffix("/presence/clear"),
            "wake snapshot crossed the sleep clear barrier"
        )

        await transport.releaseFirstRequest()
        _ = try await wakeTask.value

        let mutations = await transport.recordedMutations()
        try expect(
            mutations.map(\.sequence) == [70, 71],
            "sleep and wake mutations did not share one monotonic sequencer"
        )
        try expect(
            mutations.map(\.path).map { $0.hasSuffix("/presence/clear") ? "clear" : "replace" }
                == ["clear", "replace"],
            "wake snapshot was not ordered after sleep clear"
        )
        try expect(
            mutations.allSatisfy { $0.clientVersion == "1.7.3" },
            "clear or wake snapshot omitted the Companion version header"
        )
        let retainedAuthority = await MainActor.run {
            registry.resolve(for: key) { replacementClient }
        }
        try expect(
            (sleepAuthority as AnyObject) === (retainedAuthority as AnyObject),
            "immediate wake replaced the paired device authority"
        )
    }

    private static func verifiesBoundedClearReturnsWhenTheRequestFinishes() async throws {
        let clock = ContinuousClock()
        let startedAt = clock.now
        await CompanionPresenceCleanup.clearBestEffort(
            using: ImmediatelyFinishingPresenceSender(),
            reason: .sleep,
            timeout: .milliseconds(500)
        )
        let elapsed = startedAt.duration(to: clock.now)
        try expect(
            elapsed < .milliseconds(400),
            "completed clear waited for the full timeout"
        )
    }

    private static func verifiesSchemaRejectionForcesCapabilityRefresh() throws {
        let responseJSON = """
        {
          "meta": {
            "schema": "yohaku.companion.presence",
            "schemaVersion": 2,
            "requestId": "\(requestID(91))",
            "serverTime": "2026-07-16T12:00:00.180Z"
          },
          "error": {
            "code": "COMPANION_SCHEMA_UNSUPPORTED",
            "message": "Refresh capabilities.",
            "retryable": false,
            "retryAfterMs": null,
            "acceptedSequence": null,
            "fields": []
          }
        }
        """
        let decodedResponse = try CompanionJSON.makeDecoder().decode(
            CompanionErrorResponseV2.self,
            from: Data(responseJSON.utf8)
        )
        try expect(
            CompanionPresenceMutationFailurePolicy.action(
                for: CompanionHTTPClientError.server(
                    statusCode: 426,
                    response: decodedResponse
                )
            ) == .refreshCapabilities,
            "schema error envelope degraded without capability refresh"
        )
        let featureResponse = try CompanionJSON.makeDecoder().decode(
            CompanionErrorResponseV2.self,
            from: Data(
                responseJSON.replacingOccurrences(
                    of: "COMPANION_SCHEMA_UNSUPPORTED",
                    with: "COMPANION_FEATURE_UNAVAILABLE"
                ).utf8
            )
        )
        try expect(
            CompanionPresenceMutationFailurePolicy.action(
                for: CompanionHTTPClientError.server(
                    statusCode: 503,
                    response: featureResponse
                )
            ) == .refreshCapabilities,
            "feature-unavailable mutation degraded without capability refresh"
        )
        try expect(
            CompanionPresenceMutationFailurePolicy.action(
                for: CompanionHTTPClientError.server(statusCode: 426, response: nil)
            ) == .refreshCapabilities,
            "undecodable 426 degraded without capability refresh"
        )
        try expect(
            CompanionPresenceMutationFailurePolicy.action(
                for: CompanionHTTPClientError.server(statusCode: 503, response: nil)
            ) == .degrade,
            "ordinary server failure discarded the negotiated authority"
        )
    }

    private static func verifiesMismatchedResponseRequestIDIsRejected() async throws {
        let responseJSON = """
        {
          "meta": {
            "schema": "yohaku.companion.presence",
            "schemaVersion": 2,
            "requestId": "\(requestID(81))",
            "serverTime": "2026-07-16T12:00:00.180Z"
          },
          "data": {
            "acceptedSequence": 80,
            "receivedAt": "2026-07-16T12:00:00.180Z",
            "state": {
              "schemaVersion": 2,
              "epoch": "\(epoch)",
              "revision": 1,
              "projection": null
            }
          }
        }
        """
        let transport = StaticResponseTransport(responseBody: Data(responseJSON.utf8))
        let httpClient = CompanionHTTPClient(
            server: try CompanionServerConfiguration(
                baseURL: URL(string: "https://example.com/api/v3")!
            ),
            transport: transport
        )
        let credential = try CompanionDeviceCredential(
            deviceID: deviceID,
            token: "secret-token"
        )
        let request = try CompanionPresenceDTOMapper().makePresenceRequest(
            snapshot: SanitizedPresenceSnapshot(
                observedAt: Date(timeIntervalSince1970: 1_721_131_200),
                application: nil,
                media: nil
            ),
            deviceID: deviceID,
            sequence: 80,
            requestID: requestID(80)
        )

        do {
            _ = try await httpClient.replacePresence(request, credential: credential)
            throw HarnessFailure.assertion("mismatched response request ID was accepted")
        } catch CompanionHTTPClientError.responseRequestIDMismatch {
            // Expected.
        }
    }

    private static func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let encoded = try CompanionJSON.makeEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: encoded)
        return try dictionary(object, path: "root")
    }

    private static func dictionary(_ value: Any?, path: String) throws -> [String: Any] {
        guard let dictionary = value as? [String: Any] else {
            throw HarnessFailure.assertion("\(path) was not a JSON object")
        }
        return dictionary
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw HarnessFailure.assertion(message) }
    }
}

private actor InMemorySequencePersistence: CompanionSequencePersistence {
    private var values: [String: Int] = [:]

    func loadNextSequence(for deviceID: String) -> Int? {
        values[deviceID]
    }

    func storeNextSequence(_ sequence: Int, for deviceID: String) {
        values[deviceID] = sequence
    }

    func removeSequence(for deviceID: String) {
        values.removeValue(forKey: deviceID)
    }
}

private actor RetryRecordingTransport: CompanionHTTPTransport {
    private let responseBody: Data
    private var requests: [URLRequest] = []

    init(responseBody: Data) {
        self.responseBody = responseBody
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if requests.count == 1 {
            throw URLError(.timedOut)
        }
        guard let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            throw HarnessFailure.assertion("could not construct HTTP response")
        }
        return (try correlatedResponseBody(for: request), response)
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }

    private func correlatedResponseBody(for request: URLRequest) throws -> Data {
        guard
            let requestBody = request.httpBody,
            let requestObject = try JSONSerialization.jsonObject(with: requestBody)
                as? [String: Any],
            let requestMeta = requestObject["meta"] as? [String: Any],
            let requestID = requestMeta["requestId"] as? String,
            var responseObject = try JSONSerialization.jsonObject(with: responseBody)
                as? [String: Any],
            var responseMeta = responseObject["meta"] as? [String: Any]
        else {
            throw HarnessFailure.assertion("could not correlate retry response request ID")
        }
        responseMeta["requestId"] = requestID
        responseObject["meta"] = responseMeta
        return try JSONSerialization.data(withJSONObject: responseObject, options: [.sortedKeys])
    }
}

private actor BlockingOrderedTransport: CompanionHTTPTransport {
    struct Mutation: Sendable {
        let path: String
        let sequence: Int
        let clientVersion: String?
    }

    private var mutations: [Mutation] = []
    private var firstRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstRequestContinuation: CheckedContinuation<Void, Never>?

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let body = request.httpBody,
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let meta = object["meta"] as? [String: Any],
              let sequence = meta["sequence"] as? Int,
              let requestID = meta["requestId"] as? String,
              let url = request.url
        else {
            throw HarnessFailure.assertion("ordered transport could not inspect mutation")
        }

        mutations.append(
            Mutation(
                path: url.path,
                sequence: sequence,
                clientVersion: request.value(
                    forHTTPHeaderField: CompanionClientVersion.headerName
                )
            )
        )
        if mutations.count == 1 {
            let waiters = firstRequestWaiters
            firstRequestWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            await withCheckedContinuation { continuation in
                firstRequestContinuation = continuation
            }
        }

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            throw HarnessFailure.assertion("could not construct ordered response")
        }
        let responseObject: [String: Any] = [
            "meta": [
                "schema": "yohaku.companion.presence",
                "schemaVersion": 2,
                "requestId": requestID,
                "serverTime": "2026-07-16T12:00:00.180Z",
            ],
            "data": [
                "acceptedSequence": sequence,
                "receivedAt": "2026-07-16T12:00:00.180Z",
                "state": [
                    "schemaVersion": 2,
                    "epoch": "01K0A5P1KD0QAFMZKVFNFC7AFN",
                    "revision": sequence + 1,
                    "projection": NSNull(),
                ],
            ],
        ]
        return (
            try JSONSerialization.data(withJSONObject: responseObject, options: [.sortedKeys]),
            response
        )
    }

    func waitUntilFirstRequestStarts() async {
        guard mutations.isEmpty else { return }
        await withCheckedContinuation { continuation in
            firstRequestWaiters.append(continuation)
        }
    }

    func releaseFirstRequest() {
        firstRequestContinuation?.resume()
        firstRequestContinuation = nil
    }

    func recordedMutations() -> [Mutation] {
        mutations
    }
}

private actor HarnessGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

private actor ImmediatelyFinishingPresenceSender: CompanionPresenceSending {
    func replacePresence(
        with snapshot: SanitizedPresenceSnapshot,
        requestedLeaseSeconds: Int
    ) async throws -> CompanionPresenceMutationResponseV2 {
        throw HarnessFailure.assertion("immediate clear sender received a snapshot")
    }

    func clearPresence(
        reason: CompanionPresenceClearReasonV2,
        observedAt: Date
    ) async throws -> CompanionPresenceMutationResponseV2 {
        throw CancellationError()
    }
}

private struct StaticResponseTransport: CompanionHTTPTransport {
    let responseBody: Data

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            throw HarnessFailure.assertion("could not construct HTTP response")
        }
        return (responseBody, response)
    }
}
