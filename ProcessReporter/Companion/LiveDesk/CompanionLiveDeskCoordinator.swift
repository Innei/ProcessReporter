import AppKit
import Foundation
import RxSwift

enum CompanionLiveDeskRuntimeState: Equatable, Sendable {
    case disabled
    case connecting
    case updateRequired
    case serverFeatureUnavailable
    case active
    case degraded
    case suspended
}

/// Main-actor lifecycle owner for the initial application-only Live Desk slice.
/// It performs a fresh privacy evaluation for every semantic update and heartbeat;
/// no raw or previously retained snapshot is replayed after wake or reconnect.
@MainActor
final class CompanionLiveDeskCoordinator {
    private let connectionStore: CompanionConnectionStore
    private let capture: CompanionPresenceCapture
    private let clientVersion: String
    private let authorityRegistry = CompanionPresenceAuthorityRegistry()

    private(set) var state: CompanionLiveDeskRuntimeState = .disabled

    private var generation = 0
    private var setupTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var networkObserver: NSObjectProtocol?
    private var mediaObserverID: UUID?
    private var preferenceObservers = DisposeBag()
    private var refreshRequested = false
    private var requestedLeaseSeconds = 90
    private var minimumSendInterval: Duration = .zero
    private var lastSendStartedAt: ContinuousClock.Instant?
    private var supportsMediaTimeline = false
    private var isShuttingDown = false
    private var client: (any CompanionPresenceSending)? {
        authorityRegistry.currentClient
    }

    convenience init(connectionStore: CompanionConnectionStore) {
        self.init(
            connectionStore: connectionStore,
            capture: CompanionPresenceCapture(),
            clientVersion: Self.defaultClientVersion
        )
    }

    init(
        connectionStore: CompanionConnectionStore,
        capture: CompanionPresenceCapture,
        clientVersion: String
    ) {
        self.connectionStore = connectionStore
        self.capture = capture
        self.clientVersion = clientVersion
    }

    func start() {
        guard !isShuttingDown else { return }
        installNetworkObserverIfNeeded()
        // Lazily creates the shared NWPathMonitor. Its first callback is a
        // transition from unknown and therefore also repairs startup-offline.
        _ = isNetworkAvailable()
        let currentGeneration = beginNewGeneration(state: .connecting)
        setupTask = Task { @MainActor [weak self] in
            await self?.configure(generation: currentGeneration)
        }
    }

    func handleSleepOrLock() {
        // NSWorkspace sleep and DistributedNotificationCenter lock can describe
        // the same suspension. The first notification owns the only required
        // ordered clear; later notifications must not cancel it.
        guard !isShuttingDown, state != .suspended else { return }
        let clearClient = client
        _ = beginNewGeneration(state: .suspended)
        guard let clearClient else { return }
        cleanupTask = Task {
            await CompanionPresenceCleanup.clearBestEffort(
                using: clearClient,
                reason: .sleep,
                timeout: .milliseconds(500)
            )
        }
    }

    func handleWakeOrUnlock() {
        // Wake and unlock commonly arrive as a pair. One restart is sufficient;
        // explicitly join the bounded cleanup task before capability negotiation
        // so Task scheduling cannot enqueue the wake snapshot ahead of clear.
        guard !isShuttingDown, state == .suspended else { return }
        let suspendedGeneration = generation
        let pendingCleanup = cleanupTask
        state = .connecting
        wakeTask = Task { @MainActor [weak self] in
            await pendingCleanup?.value
            guard let self,
                  !Task.isCancelled,
                  !self.isShuttingDown,
                  self.generation == suspendedGeneration,
                  self.state == .connecting
            else {
                return
            }
            self.cleanupTask = nil
            self.wakeTask = nil
            self.start()
        }
    }

