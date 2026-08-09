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

private actor RecordingCredentialPersistence: CompanionConnectionCredentialPersistence {
    private var token: String?
    private var resolveCount = 0
    private var pendingMetadataValues: [String] = []
    private let defaults: UserDefaults

    init(suiteName: String) throws {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw HarnessFailure.assertion("could not create credential defaults suite")
        }
        self.defaults = defaults
    }

    func resolveDeviceToken() -> String? {
        resolveCount += 1
        return token
    }

    func replaceDeviceToken(
        previousValue: String,
        newValue: String,
        pendingMetadataKey: String,
        pendingMetadataValue: String
    ) throws -> CompanionCredentialMutationResult {
        guard previousValue == (token ?? "") else {
            throw HarnessFailure.assertion("credential compare-and-replace used a stale value")
        }
        token = newValue.isEmpty ? nil : newValue
        pendingMetadataValues.append(pendingMetadataValue)
        defaults.set(pendingMetadataValue, forKey: pendingMetadataKey)
        return CompanionCredentialMutationResult(retainedClearedKeychainValue: false)
    }

    func observations() -> (token: String?, resolveCount: Int, metadataValues: [String]) {
        (token, resolveCount, pendingMetadataValues)
    }
}

private actor SuspendingCredentialPersistence: CompanionConnectionCredentialPersistence {
    private var resolutionContinuation: CheckedContinuation<String?, Never>?
    private var didBeginResolution = false
    private var beginWaiters: [CheckedContinuation<Void, Never>] = []

    func resolveDeviceToken() async -> String? {
        didBeginResolution = true
        let waiters = beginWaiters
        beginWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        return await withCheckedContinuation { continuation in
            resolutionContinuation = continuation
        }
    }

    func replaceDeviceToken(
        previousValue: String,
        newValue: String,
        pendingMetadataKey: String,
        pendingMetadataValue: String
    ) throws -> CompanionCredentialMutationResult {
        throw HarnessFailure.assertion("suspending credential store cannot mutate")
    }

    func waitUntilResolutionBegins() async {
        if didBeginResolution { return }
        await withCheckedContinuation { continuation in
            beginWaiters.append(continuation)
        }
    }

    func completeResolution(with token: String?) {
        resolutionContinuation?.resume(returning: token)
        resolutionContinuation = nil
    }
}

private struct UnavailableCredentialPersistence: CompanionConnectionCredentialPersistence {
    func resolveDeviceToken() throws -> String? {
        throw CompanionConnectionStoreError.credentialStorageUnavailable
    }

    func replaceDeviceToken(
        previousValue: String,
        newValue: String,
        pendingMetadataKey: String,
        pendingMetadataValue: String
    ) throws -> CompanionCredentialMutationResult {
        throw HarnessFailure.assertion("unavailable credential store attempted a mutation")
    }
}

@main
private struct CompanionConnectionCaptureHarness {
    private static let deviceID = "01K0A4VDWYSH1JQH4PGY4QM8YT"
    private static let requestID = "00000000-0000-4000-8000-000000000001"

    static func main() async throws {
        try await verifiesUnavailableProtectedStorageDoesNotConsumePairingCode()
        try await verifiesCapabilitiesPreflightDoesNotConsumePairingCode()
        try await verifiesPairingErrorEnvelopeRetainsOnlyStableCode()
        try await verifiesPairingTransportInstallsWithoutLeakingTheToken()
        try await verifiesPairingWithoutPresenceScopeIsRejected()
        try await verifiesPairingIsProtectedAndDefaultsToDisabled()
        try await verifiesConcurrentDisableWinsOverCredentialResolution()
        try verifiesApplicationPrivacyProducesAnApplicationOnlySnapshot()
        try verifiesHiddenApplicationProducesAnExplicitIdleSnapshot()
        print("Companion connection and capture behavior passed")
    }

