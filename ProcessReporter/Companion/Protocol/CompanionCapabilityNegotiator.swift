import Foundation

struct CompanionNegotiatedPresenceConfiguration: Equatable, Sendable {
    let maximumPayloadBytes: Int
    let requestsPerMinute: Int
    let minimumLeaseSeconds: Int
    let maximumLeaseSeconds: Int
    let recommendedHeartbeatSeconds: Int
    let maximumClockSkewSeconds: Int
    let supportsMediaTimeline: Bool
}

enum CompanionPresenceNegotiationResult: Equatable, Sendable {
    case available(CompanionNegotiatedPresenceConfiguration)
    case clientUpdateRequired(minimumVersion: String)
    case schemaUnsupported
    case featureUnavailable
    case invalidCapabilities
}

enum CompanionCapabilityNegotiator {
    static func negotiatePresence(
        _ capabilities: CompanionCapabilitiesV2,
        clientVersion: String
    ) -> CompanionPresenceNegotiationResult {
        guard
            let clientVersion = CompanionSemanticVersion(clientVersion),
            let minimumVersion = CompanionSemanticVersion(capabilities.minimumClientVersion),
            let configuration = validatedPresenceConfiguration(capabilities)
        else {
            return .invalidCapabilities
        }

        guard clientVersion >= minimumVersion else {
            return .clientUpdateRequired(minimumVersion: capabilities.minimumClientVersion)
        }
        guard capabilities.presenceSchemaVersions.contains(
            CompanionProtocolV2.presenceSchemaVersion
        ) else {
            return .schemaUnsupported
        }
        guard capabilities.features.liveDesk else {
            return .featureUnavailable
        }
        return .available(configuration)
    }

    private static func validatedPresenceConfiguration(
        _ capabilities: CompanionCapabilitiesV2
    ) -> CompanionNegotiatedPresenceConfiguration? {
        let limits = capabilities.limits
        guard
            limits.presencePayloadBytes > 0,
            limits.presenceRequestsPerMinute > 0,
            limits.presenceLeaseMinSeconds > 0,
            limits.presenceLeaseMinSeconds <= limits.presenceLeaseMaxSeconds,
            limits.recommendedHeartbeatSeconds >= limits.presenceLeaseMinSeconds,
            limits.recommendedHeartbeatSeconds <= limits.presenceLeaseMaxSeconds,
            limits.maximumClockSkewSeconds >= 0,
            capabilities.presenceSchemaVersions.allSatisfy({ $0 > 0 }),
            capabilities.momentSchemaVersions.allSatisfy({ $0 > 0 })
        else {
            return nil
        }

        return CompanionNegotiatedPresenceConfiguration(
            maximumPayloadBytes: limits.presencePayloadBytes,
            requestsPerMinute: limits.presenceRequestsPerMinute,
            minimumLeaseSeconds: limits.presenceLeaseMinSeconds,
            maximumLeaseSeconds: limits.presenceLeaseMaxSeconds,
            recommendedHeartbeatSeconds: limits.recommendedHeartbeatSeconds,
            maximumClockSkewSeconds: limits.maximumClockSkewSeconds,
            supportsMediaTimeline: capabilities.features.mediaTimeline
        )
    }
}

private struct CompanionSemanticVersion: Comparable, Sendable {
    private enum PrereleaseIdentifier: Equatable, Sendable {
        case numeric(Int)
        case text(String)
    }

    private let major: Int
    private let minor: Int
    private let patch: Int
    private let prerelease: [PrereleaseIdentifier]?

    init?(_ rawValue: String) {
        let buildParts = rawValue.split(
            separator: "+",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard
            (1...2).contains(buildParts.count),
            !buildParts[0].isEmpty,
            buildParts.count == 1 || Self.isValidIdentifierList(buildParts[1], numericLeadingZero: true)
        else {
            return nil
        }

        let releaseParts = buildParts[0].split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard !releaseParts[0].isEmpty else { return nil }
        let core = releaseParts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard
            core.count == 3,
            let major = Self.parseCoreNumber(core[0]),
            let minor = Self.parseCoreNumber(core[1]),
            let patch = Self.parseCoreNumber(core[2])
        else {
            return nil
        }

        let prerelease: [PrereleaseIdentifier]?
        if releaseParts.count == 2 {
            guard
                Self.isValidIdentifierList(releaseParts[1], numericLeadingZero: false)
            else {
                return nil
            }
            prerelease = releaseParts[1].split(separator: ".").map { identifier in
                if let number = Int(identifier) {
                    return .numeric(number)
                }
                return .text(String(identifier))
            }
        } else {
            prerelease = nil
        }

        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        let lhsCore = [lhs.major, lhs.minor, lhs.patch]
        let rhsCore = [rhs.major, rhs.minor, rhs.patch]
        if lhsCore != rhsCore {
            return lhsCore.lexicographicallyPrecedes(rhsCore)
        }

        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        case (let lhsIdentifiers?, let rhsIdentifiers?):
            for (lhsIdentifier, rhsIdentifier) in zip(lhsIdentifiers, rhsIdentifiers) {
                if lhsIdentifier == rhsIdentifier { continue }
                switch (lhsIdentifier, rhsIdentifier) {
                case (.numeric(let lhsNumber), .numeric(let rhsNumber)):
                    return lhsNumber < rhsNumber
                case (.numeric, .text):
                    return true
                case (.text, .numeric):
                    return false
                case (.text(let lhsText), .text(let rhsText)):
                    return lhsText < rhsText
                }
            }
            return lhsIdentifiers.count < rhsIdentifiers.count
        }
    }

    private static func parseCoreNumber(_ value: Substring) -> Int? {
        guard
            !value.isEmpty,
            value.allSatisfy(\.isNumber),
            value == "0" || value.first != "0"
        else {
            return nil
        }
        return Int(value)
    }

    private static func isValidIdentifierList(
        _ value: Substring,
        numericLeadingZero: Bool
    ) -> Bool {
        let identifiers = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !identifiers.isEmpty else { return false }
        return identifiers.allSatisfy { identifier in
            guard
                !identifier.isEmpty,
                identifier.unicodeScalars.allSatisfy({ scalar in
                    scalar.isASCII && (
                        CharacterSet.alphanumerics.contains(scalar) || scalar == "-"
                    )
                })
            else {
                return false
            }
            if !numericLeadingZero,
               identifier.allSatisfy(\.isNumber),
               identifier.count > 1,
               identifier.first == "0"
            {
                return false
            }
            return true
        }
    }
}