    /// Stops capture immediately and gives the ordered clear a bounded window.
    /// Lease expiry remains the correctness fallback if the process or network
    /// cannot complete this best-effort request.
    func shutdown() async {
        if isShuttingDown {
            await cleanupTask?.value
            return
        }
        isShuttingDown = true
        if state != .suspended {
            let clearClient = client
            _ = beginNewGeneration(state: .suspended)
            if let clearClient {
                cleanupTask = Task {
                    await CompanionPresenceCleanup.clearBestEffort(
                        using: clearClient,
                        reason: .shutdown,
                        timeout: .milliseconds(500)
                    )
                }
            }
        }
        // A concurrent or preceding sleep/lock already owns the clear. Join its
        // bounded task instead of cancelling it and losing the only mutation.
        await cleanupTask?.value
        cleanupTask = nil
        authorityRegistry.discard()
        removeNetworkObserver()
        state = .disabled
    }

    /// Coalesces activation and heartbeat events. While one request is in flight,
    /// all later events collapse into one fresh capture of the latest desired state.
    func requestFreshSnapshot() {
        guard client != nil, state == .active || state == .degraded else { return }
        refreshRequested = true
        guard refreshTask == nil else { return }

        let currentGeneration = generation
        refreshTask = Task { @MainActor [weak self] in
            await self?.runRefreshLoop(generation: currentGeneration)
        }
    }

    private func configure(generation currentGeneration: Int) async {
        do {
            guard let metadata = try await connectionStore.loadMetadata() else {
                finishConfigurationIfCurrent(
                    .disabled,
                    generation: currentGeneration,
                    discardingAuthority: true
                )
                return
            }
            guard metadata.isLiveDeskEnabled else {
                finishConfigurationIfCurrent(
                    .disabled,
                    generation: currentGeneration,
                    discardingAuthority: true
                )
                return
            }
            guard generation == currentGeneration,
                  let connection = try await connectionStore.loadEnabledConnection()
            else {
                return
            }

            let capabilityClient = CompanionHTTPClient(server: connection.server)
            let capabilities = try await capabilityClient.fetchCapabilities()
            guard generation == currentGeneration else { return }

            switch CompanionCapabilityNegotiator.negotiatePresence(
                capabilities.data,
                clientVersion: clientVersion
            ) {
            case .available(let configuration):
                requestedLeaseSeconds = min(
                    max(90, configuration.minimumLeaseSeconds),
                    configuration.maximumLeaseSeconds
                )
                let heartbeatSeconds = min(
                    configuration.recommendedHeartbeatSeconds,
                    max(1, requestedLeaseSeconds / 3)
                )
                minimumSendInterval = .seconds(
                    60.0 / Double(configuration.requestsPerMinute)
                )
                supportsMediaTimeline = configuration.supportsMediaTimeline
                let mapper = CompanionPresenceDTOMapper(
                    minimumLeaseSeconds: configuration.minimumLeaseSeconds,
                    maximumLeaseSeconds: configuration.maximumLeaseSeconds
                )
                _ = authorityRegistry.resolve(
                    for: CompanionPresenceAuthorityKey(
                        baseURL: connection.server.baseURL,
                        deviceID: connection.metadata.deviceID
                    )
                ) {
                    let sequencer = CompanionPresenceSequencer(
                        deviceID: connection.metadata.deviceID,
                        pairingNextSequence: connection.metadata.pairingNextSequence,
                        persistence: UserDefaultsCompanionSequencePersistence()
                    )
                    return YohakuPresenceClient(
                        credential: connection.credential,
                        mapper: mapper,
                        httpClient: CompanionHTTPClient(
                            server: connection.server,
                            maximumPayloadBytes: configuration.maximumPayloadBytes,
                            clientVersion: clientVersion
                        ),
                        sequencer: sequencer
                    )
                }
                state = .active
                installActivationObserver()
                installPreferenceObservers()
                reconcileMediaObservation()
                startHeartbeat(
                    seconds: heartbeatSeconds,
                    generation: currentGeneration
                )
                setupTask = nil
                requestFreshSnapshot()

            case .clientUpdateRequired:
                finishConfigurationIfCurrent(
                    .updateRequired,
                    generation: currentGeneration,
                    discardingAuthority: true
                )

            case .schemaUnsupported, .featureUnavailable:
                finishConfigurationIfCurrent(
                    .serverFeatureUnavailable,
                    generation: currentGeneration,
                    discardingAuthority: true
                )
                scheduleReconnect(after: .seconds(300), generation: currentGeneration)

            case .invalidCapabilities:
                finishConfigurationIfCurrent(.degraded, generation: currentGeneration)
                scheduleReconnect(after: .seconds(300), generation: currentGeneration)
            }
        } catch is CancellationError {
            return
        } catch {
            finishConfigurationIfCurrent(.degraded, generation: currentGeneration)
            scheduleReconnect(after: .seconds(30), generation: currentGeneration)
        }
    }