    private static func verifiesUnavailableProtectedStorageDoesNotConsumePairingCode() async throws {
        let suiteName = "ProcessReporter.PairingPreflightHarness.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw HarnessFailure.assertion("could not create preflight defaults suite")
        }
        let store = CompanionConnectionStore(
            defaults: defaults,
            credentialPersistence: UnavailableCredentialPersistence()
        )
        let transport = PairingRecordingTransport(claimResponseBody: Data("{}".utf8))
        let client = CompanionPairingClient(
            server: try CompanionServerConfiguration(
                baseURL: URL(string: "https://example.com")!
            ),
            transport: transport
        )

        do {
            try await client.claimAndInstall(
                pairingCode: "01234-56789",
                deviceName: "MacBook Pro",
                connectionStore: store
            )
            throw HarnessFailure.assertion("pairing bypassed unavailable credential storage")
        } catch CompanionConnectionStoreError.credentialStorageUnavailable {
            // Expected.
        }
        let requests = await transport.recordedRequests()
        try expect(
            requests.isEmpty,
            "pairing code was consumed before credential preflight succeeded"
        )
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    private static func verifiesCapabilitiesPreflightDoesNotConsumePairingCode() async throws {
        let scenarios: [(String, Data, CompanionPairingClientError)] = [
            (
                "feature-off",
                Data(
                    availableCapabilitiesJSON.replacingOccurrences(
                        of: "\"liveDesk\": true",
                        with: "\"liveDesk\": false"
                    ).utf8
                ),
                .serverFeatureUnavailable
            ),
            (
                "schema-newer",
                Data(
                    availableCapabilitiesJSON.replacingOccurrences(
                        of: "\"presenceSchemaVersions\": [2]",
                        with: "\"presenceSchemaVersions\": [3]"
                    ).utf8
                ),
                .presenceSchemaUnsupported
            ),
            (
                "client-old",
                Data(
                    availableCapabilitiesJSON.replacingOccurrences(
                        of: "\"minimumClientVersion\": \"0.0.0\"",
                        with: "\"minimumClientVersion\": \"99.0.0\""
                    ).utf8
                ),
                .clientUpdateRequired
            ),
        ]

        for (name, capabilitiesBody, expectedError) in scenarios {
            let suiteName = "ProcessReporter.PairingCapabilitiesHarness.\(name).\(UUID().uuidString)"
            let credentials = try RecordingCredentialPersistence(suiteName: suiteName)
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                throw HarnessFailure.assertion("could not create capabilities defaults suite")
            }
            let store = CompanionConnectionStore(
                defaults: defaults,
                credentialPersistence: credentials
            )
            let transport = PairingRecordingTransport(
                claimResponseBody: Data("{}".utf8),
                capabilitiesResponseBody: capabilitiesBody
            )
            let client = CompanionPairingClient(
                server: try CompanionServerConfiguration(
                    baseURL: URL(string: "https://example.com")!
                ),
                transport: transport,
                clientVersion: "1.7.3"
            )

            do {
                try await client.claimAndInstall(
                    pairingCode: "01234-56789",
                    deviceName: "MacBook Pro",
                    connectionStore: store
                )
                throw HarnessFailure.assertion("\(name) capabilities consumed a pairing code")
            } catch let error as CompanionPairingClientError {
                try expect(error == expectedError, "\(name) returned the wrong local state")
            }

            let requests = await transport.recordedRequests()
            try expect(requests.count == 1, "\(name) issued a claim after failed negotiation")
            try expect(
                requests[0].httpMethod == "GET"
                    && requests[0].url?.path.hasSuffix("/companion/capabilities") == true,
                "\(name) did not stop at capabilities preflight"
            )
            let observations = await credentials.observations()
            try expect(observations.token == nil, "\(name) persisted a Device Token")
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
    }

