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

protocol DiscordClient: AnyObject {
    var isConnected: Bool { get }
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
    )
    func clearActivity()
    func shutdown()
}

final class NoopDiscordClient: DiscordClient {
    private(set) var isConnected: Bool = false

    func initialize(applicationId: String) {
        // Placeholder for SDK init. Mark as connected for flow testing.
        isConnected = !applicationId.isEmpty
        NSLog("[Discord] Noop client initialized: connected=\(isConnected)")
        DiscordDebugStore.shared.update { snapshot in
            snapshot.clientKind = "noop"
            snapshot.isConnected = isConnected
            snapshot.lastOutcome = "initialized"
            snapshot.lastReason = isConnected ? nil : "empty applicationId"
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
    ) {
        guard isConnected else {
            NSLog("[Discord] Noop client not connected; skipping activity")
            return
        }
        if let buttons, !buttons.isEmpty {
            let desc = buttons.map { "{label:\($0.label),url:\($0.url)}" }.joined(separator: ",")
            NSLog("[Discord] Noop setActivity details=\(details ?? "") state=\(state ?? "") type=\(activityType?.rawValue ?? -1) buttons=[\(desc)]")
        } else {
            NSLog("[Discord] Noop setActivity details=\(details ?? "") state=\(state ?? "") type=\(activityType?.rawValue ?? -1)")
        }
    }

    func clearActivity() {
        NSLog("[Discord] Noop clearActivity")
        DiscordDebugStore.shared.update { snapshot in
            snapshot.clientKind = "noop"
            snapshot.lastOutcome = "clearActivity"
        }
    }

    func shutdown() {
        isConnected = false
        NSLog("[Discord] Noop shutdown")
        DiscordDebugStore.shared.update { snapshot in
            snapshot.clientKind = "noop"
            snapshot.isConnected = false
            snapshot.lastOutcome = "shutdown"
        }
    }
}

enum DiscordClientProvider {
    // Prefer bridge-backed client; fall back to noop if unavailable
    static var shared: DiscordClient = {
        // Attempt to instantiate the bridge-backed client dynamically
        if NSClassFromString("DiscordSDKBridge") != nil {
            return DiscordSDKClient()
        } else {
            return NoopDiscordClient()
        }
    }()
}
