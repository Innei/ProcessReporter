import Foundation

struct CompanionMediaSemanticIdentity: Equatable, Sendable {
    let kind: CompanionMediaKind
    let title: String?
    let artist: String?
    let album: String?
    let playerDisplayName: String?
    let durationSeconds: Double?
}

actor CompanionMediaSessionTracker {
    private var currentIdentity: CompanionMediaSemanticIdentity?
    private var currentSessionID: UUID?

    func sessionID(for identity: CompanionMediaSemanticIdentity) -> UUID {
        if currentIdentity == identity, let currentSessionID {
            return currentSessionID
        }

        let nextSessionID = UUID()
        currentIdentity = identity
        currentSessionID = nextSessionID
        return nextSessionID
    }

    func reset() {
        currentIdentity = nil
        currentSessionID = nil
    }
}
