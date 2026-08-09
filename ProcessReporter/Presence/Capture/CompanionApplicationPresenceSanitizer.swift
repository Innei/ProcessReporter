import Foundation

enum CompanionApplicationPresenceSanitizer {
    /// Converts already-decided privacy inputs into the canonical sanitized
    /// domain. Bundle identifiers and other raw process metadata are not accepted
    /// by this boundary and therefore cannot accidentally enter the DTO mapper.
    static func sanitize(
        capturedDisplayName: String,
        mappedDisplayName: String?,
        displayAlias: String?,
        capturedWindowTitle: String?,
        sharesApplication: Bool,
        sharesWindowTitle: Bool,
        globalWindowTitleSharingEnabled: Bool
    ) throws -> SanitizedApplicationPresence? {
        guard sharesApplication else { return nil }

        let displayName = normalized(displayAlias)
            ?? normalized(mappedDisplayName)
            ?? capturedDisplayName
        let windowTitle = sharesWindowTitle && globalWindowTitleSharingEnabled
            ? capturedWindowTitle
            : nil

        return try SanitizedApplicationPresence(
            displayName: displayName,
            activity: nil,
            windowTitle: windowTitle,
            iconURL: nil
        )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
