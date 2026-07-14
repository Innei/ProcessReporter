//
//  SettingWindowManager.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/12
//

import Cocoa

@MainActor
final class SettingWindowManager: NSObject {
    static let shared = SettingWindowManager()
    var settingWindow: SettingWindow?

    func showWindow() {
        // Check if we have a reference AND the window it points to hasn't been closed by the user
        if let window = settingWindow {
            // Window exists and is presumed open, bring it to front.
            window.makeKeyAndOrderFront(nil)
        } else {
            // Either no window exists, or the one we had was closed. Create a new one.

            let window = SettingWindow()

            self.settingWindow = window  // Store the strong reference to the NEW window

            window.makeKeyAndOrderFront(nil)
        }
        // Ensure the application becomes active to focus the window
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeWindow() {
        let window = settingWindow
        settingWindow = nil
        window?.close()
        AppUtility.shared.clearCache()
    }

    func windowDidClose(_ window: SettingWindow) {
        if settingWindow === window {
            settingWindow = nil
            AppUtility.shared.clearCache()
        }
    }
}

class TestWindow: NSWindow {
    convenience init() {
        self.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        self.title = "Test Window"
    }
}
