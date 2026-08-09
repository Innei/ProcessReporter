import Foundation

enum CompanionPairingClientError: Error, Equatable, Sendable {
    case invalidPairingCode
    case invalidDeviceName
    case invalidResponse
    case responseTooLarge
    case responseDecodingFailed
    case requiredPresenceScopeMissing
    case clientUpdateRequired
    case presenceSchemaUnsupported
    case serverFeatureUnavailable
    case invalidCapabilities
    case server(statusCode: Int, code: CompanionPairingServerErrorCode?)
}

/// Fixed, non-content error codes accepted from the global API error envelope.
/// Arbitrary server messages and details are deliberately not retained because
/// pairing diagnostics must not become a second response-body log.
enum CompanionPairingServerErrorCode: String, Equatable, Sendable {
    case pairingExpired = "COMPANION_PAIRING_EXPIRED"
    case validationFailed = "VALIDATION_FAILED"
    case rateLimited = "RATE_LIMITED"
    case internalError = "INTERNAL_ERROR"
    case httpError = "HTTP_ERROR"
}

private struct CompanionPairingRequest: Encodable, Sendable {
    let pairingCode: String
    let deviceName: String
}

private struct CompanionPairingResponseEnvelope: Decodable, Sendable {
    struct DataValue: Decodable, Sendable {
        let deviceID: String
        let deviceToken: String
        let scopes: [CompanionDeviceScope]
        let nextSequence: Int

        private enum CodingKeys: String, CodingKey {
            case deviceID = "deviceId"
            case deviceToken
            case scopes
            case nextSequence
        }
    }

    let data: DataValue
}

private struct CompanionPairingErrorEnvelope: Decodable, Sendable {
    struct ErrorValue: Decodable, Sendable {
        let code: String
    }

    let error: ErrorValue
}

actor CompanionPairingClient {
    private let server: CompanionServerConfiguration
    private let transport: any CompanionHTTPTransport
    private let maximumResponseBytes: Int
    private let clientVersion: String

    init(
        server: CompanionServerConfiguration,
        transport: any CompanionHTTPTransport = URLSessionCompanionHTTPTransport(),
        maximumResponseBytes: Int = 64 * 1_024,
        clientVersion: String = CompanionClientVersion.current
    ) {
        self.server = server
        self.transport = transport
        self.maximumResponseBytes = maximumResponseBytes
        self.clientVersion = clientVersion
    }

    /// Claims a one-time pairing code and immediately crosses the protected
    /// persistence boundary. The plaintext Device Token is never returned to UI
    /// code, added to a URL, or retained by this actor after the call completes.
    func claimAndInstall(
        pairingCode: String,
        deviceName: String,
        connectionStore: CompanionConnectionStore
    ) async throws {
        let normalizedCode = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...32).contains(normalizedCode.count) else {
            throw CompanionPairingClientError.invalidPairingCode
        }
        let normalizedName = deviceName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        guard !normalizedName.isEmpty, normalizedName.unicodeScalars.count <= 120 else {
            throw CompanionPairingClientError.invalidDeviceName
        }

        try await connectionStore.ensureProtectedStorageAvailable()

        // A pairing code is single-use. Negotiate the currently advertised
        // Presence contract before asking the server to consume it, so a
        // disabled feature, unsupported schema, or obsolete client cannot mint
        // an unusable Device Token.
        let capabilities = try await CompanionHTTPClient(
            server: server,
            transport: transport,
            clientVersion: clientVersion
        ).fetchCapabilities()
        switch CompanionCapabilityNegotiator.negotiatePresence(
            capabilities.data,
            clientVersion: clientVersion
        ) {
        case .available:
            break
        case .clientUpdateRequired:
            throw CompanionPairingClientError.clientUpdateRequired
        case .schemaUnsupported:
            throw CompanionPairingClientError.presenceSchemaUnsupported
        case .featureUnavailable:
            throw CompanionPairingClientError.serverFeatureUnavailable
        case .invalidCapabilities:
            throw CompanionPairingClientError.invalidCapabilities
        }

        var request = URLRequest(url: server.endpoint("/companion/pairings/claim"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try encoder.encode(
            CompanionPairingRequest(
                pairingCode: normalizedCode,
                deviceName: normalizedName
            )
        )

        let (responseData, response) = try await transport.data(for: request)
        guard responseData.count <= maximumResponseBytes else {
            throw CompanionPairingClientError.responseTooLarge
        }
        guard (200..<300).contains(response.statusCode) else {
            let serverCode = try? JSONDecoder()
                .decode(CompanionPairingErrorEnvelope.self, from: responseData)
                .error.code
            throw CompanionPairingClientError.server(
                statusCode: response.statusCode,
                code: serverCode.flatMap(CompanionPairingServerErrorCode.init(rawValue:))
            )
        }
        guard !responseData.isEmpty else {
            throw CompanionPairingClientError.invalidResponse
        }

        let responseEnvelope: CompanionPairingResponseEnvelope
        do {
            responseEnvelope = try JSONDecoder().decode(
                CompanionPairingResponseEnvelope.self,
                from: responseData
            )
        } catch {
            throw CompanionPairingClientError.responseDecodingFailed
        }
        guard responseEnvelope.data.scopes.contains(.presenceWrite) else {
            throw CompanionPairingClientError.requiredPresenceScopeMissing
        }

        let claim = try CompanionPairingClaim(
            baseURL: server.baseURL,
            deviceID: responseEnvelope.data.deviceID,
            deviceToken: responseEnvelope.data.deviceToken,
            scopes: responseEnvelope.data.scopes,
            nextSequence: responseEnvelope.data.nextSequence
        )
        try await connectionStore.installPairingClaim(claim)
    }
}
