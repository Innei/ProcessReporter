import Foundation

@MainActor
struct PresencePopoverActions {
    let openSettings: () -> Void
    let openPrivacyRules: (String?) -> Void
    let openDestinations: () -> Void
    let openDestination: (PresenceDestinationID) -> Void
    let openIconHosting: () -> Void
    let dismiss: () -> Void
    let quit: () -> Void
}
