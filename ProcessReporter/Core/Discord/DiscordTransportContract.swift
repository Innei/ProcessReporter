//
//  DiscordTransportContract.swift
//  ProcessReporter
//

import Foundation

enum DiscordTransportContract {
    private static let minimumTextCharacterCount = 2
    private static let maximumStringByteCount = 127

    /// Discord rejects optional activity and asset tooltip text shorter than
    /// two characters. Omitting unsupported text keeps the rest of the Rich
    /// Presence payload deliverable without adding visible or invisible filler.
    static func text(_ value: String?) -> String? {
        guard let value = boundedString(value),
              value.count >= minimumTextCharacterCount
        else { return nil }
        return value
    }

    /// Asset identifiers may contain a single character, so they only need to
    /// satisfy the concrete SDK buffer limit.
    static func assetIdentifier(_ value: String?) -> String? {
        boundedString(value)
    }

    private static func boundedString(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard value.utf8.count > maximumStringByteCount else { return value }

        var result = ""
        var byteCount = 0
        for character in value {
            let fragment = String(character)
            let fragmentByteCount = fragment.utf8.count
            guard byteCount + fragmentByteCount <= maximumStringByteCount else { break }
            result.append(character)
            byteCount += fragmentByteCount
        }
        return result.isEmpty ? nil : result
    }
}
