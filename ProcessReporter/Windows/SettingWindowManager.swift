//
//  SettingWindowManager.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/12.
//

import AppKit

@MainActor
final class SettingWindowManager: NSObject {
    static let shared = SettingWindowManager()

    private(set) var settingWindow: SettingWindow?

    func showWindow(route: SettingsRoute? = nil) {
        NSApp.setActivationPolicy(.regular)

        let window: SettingWindow
        if let existingWindow = settingWindow {
            window = existingWindow
            if let route {
                window.navigate(to: route)
            }
        } else {
            window = SettingWindow(initialRoute: route)
            settingWindow = window
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func closeWindow() {
        settingWindow?.performClose(nil)
    }

    func windowDidClose(_ window: SettingWindow) {
        guard settingWindow === window else { return }
        settingWindow = nil
        AppUtility.shared.clearCache()

        let hasAnotherVisibleTitledWindow = NSApp.windows.contains { candidate in
            candidate !== window
                && candidate.isVisible
                && candidate.styleMask.contains(.titled)
        }
        if !hasAnotherVisibleTitledWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
