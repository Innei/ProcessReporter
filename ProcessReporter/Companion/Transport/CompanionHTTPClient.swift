import Foundation

enum CompanionClientVersion {
    static let headerName = "X-Yohaku-Companion-Version"

    static var current: String {
        guard let value = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String, !value.isEmpty else {
            return "0.0.0"
        }
        return value
    }
}

enum CompanionConnectionConfigurationError: Error, Equatable, Sendable {
    case invalidBaseURL
    case insecureBaseURL
    case missingCredential
}

struct CompanionServerConfiguration: Equatable, Sendable {
    let baseURL: URL

    init(baseURL: URL) throws {
        guard
            let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(),
            let host = components.host,
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil
        else {
            throw CompanionConnectionConfigurationError.invalidBaseURL
        }
        guard scheme == "https" || (scheme == "http" && Self.isLoopbackHost(host)) else {
            throw CompanionConnectionConfigurationError.insecureBaseURL
        }
        self.baseURL = baseURL
    }

    func endpoint(_ path: String) -> URL {
        path.split(separator: "/").reduce(baseURL) { url, component in
            url.appendingPathComponent(String(component), isDirectory: false)
        }
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.lowercased()
        if normalized == "localhost" || normalized == "[::1]" || normalized == "::1" {
            return true
        }

        let octets = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets.first == "127" else { return false }
        return octets.allSatisfy { UInt8($0) != nil }
    }
}

struct CompanionDeviceCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let deviceID: String
    let token: String

    init(deviceID: String, token: String) throws {
        let normalizedDeviceID = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDeviceID.isEmpty, !normalizedToken.isEmpty else {
            throw CompanionConnectionConfigurationError.missingCredential
        }
        self.deviceID = normalizedDeviceID
        self.token = normalizedToken
    }

    var description: String { "CompanionDeviceCredential(<redacted>)" }
    var debugDescription: String { description }
}

protocol CompanionHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionCompanionHTTPTransport: CompanionHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CompanionHTTPClientError.invalidResponse
        }
        return (data, httpResponse)
    }
}

enum CompanionHTTPClientError: Error, Sendable {
    case invalidResponse
    case credentialDeviceMismatch
    case responseRequestIDMismatch
    case payloadTooLarge
    case unexpectedEmptyResponse(statusCode: Int)
    case responseDecodingFailed(statusCode: Int)
    case server(statusCode: Int, response: CompanionErrorResponseV2?)
}

actor CompanionHTTPClient {
    private let server: CompanionServerConfiguration
    private let transport: any CompanionHTTPTransport
    private let maximumPayloadBytes: Int
    private let clientVersion: String

    init(
        server: CompanionServerConfiguration,
        transport: any CompanionHTTPTransport = URLSessionCompanionHTTPTransport(),
        maximumPayloadBytes: Int = 32 * 1_024,
        clientVersion: String = CompanionClientVersion.current
    ) {
        self.server = server
        self.transport = transport
        self.maximumPayloadBytes = maximumPayloadBytes
        let normalizedVersion = clientVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientVersion = normalizedVersion.isEmpty ? "0.0.0" : normalizedVersion
    }

    func fetchCapabilities() async throws -> CompanionCapabilitiesResponseV2 {
        try await execute(
            method: "GET",
            path: "/companion/capabilities",
            credential: nil,
            body: Optional<CompanionPresenceRequestV2>.none,
            expectedRequestID: nil,
            responseType: CompanionCapabilitiesResponseV2.self
        )
    }

    func replacePresence(
        _ request: CompanionPresenceRequestV2,
        credential: CompanionDeviceCredential
    ) async throws -> CompanionPresenceMutationResponseV2 {
        guard request.meta.deviceID == credential.deviceID else {
            throw CompanionHTTPClientError.credentialDeviceMismatch
        }
        return try await execute(
            method: "PUT",
            path: "/companion/presence",
            credential: credential,
            body: request,
            expectedRequestID: request.meta.requestID,
            responseType: CompanionPresenceMutationResponseV2.self
        )
    }

    func clearPresence(
        _ request: CompanionPresenceClearRequestV2,
        credential: CompanionDeviceCredential
    ) async throws -> CompanionPresenceMutationResponseV2 {
        guard request.meta.deviceID == credential.deviceID else {
            throw CompanionHTTPClientError.credentialDeviceMismatch
        }
        return try await execute(
            method: "POST",
            path: "/companion/presence/clear",
            credential: credential,
            body: request,
            expectedRequestID: request.meta.requestID,
            responseType: CompanionPresenceMutationResponseV2.self
        )
    }

    func fetchPublicPresence() async throws -> CompanionPublicPresenceResponseV2 {
        try await execute(
            method: "GET",
            path: "/companion/presence/public",
            credential: nil,
            body: Optional<CompanionPresenceRequestV2>.none,
            expectedRequestID: nil,
            responseType: CompanionPublicPresenceResponseV2.self
        )
    }

    private func execute<Request: Encodable, Response: CompanionResponseEnvelopeV2>(
        method: String,
        path: String,
        credential: CompanionDeviceCredential?,
        body: Request?,
        expectedRequestID: String?,
        responseType: Response.Type
    ) async throws -> Response {
        var request = URLRequest(url: server.endpoint(path))
        request.httpMethod = method
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let credential {
            request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
            request.setValue(
                clientVersion,
                forHTTPHeaderField: CompanionClientVersion.headerName
            )
        }
        if let body {
            let encoded = try CompanionJSON.makeEncoder().encode(body)
            guard encoded.count <= maximumPayloadBytes else {
                throw CompanionHTTPClientError.payloadTooLarge
            }
            request.httpBody = encoded
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await transport.data(for: request)
        guard !data.isEmpty else {
            throw CompanionHTTPClientError.unexpectedEmptyResponse(
                statusCode: response.statusCode
            )
        }

        if (200..<300).contains(response.statusCode) {
            do {
                let decoded = try CompanionJSON.makeDecoder().decode(responseType, from: data)
                try validateRequestID(decoded.meta.requestID, expected: expectedRequestID)
                return decoded
            } catch let error as CompanionHTTPClientError {
                throw error
            } catch {
                throw CompanionHTTPClientError.responseDecodingFailed(
                    statusCode: response.statusCode
                )
            }
        }

        let errorResponse = try? CompanionJSON.makeDecoder().decode(
            CompanionErrorResponseV2.self,
            from: data
        )
        if let errorResponse {
            try validateRequestID(errorResponse.meta.requestID, expected: expectedRequestID)
        }
        throw CompanionHTTPClientError.server(
            statusCode: response.statusCode,
            response: errorResponse
        )
    }

    private func validateRequestID(_ actual: String, expected: String?) throws {
        guard let expected else { return }
        guard actual == expected else {
            throw CompanionHTTPClientError.responseRequestIDMismatch
        }
    }
}
