//
//  AppDelegate.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/6.
//

import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 初始设置为 accessory 模式（不显示 Dock 图标）
        NSApp.setActivationPolicy(.accessory)

        Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [unowned self] _ in
            if !PreferencesDataModel.shared.isEnabled.value {
                self.showSettings()
            }
        }
        #if DEBUG
        showSettings()
        #endif
    }

    func showSettings() {
        Task { @MainActor in
            SettingWindowManager.shared.showWindow()
        }
    }

    func applicationWillTerminate(_ aNotification: Notification) {}

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false // Keep the app running even after the window is closed
    }
}