    private func runRefreshLoop(generation currentGeneration: Int) async {
        defer {
            if generation == currentGeneration {
                refreshTask = nil
            }
        }

        while generation == currentGeneration, refreshRequested, !Task.isCancelled {
            refreshRequested = false
            guard let client else { return }
            if let lastSendStartedAt {
                let clock = ContinuousClock()
                let earliestSend = lastSendStartedAt.advanced(by: minimumSendInterval)
                let remaining = clock.now.duration(to: earliestSend)
                if remaining > .zero {
                    do {
                        try await Task.sleep(for: remaining)
                    } catch {
                        return
                    }
                    guard generation == currentGeneration else { return }
                }
            }
            do {
                lastSendStartedAt = ContinuousClock().now
                let snapshot = try await capture.capture(
                    mediaTimelineEnabled: supportsMediaTimeline,
                    continuityGeneration: currentGeneration
                )
                guard generation == currentGeneration, !Task.isCancelled else { return }
                _ = try await client.replacePresence(
                    with: snapshot,
                    requestedLeaseSeconds: requestedLeaseSeconds
                )
                guard generation == currentGeneration else { return }
                state = .active
            } catch is CancellationError {
                return
            } catch {
                guard generation == currentGeneration else { return }
                if CompanionPresenceMutationFailurePolicy.action(for: error)
                    == .refreshCapabilities
                {
                    restartAfterCapabilityRejection(generation: currentGeneration)
                    return
                }
                // Diagnostics expose only this fixed state; the error and snapshot
                // content are deliberately not logged or retained.
                state = .degraded
                refreshRequested = false
                return
            }
        }
    }

    private func restartAfterCapabilityRejection(generation currentGeneration: Int) {
        guard generation == currentGeneration, !isShuttingDown else { return }
        // The current mapper and writer have been rejected at the schema
        // boundary. Remove their heartbeat and authority before fetching a new
        // capability baseline; no blind retry may use the rejected schema.
        heartbeatTask?.cancel()
        heartbeatTask = nil
        refreshRequested = false
        authorityRegistry.discard()
        start()
    }