    private static func verifiesPairingErrorEnvelopeRetainsOnlyStableCode() async throws {
        let suiteName = "ProcessReporter.PairingErrorHarness.\(UUID().uuidString)"
        let untrustedMessage = "expired response must not become retained diagnostics"
        let response = """
        {
          "error": {
            "code": "COMPANION_PAIRING_EXPIRED",
            "message": "\(untrustedMessage)"
          }
        }
        """
        let credentials = try RecordingCredentialPersistence(suiteName: suiteName)
        guard let storeDefaults = UserDefaults(suiteName: suiteName) else {
            throw HarnessFailure.assertion("could not create pairing error defaults suite")
        }
        let store = CompanionConnectionStore(
            defaults: storeDefaults,
            credentialPersistence: credentials
        )
        let client = CompanionPairingClient(
            server: try CompanionServerConfiguration(
                baseURL: URL(string: "https://example.com")!
            ),
            transport: PairingRecordingTransport(
                claimResponseBody: Data(response.utf8),
                claimStatusCode: 410
            )
        )

        do {
            try await client.claimAndInstall(
                pairingCode: "01234-56789",
                deviceName: "MacBook Pro",
                connectionStore: store
            )
            throw HarnessFailure.assertion("expired pairing response was accepted")
        } catch let error as CompanionPairingClientError {
            try expect(
                error == .server(statusCode: 410, code: .pairingExpired),
                "global pairing error envelope was not decoded"
            )
            try expect(
                !String(reflecting: error).contains(untrustedMessage),
                "arbitrary server message entered retained pairing diagnostics"
            )
        }

        let observations = await credentials.observations()
        try expect(observations.token == nil, "failed claim persisted a Device Token")
        let metadata = try await store.loadMetadata()
        try expect(metadata == nil, "failed claim persisted metadata")
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    private static func verifiesPairingWithoutPresenceScopeIsRejected() async throws {
        let suiteName = "ProcessReporter.PairingScopeHarness.\(UUID().uuidString)"
        let response = """
        {
          "data": {
            "deviceId": "\(deviceID)",
            "deviceToken": "moment-only-token",
            "scopes": ["companion:moment:write"],
            "nextSequence": 0
          }
        }
        """
        let credentials = try RecordingCredentialPersistence(suiteName: suiteName)
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw HarnessFailure.assertion("could not create scope defaults suite")
        }
        let store = CompanionConnectionStore(
            defaults: defaults,
            credentialPersistence: credentials
        )
        let client = CompanionPairingClient(
            server: try CompanionServerConfiguration(
                baseURL: URL(string: "https://example.com")!
            ),
            transport: PairingRecordingTransport(claimResponseBody: Data(response.utf8))
        )

        do {
            try await client.claimAndInstall(
                pairingCode: "01234-56789",
                deviceName: "MacBook Pro",
                connectionStore: store
            )
            throw HarnessFailure.assertion("moment-only pairing was accepted for Live Desk")
        } catch CompanionPairingClientError.requiredPresenceScopeMissing {
            // Expected.
        }

        let observations = await credentials.observations()
        try expect(observations.token == nil, "scope-denied token was persisted")
        let deniedMetadata = try await store.loadMetadata()
        try expect(deniedMetadata == nil, "scope-denied metadata was persisted")
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    private static func verifiesPairingTransportInstallsWithoutLeakingTheToken() async throws {
        let suiteName = "ProcessReporter.PairingHarness.\(UUID().uuidString)"
        let secret = "one-time-device-token"
        let response = """
        {
          "data": {
            "deviceId": "\(deviceID)",
            "deviceToken": "\(secret)",
            "scopes": ["companion:presence:write"],
            "nextSequence": 7
          },
          "meta": {}
        }
        """
        let transport = PairingRecordingTransport(claimResponseBody: Data(response.utf8))
        let credentials = try RecordingCredentialPersistence(suiteName: suiteName)
        guard let storeDefaults = UserDefaults(suiteName: suiteName) else {
            throw HarnessFailure.assertion("could not create pairing defaults suite")
        }
        let store = CompanionConnectionStore(
            defaults: storeDefaults,
            credentialPersistence: credentials
        )
        let server = try CompanionServerConfiguration(
            baseURL: URL(string: "https://example.com/api/v3")!
        )
        let client = CompanionPairingClient(server: server, transport: transport)

        try await client.claimAndInstall(
            pairingCode: " 01234-56789 ",
            deviceName: "  MacBook Pro  ",
            connectionStore: store
        )

        let requests = await transport.recordedRequests()
        try expect(requests.count == 2, "pairing did not perform exactly one preflight and claim")
        let capabilitiesRequest = requests[0]
        try expect(
            capabilitiesRequest.httpMethod == "GET"
                && capabilitiesRequest.url?.path == "/api/v3/companion/capabilities",
            "pairing did not preflight the negotiated server contract"
        )
        try expect(
            capabilitiesRequest.value(forHTTPHeaderField: "Authorization") == nil,
            "capabilities preflight unexpectedly sent a Device Token"
        )
        let request = requests[1]
        try expect(
            request.url?.path == "/api/v3/companion/pairings/claim",
            "pairing used the wrong endpoint"
        )
        try expect(request.url?.query == nil, "pairing credential entered the URL query")
        try expect(
            request.value(forHTTPHeaderField: "Authorization") == nil,
            "one-time pairing unexpectedly sent a Device Token header"
        )
        let body = try dictionary(
            try JSONSerialization.jsonObject(with: request.httpBody ?? Data()),
            "pairing request"
        )
        try expect(body["pairingCode"] as? String == "01234-56789", "pairing code was not normalized")
        try expect(body["deviceName"] as? String == "MacBook Pro", "device name was not normalized")
        try expect(
            !String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains(secret),
            "minted Device Token entered the pairing request"
        )

        let observations = await credentials.observations()
        try expect(observations.token == secret, "claimed Device Token was not protected")
        let metadata = try required(try await store.loadMetadata(), "pairing metadata missing")
        try expect(!metadata.isLiveDeskEnabled, "claim transport bypassed preview consent")
        try expect(metadata.scopes.contains(.presenceWrite), "claimed scope was not retained")
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    private static func verifiesConcurrentDisableWinsOverCredentialResolution() async throws {
        let suiteName = "ProcessReporter.CompanionRaceHarness.\(UUID().uuidString)"
        guard let seedDefaults = UserDefaults(suiteName: suiteName) else {
            throw HarnessFailure.assertion("could not create race defaults suite")
        }
        let metadata = try CompanionConnectionMetadata(
            baseURL: URL(string: "https://example.com")!,
            deviceID: deviceID,
            pairingNextSequence: 10,
            isLiveDeskEnabled: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(metadata)
        seedDefaults.set(
            String(decoding: encoded, as: UTF8.self),
            forKey: CompanionConnectionStore.metadataKey
        )

        let credentials = SuspendingCredentialPersistence()
        guard let storeDefaults = UserDefaults(suiteName: suiteName) else {
            throw HarnessFailure.assertion("could not open race defaults suite")
        }
        let store = CompanionConnectionStore(
            defaults: storeDefaults,
            credentialPersistence: credentials
        )
        let loadTask = Task {
            try await store.loadEnabledConnection()
        }
        await credentials.waitUntilResolutionBegins()
        try await store.setLiveDeskEnabled(false)
        await credentials.completeResolution(with: "resolved-after-disable")

        let connection = try await loadTask.value
        try expect(connection == nil, "concurrent disable published with a stale opt-in")
        seedDefaults.removePersistentDomain(forName: suiteName)
    }

    private static func verifiesPairingIsProtectedAndDefaultsToDisabled() async throws {
        let suiteName = "ProcessReporter.CompanionHarness.\(UUID().uuidString)"
        guard let setupDefaults = UserDefaults(suiteName: suiteName) else {
            throw HarnessFailure.assertion("could not create isolated defaults suite")
        }
        setupDefaults.removePersistentDomain(forName: suiteName)

        let protectedPersistence = try RecordingCredentialPersistence(suiteName: suiteName)
        guard let storeDefaults = UserDefaults(suiteName: suiteName) else {
            throw HarnessFailure.assertion("could not create connection defaults suite")
        }
        let store = CompanionConnectionStore(
            defaults: storeDefaults,
            credentialPersistence: protectedPersistence
        )
        let secret = "device-secret-that-must-not-enter-defaults"
        let claim = try CompanionPairingClaim(
            baseURL: URL(string: "https://example.com")!,
            deviceID: deviceID,
            deviceToken: secret,
            nextSequence: 41
        )
        try expect(!String(describing: claim).contains(secret), "pairing description leaked token")
        try expect(!String(reflecting: claim).contains(secret), "pairing debug description leaked token")
        try await store.installPairingClaim(claim)

        guard let inspectionDefaults = UserDefaults(suiteName: suiteName) else {
            throw HarnessFailure.assertion("could not inspect isolated defaults suite")
        }
        let metadataValue = try required(
            inspectionDefaults.string(forKey: CompanionConnectionStore.metadataKey),
            "pairing did not commit metadata"
        )
        try expect(!metadataValue.contains(secret), "Device Token entered metadata")
        try expect(
            !metadataValue.contains("token") && !metadataValue.contains("credential"),
            "metadata exposed a credential-shaped key"
        )
        try expect(
            inspectionDefaults.dictionaryRepresentation().values.allSatisfy {
                !String(describing: $0).contains(secret)
            },
            "Device Token entered UserDefaults"
        )

        let metadata = try required(
            try await store.loadMetadata(),
            "stored metadata could not be loaded"
        )
        try expect(!metadata.isLiveDeskEnabled, "pairing silently enabled public Live Desk")
        try expect(metadata.pairingNextSequence == 41, "pairing sequence was not retained")

        let countAfterInstall = await protectedPersistence.observations().resolveCount
        let disabledConnection = try await store.loadEnabledConnection()
        let countAfterDisabledLoad = await protectedPersistence.observations().resolveCount
        try expect(disabledConnection == nil, "disabled Live Desk resolved a connection")
        try expect(
            countAfterDisabledLoad == countAfterInstall,
            "disabled Live Desk unnecessarily resolved the protected token"
        )

        try await store.setLiveDeskEnabled(true)
        let enabledConnection = try required(
            try await store.loadEnabledConnection(),
            "explicit opt-in did not resolve the paired connection"
        )
        try expect(enabledConnection.credential.deviceID == deviceID, "device binding changed")
        try expect(enabledConnection.credential.token == secret, "protected token was not resolved")
        try expect(
            !String(reflecting: enabledConnection.credential).contains(secret),
            "credential debug description leaked token"
        )

        _ = try await store.removeConnection()
        let finalState = await protectedPersistence.observations()
        try expect(finalState.token == nil, "connection removal retained the protected token")
        try expect(
            inspectionDefaults.string(forKey: CompanionConnectionStore.metadataKey) == "",
            "connection removal retained active metadata"
        )
        try expect(
            finalState.metadataValues.allSatisfy { !$0.contains(secret) },
            "credential transaction received secret-bearing metadata"
        )
        inspectionDefaults.removePersistentDomain(forName: suiteName)
    }

    private static func verifiesApplicationPrivacyProducesAnApplicationOnlySnapshot() throws {
        let application = try required(
            CompanionApplicationPresenceSanitizer.sanitize(
                capturedDisplayName: "  Xcode  ",
                mappedDisplayName: "Editor",
                displayAlias: "  Focus  ",
                capturedWindowTitle: "Private.swift",
                sharesApplication: true,
                sharesWindowTitle: false,
                globalWindowTitleSharingEnabled: true
            ),
            "shared application was removed"
        )
        let request = try CompanionPresenceDTOMapper().makePresenceRequest(
            snapshot: SanitizedPresenceSnapshot(
                observedAt: Date(timeIntervalSince1970: 1_721_131_200),
                application: application,
                media: nil
            ),
            deviceID: deviceID,
            sequence: 1,
            requestID: requestID
        )
        let data = try requestData(request)
        let encodedApplication = try dictionary(data["application"], "application")

        try expect(data["availability"] as? String == "active", "snapshot was not active")
        try expect(encodedApplication["displayName"] as? String == "Focus", "alias lost precedence")
        try expect(encodedApplication["window"] is NSNull, "hidden window title escaped privacy")
        try expect(data["media"] is NSNull, "initial slice fabricated media context")
    }

    private static func verifiesHiddenApplicationProducesAnExplicitIdleSnapshot() throws {
        let application = try CompanionApplicationPresenceSanitizer.sanitize(
            capturedDisplayName: "Xcode",
            mappedDisplayName: nil,
            displayAlias: nil,
            capturedWindowTitle: "Private.swift",
            sharesApplication: false,
            sharesWindowTitle: true,
            globalWindowTitleSharingEnabled: true
        )
        try expect(application == nil, "hidden application survived sanitization")

        let request = try CompanionPresenceDTOMapper().makePresenceRequest(
            snapshot: SanitizedPresenceSnapshot(
                observedAt: Date(timeIntervalSince1970: 1_721_131_200),
                application: application,
                media: nil
            ),
            deviceID: deviceID,
            sequence: 2,
            requestID: "00000000-0000-4000-8000-000000000002"
        )
        let data = try requestData(request)
        try expect(data["availability"] as? String == "idle", "empty capture was not idle")
        try expect(data["application"] is NSNull, "application null key was omitted")
        try expect(data["media"] is NSNull, "media null key was omitted")
    }

    private static func requestData(_ request: CompanionPresenceRequestV2) throws -> [String: Any] {
        let encoded = try CompanionJSON.makeEncoder().encode(request)
        let object = try JSONSerialization.jsonObject(with: encoded)
        let root = try dictionary(object, "root")
        return try dictionary(root["data"], "data")
    }

    private static func dictionary(_ value: Any?, _ path: String) throws -> [String: Any] {
        guard let value = value as? [String: Any] else {
            throw HarnessFailure.assertion("\(path) was not an object")
        }
        return value
    }

    private static func required<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw HarnessFailure.assertion(message) }
        return value
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw HarnessFailure.assertion(message) }
    }
}

