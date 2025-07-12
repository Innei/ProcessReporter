//
//  AppDelegate.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/6.
//

import Cocoa
import IOKit.pwr_mgt

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 初始设置为 accessory 模式（不显示 Dock 图标）
        NSApp.setActivationPolicy(.accessory)
        
        // Setup sleep/wake notifications for cache cleanup
        setupSleepWakeNotifications()

        Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            if !PreferencesDataModel.shared.isEnabled.value {
                self?.showSettings()
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
    
    // MARK: - Sleep/Wake Notifications for Cache Cleanup
    
    private func setupSleepWakeNotifications() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(willSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }
    
    @objc private func willSleep() {
        print("System will sleep - cleaning up caches...")
        cleanupCachesBeforeSleep()
    }
    
    @objc private func didWake() {
        print("System did wake - reinitializing components...")
        reinitializeAfterWake()
    }
    
    private func cleanupCachesBeforeSleep() {
        // Clean up app info cache with icons (can be memory-heavy)
        AppUtility.shared.clearCache()
        
        // Clean up reporter caches
        Task { @MainActor in
            if let reporter = reporter {
                reporter.clearCaches()
            }
        }
        
        // Stop media monitoring to free resources
        MediaInfoManager.stopMonitoringPlaybackChanges()
        
        // Save any pending database changes
        Task { @MainActor in
            if let context = await Database.shared.mainContext {
                try? context.save()
            }
        }
        
        print("Cache cleanup completed before sleep")
    }
    
    private func reinitializeAfterWake() {
        // Restart media monitoring after wake
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000) // Wait 2 seconds for system to stabilize
            
            // We need to provide a callback if restarting media monitoring
            // Since we're just waking up, we can use an empty callback for now
            MediaInfoManager.startMonitoringPlaybackChanges { _ in
                // Media info changed after wake - handled by existing reporters
            }
        }
        
        print("Components reinitialized after wake")
    }
    
    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
