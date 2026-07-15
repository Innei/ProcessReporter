import Foundation

enum OnboardingStep: String, CaseIterable, Identifiable {
    case welcome
    case sources
    case destination
    case iconHosting
    case review

    var id: String { rawValue }

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .sources: return "Sources & Privacy"
        case .destination: return "Destination"
        case .iconHosting: return "Icon Hosting"
        case .review: return "Review"
        }
    }

    var symbolName: String {
        switch self {
        case .welcome: return "person.wave.2"
        case .sources: return "hand.raised"
        case .destination: return "dot.radiowaves.left.and.right"
        case .iconHosting: return "externaldrive.badge.icloud"
        case .review: return "checkmark.circle"
        }
    }
}

@MainActor
final class OnboardingStore: ObservableObject {
    @Published var currentStep: OnboardingStep = .welcome
    @Published var selectedDestination: SettingsDestination?
    @Published var configuredSheet: SettingsDestination?
    @Published private(set) var preview: PresenceReviewPreview?
    @Published private(set) var isLoadingPreview = false

    func steps(using settingsStore: SettingsStore) -> [OnboardingStep] {
        var values: [OnboardingStep] = [.welcome, .sources, .destination]
        if shouldOfferIconHosting(using: settingsStore) {
            values.append(.iconHosting)
        }
        values.append(.review)
        return values
    }

    func advance(using settingsStore: SettingsStore) {
        let values = steps(using: settingsStore)
        guard let index = values.firstIndex(of: currentStep), index + 1 < values.count else {
            return
        }
        currentStep = values[index + 1]
        if currentStep == .review {
            Task { await refreshPreview() }
        }
    }

    func moveBack(using settingsStore: SettingsStore) {
        let values = steps(using: settingsStore)
        guard let index = values.firstIndex(of: currentStep), index > 0 else { return }
        currentStep = values[index - 1]
    }

    func refreshPreview() async {
        isLoadingPreview = true
        preview = await PresencePreviewService.captureCurrent()
        isLoadingPreview = false
    }

    private func shouldOfferIconHosting(using settingsStore: SettingsStore) -> Bool {
        selectedDestination == .mixSpace
            || settingsStore.mixSpaceIntegration.isEnabled
            || settingsStore.mixSpaceIntegration.hasPresenceDestinationConfiguration
    }
}

