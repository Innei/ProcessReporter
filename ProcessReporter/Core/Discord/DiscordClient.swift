//
//  DiscordClient.swift
//  ProcessReporter
//
//  Created by Codex on 2025/8/27.
//

import Foundation

protocol DiscordClient: AnyObject {
    var isConnected: Bool { get }
    func initialize(applicationId: String)
    func setActivity(
        details: String?,
        state: String?,
        startTimestamp: Int64?,
        endTimestamp: Int64?,
        largeImageKey: String?,
        largeImageText: String?,
        smallImageKey: String?,
        smallImageText: String?
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
    }

    func setActivity(
        details: String?,
        state: String?,
        startTimestamp: Int64?,
        endTimestamp: Int64?,
        largeImageKey: String?,
        largeImageText: String?,
        smallImageKey: String?,
        smallImageText: String?
    ) {
        guard isConnected else {
            NSLog("[Discord] Noop client not connected; skipping activity")
            return
        }
        NSLog("[Discord] Noop setActivity details=\(details ?? "") state=\(state ?? "")")
    }

    func clearActivity() {
        NSLog("[Discord] Noop clearActivity")
    }

    func shutdown() {
        isConnected = false
        NSLog("[Discord] Noop shutdown")
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
