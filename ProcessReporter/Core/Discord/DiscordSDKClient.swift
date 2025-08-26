//
//  DiscordSDKClient.swift
//  ProcessReporter
//
//  Swift wrapper conforming to DiscordClient backed by DiscordSDKBridge.
//

import Foundation

final class DiscordSDKClient: NSObject, DiscordClient {
    private let bridge = DiscordSDKBridge.sharedInstance()

    private(set) var isConnected: Bool = false

    override init() {
        super.init()
        bridge.delegate = self
    }

    func initialize(applicationId: String) {
        // Use the exact imported selector name for robustness
		bridge.initialize(withApplicationId: applicationId)
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
        bridge.setActivityWithDetails(details,
                                      state: state,
                                      startTimestamp: startTimestamp == nil ? nil : NSNumber(value: startTimestamp!),
                                      endTimestamp: endTimestamp == nil ? nil : NSNumber(value: endTimestamp!),
                                      largeImageKey: largeImageKey,
                                      largeImageText: largeImageText,
                                      smallImageKey: smallImageKey,
                                      smallImageText: smallImageText)
    }

    func clearActivity() { bridge.clearActivity() }

    func shutdown() { bridge.shutdown() }
}

extension DiscordSDKClient: DiscordSDKBridgeDelegate {
    func discordSDKDidConnect(_ bridge: DiscordSDKBridge) {
        isConnected = true
        NSLog("[Discord] Bridge connected")
    }

    func discordSDKDidDisconnect(_ bridge: DiscordSDKBridge, error: Error?) {
        isConnected = false
        NSLog("[Discord] Bridge disconnected: \(error?.localizedDescription ?? "-")")
    }
}
