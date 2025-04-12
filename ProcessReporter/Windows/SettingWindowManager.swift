//
//  SettingWindowManager.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/12
//

import AppKit
import Cocoa

@MainActor
class SettingWindowManager: NSObject {
    static let shared = SettingWindowManager()
    var settingWindow: TestWindow?

    func showWindow() {
        // Check if we have a reference AND the window it points to hasn't been closed by the user
        if let window = settingWindow, window.isVisible {
            // Window exists and is presumed open, bring it to front.
            window.makeKeyAndOrderFront(nil)
        } else {
            // Either no window exists, or the one we had was closed. Create a new one.
            print("Creating new TestWindow instance.") // Debugging log
            let window = TestWindow()

            self.settingWindow = window // Store the strong reference to the NEW window

            // Center the window (optional, but good practice)
            window.center()

            window.makeKeyAndOrderFront(nil)
        }
        // Ensure the application becomes active to focus the window
        NSApp.activate(ignoringOtherApps: true)
    }

    // Optional: Add a method to explicitly close/release the window if needed
    func closeWindow() {
        self.settingWindow?.close()
//        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
//            self?.settingWindow = SettingWindow()
//        }
        // If you want to release the window instance when closed:
//        settingWindow = nil
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
