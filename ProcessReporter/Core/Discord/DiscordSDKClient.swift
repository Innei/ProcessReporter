//
//  DiscordSDKClient.swift
//  ProcessReporter
//
//  Swift wrapper conforming to DiscordClient backed by DiscordSDKBridge.
//

import Foundation

final class DiscordSDKClient: NSObject, DiscordClient {
    private let bridge = DiscordSDKBridge.sharedInstance()
    private var applicationId: String?
    private var activityCompletion: ((Result<Void, Error>) -> Void)?
    private var activityRequestCounter: UInt64 = 0
    private var activeActivityRequestIdentifier: UInt64?
    private var activityClearCompletions = [CheckedContinuation<Void, Error>]()
    private var activityClearInProgress = false

    private(set) var isConnected: Bool = false
    private(set) var connectionGeneration: UInt64 = 0

    override init() {
        super.init()
        bridge.delegate = self
    }

    func initialize(applicationId: String) {
        if isConnected, self.applicationId == applicationId {
            return
        }

        advanceConnectionGeneration()

        if self.applicationId != nil, self.applicationId != applicationId {
            bridge.shutdown()
            isConnected = false
        }

        self.applicationId = applicationId
		bridge.initialize(withApplicationId: applicationId)
        // DiscordCreate is synchronous. Reflect the bridge state immediately
        // instead of failing the first report while the delegate callback waits
        // on the next main-run-loop turn.
        isConnected = bridge.isConnected
        DiscordDebugStore.shared.update { snapshot in
            snapshot.clientKind = "sdk"
            snapshot.isConnected = isConnected
            snapshot.lastOutcome = isConnected ? "initialized" : "initialization failed"
        }
    }

    func setActivity(
        details: String?,
        state: String?,
        activityType: DiscordActivityType?,
        startTimestamp: Int64?,
        endTimestamp: Int64?,
        largeImageKey: String?,
        largeImageText: String?,
        smallImageKey: String?,
        smallImageText: String?,
        buttons: [DiscordButton]?
    ) async throws {
        try Task.checkCancellation()
        guard isConnected else { throw DiscordClientError.notConnected }
        guard activityCompletion == nil, !activityClearInProgress else {
            throw DiscordClientError.updateAlreadyInProgress
        }

        var btnsArray: [[String: String]]? = nil
        if let buttons, !buttons.isEmpty {
            btnsArray = buttons.prefix(2).map { ["label": $0.label, "url": $0.url] }
        }

        activityRequestCounter &+= 1
        if activityRequestCounter == 0 {
            activityRequestCounter = 1
        }
        let requestIdentifier = activityRequestCounter
        activeActivityRequestIdentifier = requestIdentifier

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                activityCompletion = { result in
                    continuation.resume(with: result)
                }
                bridge.setActivityWithDetails(details,
                                              state: state,
                                              activityType: activityType.map { NSNumber(value: $0.rawValue) },
                                              startTimestamp: startTimestamp.map(NSNumber.init(value:)),
                                              endTimestamp: endTimestamp.map(NSNumber.init(value:)),
                                              largeImageKey: largeImageKey,
                                              largeImageText: largeImageText,
                                              smallImageKey: smallImageKey,
                                              smallImageText: smallImageText,
                                              buttons: btnsArray)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self,
                      self.activeActivityRequestIdentifier == requestIdentifier
                else { return }
                self.bridge.cancelPendingActivityUpdate()
            }
        }
        try Task.checkCancellation()
    }

    func clearActivity() async throws {
        guard isConnected else { return }

        try await withCheckedThrowingContinuation { continuation in
            activityClearCompletions.append(continuation)
            guard !activityClearInProgress else { return }
            activityClearInProgress = true
            bridge.clearActivity()
        }
        try Task.checkCancellation()
    }

    func shutdown() {
        advanceConnectionGeneration()
        bridge.shutdown()
        applicationId = nil
        isConnected = false
        DiscordDebugStore.shared.update { snapshot in
            snapshot.clientKind = "sdk"
            snapshot.isConnected = false
            snapshot.lastOutcome = "shutdown"
        }
    }

    private func advanceConnectionGeneration() {
        connectionGeneration &+= 1
        if connectionGeneration == 0 {
            connectionGeneration = 1
        }
    }
}

extension DiscordSDKClient: @preconcurrency DiscordSDKBridgeDelegate {
    func discordSDKDidConnect(_ bridge: DiscordSDKBridge) {
        isConnected = true
        NSLog("[Discord] Bridge connected")
        DiscordDebugStore.shared.update { snapshot in
            snapshot.clientKind = "sdk"
            snapshot.isConnected = true
            snapshot.lastOutcome = "connected"
            snapshot.lastReason = nil
        }
    }

    func discordSDKDidDisconnect(_ bridge: DiscordSDKBridge, error: Error?) {
        isConnected = false
        NSLog("[Discord] Bridge disconnected: \(error?.localizedDescription ?? "-")")
        DiscordDebugStore.shared.update { snapshot in
            snapshot.clientKind = "sdk"
            snapshot.isConnected = false
            snapshot.lastOutcome = "disconnected"
            snapshot.lastReason = error?.localizedDescription
        }
    }

    func discordSDK(
        _ bridge: DiscordSDKBridge,
        didCompleteActivityUpdateWithError error: Error?
    ) {
        guard let completion = activityCompletion else { return }
        activityCompletion = nil
        activeActivityRequestIdentifier = nil
        if let error {
            completion(.failure(error))
        } else {
            completion(.success(()))
        }
    }

    func discordSDK(
        _ bridge: DiscordSDKBridge,
        didCompleteActivityClearWithError error: Error?
    ) {
        let completions = activityClearCompletions
        activityClearCompletions.removeAll()
        activityClearInProgress = false
        for completion in completions {
            if let error {
                completion.resume(throwing: error)
            } else {
                completion.resume()
            }
        }
    }
}
