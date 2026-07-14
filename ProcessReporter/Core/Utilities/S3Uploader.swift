//
//  S3Uploader.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/13.
//

import CommonCrypto
import CryptoKit
import Foundation

struct S3UploaderOptions {
    let bucket: String
    let region: String
    let accessKey: String
    let secretKey: String
    let endpoint: String?
    let customDomain: String?

    init(
        bucket: String,
        region: String,
        accessKey: String,
        secretKey: String,
        endpoint: String? = nil,
        customDomain: String? = nil
    ) {
        self.bucket = bucket
        self.region = region
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.endpoint = endpoint
        self.customDomain = customDomain
    }
}

enum S3UploaderError: LocalizedError {
    case missingConfiguration(String)
    case invalidEndpoint(String)
    case insecureEndpoint(String)
    case invalidObjectKey
    case uploadFailed(statusCode: Int, response: String?)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration(let field):
            return "Missing S3 configuration: \(field)"
        case .invalidEndpoint(let value):
            return "Invalid S3 endpoint: \(value)"
        case .insecureEndpoint(let value):
            return "S3 credentials require HTTPS (except localhost): \(value)"
        case .invalidObjectKey:
            return "Invalid S3 object path"
        case .uploadFailed(let statusCode, let response):
            if let response, !response.isEmpty {
                return "S3 upload failed with HTTP \(statusCode): \(response)"
            }
            return "S3 upload failed with HTTP \(statusCode)"
        }
    }
}

final class S3Uploader {
    private let options: S3UploaderOptions

    init(options: S3UploaderOptions) {
        self.options = options
    }

    private var usesCustomEndpoint: Bool {
        guard let endpoint = options.endpoint?.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        return !endpoint.isEmpty
    }

    private func endpointURL() throws -> URL {
        let endpoint: String
        if let configured = options.endpoint?.trimmingCharacters(in: .whitespacesAndNewlines),
            !configured.isEmpty
        {
            endpoint = configured
        } else {
            endpoint = "https://\(options.bucket).s3.\(options.region).amazonaws.com"
        }

        guard var components = URLComponents(string: endpoint),
            let scheme = components.scheme?.lowercased(),
            (scheme == "https" || scheme == "http"),
            let host = components.host,
            !host.isEmpty,
            components.query == nil,
            components.fragment == nil
        else {
            throw S3UploaderError.invalidEndpoint(endpoint)
        }

        if scheme == "http", !isLoopbackHost(host) {
            throw S3UploaderError.insecureEndpoint(endpoint)
        }

        // A trailing slash must not produce a different canonical request path.
        while components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        guard let url = components.url else {
            throw S3UploaderError.invalidEndpoint(endpoint)
        }
        return url
    }

    private static func pathSegments(from rawPath: String) throws -> [String] {
        let segments = rawPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !segments.contains(where: { $0 == "." || $0 == ".." || $0.isEmpty }) else {
            throw S3UploaderError.invalidObjectKey
        }
        return segments
    }

