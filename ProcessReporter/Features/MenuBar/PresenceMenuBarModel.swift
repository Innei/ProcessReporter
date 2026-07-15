import Combine
import Foundation
import RxSwift

@MainActor
final class PresenceMenuBarModel: ObservableObject {
    @Published private(set) var aggregateStatus: PresenceAggregateStatus = .paused
    @Published private(set) var isSharing = false
    @Published private(set) var canShare = false
    @Published private(set) var currentPresence: PresencePresentation?
    @Published private(set) var privacyTargetApplicationIdentifier: String?
    @Published private(set) var destinations: [PresenceDestinationPresentation] = []
    @Published private(set) var assetResolution: PresenceAssetResolution = .notRequested
    @Published private(set) var blockingMessage: String?

    private var runtimeStatus: PresenceRuntimeStatus = .ready
    private var latestDeliveryStates: [PresenceDestinationID: PresenceDeliveryState] = [:]
    private var persistenceError: String?
    private var activeDeliveryID: UUID?
    private let disposeBag = DisposeBag()

    init() {
        bindPreferences()
        refreshConfiguration()
    }

    var configuredDestinations: [PresenceDestinationPresentation] {
        destinations.filter { $0.configurationState != .notConfigured }
    }

    func setSharing(_ requestedValue: Bool) {
        if requestedValue, !canShare {
            blockingMessage = "Set up and enable a destination before sharing Presence."
            refreshAggregateStatus()
            return
        }

        guard PreferencesDataModel.setReportingEnabled(requestedValue) else {
            blockingMessage =
                "Sharing remains paused until credential storage is available."
            refreshConfiguration()
            return
        }

        if !requestedValue {
            currentPresence = nil
            runtimeStatus = .paused
        } else {
            blockingMessage = nil
            runtimeStatus = .ready
        }
        refreshConfiguration()
    }

    func publishCurrentPresence(_ report: ReportModel) {
        currentPresence = PresencePresentation(report: report)
        privacyTargetApplicationIdentifier = report.sourceProcessApplicationIdentifier
            ?? report.processInfoRaw?.applicationIdentifier
            ?? report.sourceMediaApplicationIdentifier
            ?? report.mediaInfoRaw?.applicationIdentifier
    }

    func clearCurrentPresence() {
        currentPresence = nil
        privacyTargetApplicationIdentifier = nil
    }

    func setRuntimeStatus(_ status: PresenceRuntimeStatus) {
        transitionRuntimeStatus(to: status)
        rebuildDestinations()
        refreshAggregateStatus()
    }

    func beginDelivery(to destinationIDs: [PresenceDestinationID]) -> UUID {
        let deliveryID = UUID()
        activeDeliveryID = deliveryID
        persistenceError = nil
        assetResolution = .notRequested
        transitionRuntimeStatus(to: .syncing)
        for destinationID in destinationIDs {
            latestDeliveryStates[destinationID] = .sending
        }
        rebuildDestinations()
        refreshAggregateStatus()
        return deliveryID
    }

    func completeDelivery(
        deliveryID: UUID,
        results: [PresenceDestinationDeliveryResult],
        assetResolution: PresenceAssetResolution,
        persistenceError: String? = nil
    ) {
        guard activeDeliveryID == deliveryID else { return }
        activeDeliveryID = nil
        for result in results {
            latestDeliveryStates[result.id] = result.state
        }
        self.assetResolution = assetResolution
        self.persistenceError = persistenceError
        // A path, pause, or source transition can invalidate a delivery while a
        // provider request is still unwinding. Its late completion may update the
        // audit result, but it must not clear the newer runtime reason.
        if runtimeStatus == .syncing {
            transitionRuntimeStatus(to: .ready)
        }

        rebuildDestinations()
        refreshAggregateStatus()
    }

    func refreshConfiguration() {
        isSharing = PreferencesDataModel.reportingAllowed
        canShare = PreferencesDataModel.hasCompletedOnboarding.value
            && PreferencesDataModel.hasEnabledConfiguredPresenceDestination

        if !isSharing {
            transitionRuntimeStatus(to: .paused)
        } else if runtimeStatus == .paused {
            transitionRuntimeStatus(to: .ready)
        }

        rebuildDestinations()
        if destinations.first(where: { $0.id == .mixSpace })?.configurationState != .ready {
            assetResolution = .notRequested
        }

        if PreferencesDataModel.integrationCredentialStoreUnavailable {
            blockingMessage =
                PreferencesDataModel.integrationCredentialRecoveryWarning
                ?? "Credential storage is unavailable."
        } else if blockingMessage?.contains("credential storage") == true
            || (canShare
                && blockingMessage == "Set up and enable a destination before sharing Presence.")
        {
            blockingMessage = nil
        }

        refreshAggregateStatus()
    }

