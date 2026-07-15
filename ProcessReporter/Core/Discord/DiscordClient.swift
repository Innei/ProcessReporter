//
//  DiscordClient.swift
//  ProcessReporter
//
//  Created by Codex on 2025/8/27.
//

import Foundation

struct DiscordButton {
    let label: String
    let url: String
}

enum DiscordActivityType: Int {
    case playing = 0
    case streaming = 1
    case listening = 2
    case watching = 3
    case custom = 4
    case competing = 5
}

@MainActor
protocol DiscordClient: AnyObject {
    var isConnected: Bool { get }
    var connectionGeneration: UInt64 { get }
    func initialize(applicationId: String)
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
    ) async throws
    func clearActivity() async throws
    func shutdown()
}

final class NoopDiscordClient: DiscordClient {
    private(set) var isConnected: Bool = false
    private(set) var connectionGeneration: UInt64 = 0

    func initialize(applicationId: String) {
        advanceConnectionGeneration()
        isConnected = false
        NSLog("[Discord] Discord SDK unavailable; presence was not initialized")
        DiscordDebugStore.shared.update { snapshot in
            snapshot.clientKind = "noop"
            snapshot.isConnected = false
            snapshot.lastOutcome = "unavailable"
            snapshot.lastReason = "Discord SDK is unavailable"
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
        throw DiscordClientError.sdkUnavailable
    }

    func clearActivity() async throws {
        NSLog("[Discord] Noop clearActivity")
        DiscordDebugStore.shared.update { snapshot in
            snapshot.clientKind = "noop"
            snapshot.lastOutcome = "clearActivity"
        }
    }

    func shutdown() {
        advanceConnectionGeneration()
        isConnected = false
        NSLog("[Discord] Noop shutdown")
        DiscordDebugStore.shared.update { snapshot in
            snapshot.clientKind = "noop"
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

enum DiscordClientError: LocalizedError {
    case sdkUnavailable
    case notConnected
    case updateAlreadyInProgress

    var errorDescription: String? {
        switch self {
        case .sdkUnavailable:
            return "Discord SDK is unavailable"
        case .notConnected:
            return "Discord client is not connected"
        case .updateAlreadyInProgress:
            return "A Discord activity update is already in progress"
        }
    }
}

@MainActor
enum DiscordClientProvider {
    static let shared: DiscordClient = {
        if DiscordSDKBridge.isSDKAvailable() {
            return DiscordSDKClient()
        } else {
            return NoopDiscordClient()
        }
    }()
}
