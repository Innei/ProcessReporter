//
//  AppDelegate.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/6.
//

import Cocoa
import IOKit.pwr_mgt
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var wakeTask: Task<Void, Never>?
    private var terminationTask: Task<Void, Never>?
    private var updaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 初始设置为 accessory 模式（不显示 Dock 图标）
        NSApp.setActivationPolicy(.accessory)

        // Setup sleep/wake notifications for cache cleanup
        setupSleepWakeNotifications()
        configureUpdater()

        Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                if !PreferencesDataModel.shared.isEnabled.value {
                    self?.showSettings()
                }
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

    @objc func checkForUpdates(_ sender: Any?) {
        guard let updaterController else {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Updates Unavailable"
            alert.informativeText =
                "This build does not contain a Sparkle signing key. Install an official release to check for updates."
            alert.runModal()
            return
        }
        updaterController.checkForUpdates(sender)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard terminationTask == nil else { return .terminateLater }

        // AppKit does not wait for work started from applicationWillTerminate. Defer
        // termination so pending writes are flushed before the database is released.
        ApplicationState.isTerminating = true
        ApplicationState.bootstrapTask?.cancel()
        terminationTask = Task { @MainActor in
            await SettingsMutationCoordinator.shared.drain()
            ApplicationState.bootstrapTask = nil
            ApplicationState.reporter?.handleSleep()
            ApplicationState.reporter = nil
            await DataStore.shared.flush()
            await Database.shared.cleanup()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false  // Keep the app running even after the window is closed
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

    private func configureUpdater() {
        let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        guard let feedURL, URL(string: feedURL)?.scheme == "https",
              let publicKey, !publicKey.isEmpty,
              !publicKey.contains("$(")
        else {
            NSLog("Sparkle updater disabled because this build has no valid feed or public key")
            return
        }

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    @objc private func willSleep(_ notification: Notification) {
        print("System will sleep - cleaning up caches...")
        cleanupCachesBeforeSleep()
    }

    @objc private func didWake(_ notification: Notification) {
        print("System did wake - reinitializing components...")
        reinitializeAfterWake()
    }

    private func cleanupCachesBeforeSleep() {
        wakeTask?.cancel()
        wakeTask = nil

        // Clean up app info cache with icons (can be memory-heavy)
        AppUtility.shared.clearCache()

        // Stop all report preparation, delivery timers, and source callbacks so
        // a missed timer cannot persist a pre-sleep snapshot after wake.
        ApplicationState.reporter?.handleSleep()

        // Clean up reporter caches
        ApplicationState.reporter?.clearCaches()

        // Save any pending database changes via DataStore
        Task {
            await DataStore.shared.flush()
        }

        print("Cache cleanup completed before sleep")
    }

    private func reinitializeAfterWake() {
        // Reinitialize media monitoring after wake with proper callback restoration
        wakeTask?.cancel()
        wakeTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return
            }
            guard self != nil, !Task.isCancelled else { return }

            guard let reporter = ApplicationState.reporter else { return }
            reporter.handleWakeFromSleep()
        }

        print("Components reinitialized after wake")
    }

}