    private func transitionRuntimeStatus(to status: PresenceRuntimeStatus) {
        runtimeStatus = status
        if status == .waitingForNetwork {
            blockingMessage = "Waiting for network"
        } else if blockingMessage == "Waiting for network" {
            blockingMessage = nil
        }

        guard status != .syncing else { return }
        if status == .paused {
            currentPresence = nil
        }

        let interruptedAt = Date()
        let sendingDestinationIDs = latestDeliveryStates.compactMap {
            $0.value == .sending ? $0.key : nil
        }
        for destinationID in sendingDestinationIDs {
            latestDeliveryStates[destinationID] = .skipped(
                message: "Delivery was interrupted.",
                date: interruptedAt
            )
        }
    }

    private func bindPreferences() {
        let relays: [Observable<Void>] = [
            PreferencesDataModel.isEnabled.map { _ in () },
            PreferencesDataModel.enabledTypes.map { _ in () },
            PreferencesDataModel.mixSpaceIntegration.map { _ in () },
            PreferencesDataModel.slackIntegration.map { _ in () },
            PreferencesDataModel.discordIntegration.map { _ in () },
            PreferencesDataModel.integrationCredentialsReady.map { _ in () },
            PreferencesDataModel.hasCompletedOnboarding.map { _ in () },
        ]

        Observable.merge(relays)
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] in
                self?.refreshConfiguration()
            })
            .disposed(by: disposeBag)
    }

    private func rebuildDestinations() {
        destinations = PresenceDestinationID.allCases.map { destinationID in
            PresenceDestinationPresentation(
                id: destinationID,
                configurationState: configurationState(for: destinationID),
                deliveryState: latestDeliveryStates[destinationID] ?? .never
            )
        }
    }

    private func configurationState(
        for destinationID: PresenceDestinationID
    ) -> PresenceDestinationConfigurationState {
        switch destinationID {
        case .mixSpace:
            let configuration = PreferencesDataModel.mixSpaceIntegration.value
            return configurationState(
                enabled: configuration.isEnabled,
                hasConfiguration: configuration.hasPresenceDestinationConfiguration,
                isValid: configuration.isValidPresenceDestination
            )
        case .slack:
            let configuration = PreferencesDataModel.slackIntegration.value
            return configurationState(
                enabled: configuration.isEnabled,
                hasConfiguration: configuration.hasPresenceDestinationConfiguration,
                isValid: configuration.isValidPresenceDestination
            )
        case .discord:
            let configuration = PreferencesDataModel.discordIntegration.value
            return configurationState(
                enabled: configuration.isEnabled,
                hasConfiguration: configuration.hasPresenceDestinationConfiguration,
                isValid: configuration.isValidPresenceDestination
            )
        }
    }

    private func configurationState(
        enabled: Bool,
        hasConfiguration: Bool,
        isValid: Bool
    ) -> PresenceDestinationConfigurationState {
        guard hasConfiguration else { return .notConfigured }
        guard isValid else { return .invalid }
        return enabled ? .ready : .disabled
    }

    private func refreshAggregateStatus() {
        if PreferencesDataModel.integrationCredentialStoreUnavailable || persistenceError != nil {
            aggregateStatus = .error
            return
        }
        if !canShare {
            aggregateStatus = .setupRequired
            return
        }
        if !isSharing || runtimeStatus == .paused {
            aggregateStatus = .paused
            return
        }
        if PreferencesDataModel.enabledTypes.value.types.isEmpty {
            aggregateStatus = .idle
            return
        }
        if runtimeStatus == .waitingForNetwork {
            let hasPreviousSuccess = destinations.contains { destination in
                destination.configurationState == .ready
                    && destination.deliveryState.isSuccess
            }
            aggregateStatus = hasPreviousSuccess ? .degraded : .error
            return
        }
        if runtimeStatus == .syncing {
            aggregateStatus = .syncing
            return
        }

        let attemptedStates = destinations.compactMap { destination -> PresenceDeliveryState? in
            guard destination.configurationState == .ready else { return nil }
            switch destination.deliveryState {
            case .never, .sending:
                return nil
            case .succeeded, .failed, .skipped:
                return destination.deliveryState
            }
        }
        let successes = attemptedStates.filter(\.isSuccess).count
        let failures = attemptedStates.filter(\.isFailure).count

        if failures > 0, successes == 0 {
            aggregateStatus = .error
        } else if failures > 0 || (assetResolution.isFailure && successes > 0) {
            aggregateStatus = .degraded
        } else {
            aggregateStatus = .ready
        }
    }
}