    private static func sigV4EncodedPathSegment(_ segment: String) -> String {
        let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)
        return segment.utf8.map { byte in
            unreserved.contains(byte) ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
        }.joined()
    }

    private static func appending(segments: [String], to baseURL: URL) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        else {
            throw S3UploaderError.invalidEndpoint(baseURL.absoluteString)
        }
        let baseSegments = components.path.split(
            separator: "/", omittingEmptySubsequences: true
        ).map(String.init)
        let encodedSegments = (baseSegments + segments).map(sigV4EncodedPathSegment)
        components.percentEncodedPath = encodedSegments.isEmpty
            ? "/" : "/" + encodedSegments.joined(separator: "/")
        guard let url = components.url else {
            throw S3UploaderError.invalidEndpoint(baseURL.absoluteString)
        }
        return url
    }

    private func requestURL(for objectKey: String) throws -> URL {
        guard !options.bucket.isEmpty else {
            throw S3UploaderError.missingConfiguration("bucket")
        }
        let objectSegments = try Self.pathSegments(from: objectKey)
        guard !objectSegments.isEmpty else {
            throw S3UploaderError.invalidObjectKey
        }

        var url = try endpointURL()
        // Custom S3-compatible endpoints generally use path-style addressing.
        // AWS's generated endpoint already embeds the bucket in its host.
        if usesCustomEndpoint {
            url = try Self.appending(segments: [options.bucket], to: url)
        }
        return try Self.appending(segments: objectSegments, to: url)
    }

    private func publicURL(for objectKey: String) throws -> URL {
        if let domain = options.customDomain?.trimmingCharacters(in: .whitespacesAndNewlines),
            !domain.isEmpty
        {
            guard let components = URLComponents(string: domain),
                let scheme = components.scheme?.lowercased(),
                (scheme == "https" || scheme == "http"),
                components.host != nil,
                components.query == nil,
                components.fragment == nil,
                let baseURL = components.url
            else {
                throw S3UploaderError.invalidEndpoint(domain)
            }
            return try Self.appending(
                segments: Self.pathSegments(from: objectKey),
                to: baseURL
            )
        }
        return try requestURL(for: objectKey)
    }

    private func hmacSha256(key: Data, message: Data) -> Data {
        var hmac = HMAC<SHA256>(key: SymmetricKey(data: key))
        hmac.update(data: message)
        return Data(hmac.finalize())
    }

    private func imageObjectKey(_ imageData: Data, path: String) throws -> String {
        let filename = "\(imageData.md5()).png"
        return (try Self.pathSegments(from: path) + [filename]).joined(separator: "/")
    }

    func publicImageURL(_ imageData: Data, to path: String) throws -> String {
        try publicURL(for: imageObjectKey(imageData, path: path)).absoluteString
    }

    func uploadImage(_ imageData: Data, to path: String) async throws -> String {
        let objectKey = try imageObjectKey(imageData, path: path)

        try await uploadToS3(
            objectKey: objectKey,
            fileData: imageData,
            contentType: "image/png"
        )

        return try publicURL(for: objectKey).absoluteString
    }

    func uploadToS3(
        objectKey: String,
        fileData: Data,
        contentType: String
    ) async throws {
        guard !options.region.isEmpty else {
            throw S3UploaderError.missingConfiguration("region")
        }
        guard !options.accessKey.isEmpty else {
            throw S3UploaderError.missingConfiguration("access key")
        }
        guard !options.secretKey.isEmpty else {
            throw S3UploaderError.missingConfiguration("secret key")
        }

        let requestURL = try requestURL(for: objectKey)
        guard let urlComponents = URLComponents(url: requestURL, resolvingAgainstBaseURL: false),
            let host = urlComponents.host
        else {
            throw S3UploaderError.invalidEndpoint(requestURL.absoluteString)
        }

        let service = "s3"
        let xAmzDate = Self.s3Timestamp(from: Date())
        let dateStamp = String(xAmzDate.prefix(8))
        let hashedPayload = fileData.sha256()
        let hostHeader: String
        if let port = urlComponents.port {
            let formattedHost = host.contains(":") ? "[\(host)]" : host
            hostHeader = "\(formattedHost):\(port)"
        } else {
            hostHeader = host
        }

        let headers = [
            "Host": hostHeader,
            "Content-Type": contentType,
            "Content-Length": String(fileData.count),
            "x-amz-date": xAmzDate,
            "x-amz-content-sha256": hashedPayload,
        ]

        let sortedHeaders = headers.keys.sorted { $0.lowercased() < $1.lowercased() }
        let canonicalHeaders = sortedHeaders.map { key in
            let value = headers[key]!.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(key.lowercased()):\(value)"
        }.joined(separator: "\n")
        let signedHeaders = sortedHeaders.map { $0.lowercased() }.joined(separator: ";")
        let canonicalURI = urlComponents.percentEncodedPath.isEmpty
            ? "/" : urlComponents.percentEncodedPath

        let canonicalRequest = [
            "PUT",
            canonicalURI,
            "",
            canonicalHeaders,
            "",
            signedHeaders,
            hashedPayload,
        ].joined(separator: "\n")

        let algorithm = "AWS4-HMAC-SHA256"
        let credentialScope = "\(dateStamp)/\(options.region)/\(service)/aws4_request"
        let stringToSign = [
            algorithm,
            xAmzDate,
            credentialScope,
            canonicalRequest.sha256(),
        ].joined(separator: "\n")

        let kSecret = Data(("AWS4" + options.secretKey).utf8)
        let kDate = hmacSha256(key: kSecret, message: Data(dateStamp.utf8))
        let kRegion = hmacSha256(key: kDate, message: Data(options.region.utf8))
        let kService = hmacSha256(key: kRegion, message: Data(service.utf8))
        let kSigning = hmacSha256(key: kService, message: Data("aws4_request".utf8))
        let signature = hmacSha256(key: kSigning, message: Data(stringToSign.utf8)).map {
            String(format: "%02x", $0)
        }.joined()

        let authorization =
            "\(algorithm) Credential=\(options.accessKey)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var request = URLRequest(url: requestURL)
        request.httpMethod = "PUT"
        request.httpBody = fileData
        request.timeoutInterval = 10
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue(authorization, forHTTPHeaderField: "Authorization")

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw S3UploaderError.uploadFailed(statusCode: -1, response: "Invalid HTTP response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let responseSnippet = String(data: responseData.prefix(512), encoding: .utf8)
            throw S3UploaderError.uploadFailed(
                statusCode: httpResponse.statusCode,
                response: responseSnippet
            )
        }
    }

    func uploadFileToR2(
        accountId: String,
        accessKeyId: String,
        secretAccessKey: String,
        bucketName: String,
        objectKey: String,
        fileData: Data,
        contentType: String
    ) async throws {
        let r2Uploader = S3Uploader(
            options: S3UploaderOptions(
                bucket: bucketName,
                region: "auto",
                accessKey: accessKeyId,
                secretKey: secretAccessKey,
                endpoint: "https://\(accountId).r2.cloudflarestorage.com"
            )
        )
        try await r2Uploader.uploadToS3(
            objectKey: objectKey,
            fileData: fileData,
            contentType: contentType
        )
    }

    private static func s3Timestamp(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
