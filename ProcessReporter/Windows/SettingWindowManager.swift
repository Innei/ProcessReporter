//
//  SettingWindowManager.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/12
//

import Cocoa

@MainActor
class SettingWindowManager: NSObject {
    static let shared = SettingWindowManager()
    var settingWindow: SettingWindow?

    func showWindow() {
        // Check if we have a reference AND the window it points to hasn't been closed by the user
        if let window = settingWindow, window.isVisible {
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
        self.settingWindow?.close()
        AppUtility.shared.clearCache()
        self.settingWindow = nil
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