    private func startHeartbeat(seconds: Int, generation currentGeneration: Int) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            while let self,
                  self.generation == currentGeneration,
                  !Task.isCancelled
            {
                do {
                    try await Task.sleep(for: .seconds(seconds))
                } catch {
                    return
                }
                guard self.generation == currentGeneration else { return }
                self.requestFreshSnapshot()
            }
        }
    }

    private func installActivationObserver() {
        removeActivationObserver()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.requestFreshSnapshot()
            }
        }
    }

    private func removeActivationObserver() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    private func installPreferenceObservers() {
        preferenceObservers = DisposeBag()

        PreferencesDataModel.enabledTypes
            .skip(1)
            .subscribe(onNext: { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.reconcileMediaObservation()
                    self.requestFreshSnapshot()
                }
            })
            .disposed(by: preferenceObservers)

        let requestRefresh: () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                self?.requestFreshSnapshot()
            }
        }
        PreferencesDataModel.presencePrivacyConfiguration
            .skip(1)
            .subscribe(onNext: { _ in requestRefresh() })
            .disposed(by: preferenceObservers)
        PreferencesDataModel.filteredProcesses
            .skip(1)
            .subscribe(onNext: { _ in requestRefresh() })
            .disposed(by: preferenceObservers)
        PreferencesDataModel.filteredMediaProcesses
            .skip(1)
            .subscribe(onNext: { _ in requestRefresh() })
            .disposed(by: preferenceObservers)
        PreferencesDataModel.mappingList
            .skip(1)
            .subscribe(onNext: { _ in requestRefresh() })
            .disposed(by: preferenceObservers)
        PreferencesDataModel.shareWindowTitles
            .skip(1)
            .subscribe(onNext: { _ in requestRefresh() })
            .disposed(by: preferenceObservers)
        PreferencesDataModel.ignoreNullArtist
            .skip(1)
            .subscribe(onNext: { _ in requestRefresh() })
            .disposed(by: preferenceObservers)
    }

    private func reconcileMediaObservation() {
        let shouldObserve = supportsMediaTimeline
            && PreferencesDataModel.enabledTypes.value.types.contains(.media)
            && (state == .active || state == .degraded)
        if shouldObserve, mediaObserverID == nil {
            mediaObserverID = MediaInfoManager.addPlaybackStateObserver { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.requestFreshSnapshot()
                }
            }
        } else if !shouldObserve {
            removeMediaObservation()
        }
    }

    private func removeMediaObservation() {
        guard let mediaObserverID else { return }
        MediaInfoManager.removePlaybackStateObserver(mediaObserverID)
        self.mediaObserverID = nil
    }

    private func installNetworkObserverIfNeeded() {
        guard networkObserver == nil else { return }
        networkObserver = NotificationCenter.default.addObserver(
            forName: .processReporterNetworkAvailabilityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let isAvailable = notification.userInfo?[
                NetworkAvailabilityNotificationKey.isAvailable
            ] as? Bool else {
                return
            }
            Task { @MainActor [weak self] in
                self?.handleNetworkAvailabilityChanged(isAvailable: isAvailable)
            }
        }
    }

    private func removeNetworkObserver() {
        if let networkObserver {
            NotificationCenter.default.removeObserver(networkObserver)
            self.networkObserver = nil
        }
    }

    private func handleNetworkAvailabilityChanged(isAvailable: Bool) {
        guard isAvailable else {
            if state == .active {
                state = .degraded
            }
            return
        }

        if client != nil {
            requestFreshSnapshot()
        } else if state == .degraded {
            start()
        }
    }

    private func scheduleReconnect(
        after delay: Duration,
        generation currentGeneration: Int
    ) {
        guard generation == currentGeneration else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, self.generation == currentGeneration else { return }
            self.start()
        }
    }

    @discardableResult
    private func beginNewGeneration(state newState: CompanionLiveDeskRuntimeState) -> Int {
        generation &+= 1
        setupTask?.cancel()
        heartbeatTask?.cancel()
        refreshTask?.cancel()
        reconnectTask?.cancel()
        wakeTask?.cancel()
        setupTask = nil
        heartbeatTask = nil
        refreshTask = nil
        reconnectTask = nil
        wakeTask = nil
        refreshRequested = false
        minimumSendInterval = .zero
        lastSendStartedAt = nil
        supportsMediaTimeline = false
        preferenceObservers = DisposeBag()
        removeMediaObservation()
        removeActivationObserver()
        state = newState
        return generation
    }

    private func finishConfigurationIfCurrent(
        _ newState: CompanionLiveDeskRuntimeState,
        generation currentGeneration: Int,
        discardingAuthority: Bool = false
    ) {
        guard generation == currentGeneration else { return }
        setupTask = nil
        if discardingAuthority {
            authorityRegistry.discard()
        }
        state = newState
    }

    private static var defaultClientVersion: String {
        CompanionClientVersion.current
    }

    deinit {
        setupTask?.cancel()
        heartbeatTask?.cancel()
        refreshTask?.cancel()
        reconnectTask?.cancel()
        cleanupTask?.cancel()
        wakeTask?.cancel()
    }
}