private let availableCapabilitiesJSON = """
{
  "meta": {
    "schema": "yohaku.companion.presence",
    "schemaVersion": 2,
    "requestId": "00000000-0000-4000-8000-000000000090",
    "serverTime": "2026-07-16T12:00:00.180Z"
  },
  "data": {
    "minimumClientVersion": "0.0.0",
    "presenceSchemaVersions": [2],
    "momentSchemaVersions": [],
    "features": {
      "liveDesk": true,
      "mediaTimeline": false,
      "moments": false,
      "readingSessions": false
    },
    "limits": {
      "presencePayloadBytes": 32768,
      "presenceRequestsPerMinute": 30,
      "presenceLeaseMinSeconds": 30,
      "presenceLeaseMaxSeconds": 120,
      "recommendedHeartbeatSeconds": 30,
      "maximumClockSkewSeconds": 30
    }
  }
}
"""

private actor PairingRecordingTransport: CompanionHTTPTransport {
    private let claimResponseBody: Data
    private let claimStatusCode: Int
    private let capabilitiesResponseBody: Data
    private var requests: [URLRequest] = []

    init(
        claimResponseBody: Data,
        claimStatusCode: Int = 201,
        capabilitiesResponseBody: Data = Data(availableCapabilitiesJSON.utf8)
    ) {
        self.claimResponseBody = claimResponseBody
        self.claimStatusCode = claimStatusCode
        self.capabilitiesResponseBody = capabilitiesResponseBody
    }

    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let isCapabilities = request.url?.path.hasSuffix("/companion/capabilities") == true
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: isCapabilities ? 200 : claimStatusCode,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              )
        else {
            throw HarnessFailure.assertion("could not construct pairing response")
        }
        return (
            isCapabilities ? capabilitiesResponseBody : claimResponseBody,
            response
        )
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}
