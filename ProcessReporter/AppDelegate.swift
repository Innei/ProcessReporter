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
    private enum TerminationDraftDecision {
        case proceed
        case save(SettingsDestination, allowDisablingLastReadyDestination: Bool)
        case cancel
    }

    private final class TerminationProgress {
        var settingsDrained = false
        var reporterStopped = false
        var databaseFinalized = false
    }

    private var wakeTask: Task<Void, Never>?
    private var terminationTask: Task<Void, Never>?
    private var updaterController: SPUStandardUpdaterController?

    var isUpdaterAvailable: Bool { updaterController != nil }

    var updaterAvailabilityDescription: String {
        isUpdaterAvailable
            ? "Official release updates are available through Sparkle."
            : "This build has no valid Sparkle feed or signing key."
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 初始设置为 accessory 模式（不显示 Dock 图标）
        NSApp.setActivationPolicy(.accessory)

        // Setup sleep/wake notifications for cache cleanup
        setupSleepWakeNotifications()
        configureUpdater()
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

        switch terminationDraftDecision() {
        case .cancel:
            return .terminateCancel
        case .proceed:
            beginTermination(sender)
        case .save(let destination, let allowDisablingLastReadyDestination):
            terminationTask = Task { @MainActor in
                guard let window = SettingWindowManager.shared.settingWindow else {
                    self.terminationTask = nil
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
                let result = await window.settingsStore.saveDestination(
                    destination,
                    allowDisablingLastReadyDestination: allowDisablingLastReadyDestination
                )
                guard result.succeeded else {
                    self.terminationTask = nil
                    window.makeKeyAndOrderFront(nil)
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
                await self.finishTermination(sender)
            }
        }
        return .terminateLater
    }

    private func beginTermination(_ sender: NSApplication) {
        terminationTask = Task { @MainActor in
            await self.finishTermination(sender)
        }
    }

    private func finishTermination(_ sender: NSApplication) async {
        // AppKit does not wait for work started from applicationWillTerminate.
        // Stop capture synchronously, then let settings/database finalization and
        // remote cleanup share one deadline without serially blocking each other.
        ApplicationState.isTerminating = true
        ApplicationState.bootstrapTask?.cancel()

        let progress = TerminationProgress()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        let databaseStartDeadline = clock.now.advanced(by: .seconds(4))
        let reporter = ApplicationState.reporter

        reporter?.handleSleep()
        Task { @MainActor in
            if let reporter {
                await reporter.shutdown(pendingCleanupTimeout: .seconds(5))
            }
            ApplicationState.reporter = nil
            progress.reporterStopped = true
        }
        Task { @MainActor in
            await SettingsMutationCoordinator.shared.drain()
            progress.settingsDrained = true
            if let reporter {
                let reportWorkStopped = await reporter.waitForPendingReportWork(
                    until: databaseStartDeadline
                )
                guard reportWorkStopped else {
                    NSLog("Database cleanup skipped because local report work did not stop in time")
                    return
                }
            }
            ApplicationState.bootstrapTask = nil
            await DataStore.shared.flush()
            await Database.shared.cleanup()
            progress.databaseFinalized = true
        }

        while clock.now < deadline,
              !(progress.settingsDrained && progress.reporterStopped
                && progress.databaseFinalized)
        {
            try? await Task.sleep(for: .milliseconds(50))
        }

        if !progress.settingsDrained || !progress.reporterStopped
            || !progress.databaseFinalized
        {
            NSLog("Termination cleanup reached its five-second deadline")
        }
        sender.reply(toApplicationShouldTerminate: true)
    }

    private func terminationDraftDecision() -> TerminationDraftDecision {
        guard let window = SettingWindowManager.shared.settingWindow else { return .proceed }

        if let busyDestination = window.settingsStore.destinationBusy {
            window.makeKeyAndOrderFront(nil)
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Destination Operation in Progress"
            alert.informativeText =
                "Wait for the \(busyDestination.title) operation to finish before quitting ProcessReporter."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return .cancel
        }

        guard let destination = window.settingsStore.anyDirtyDestination else {
            return .proceed
        }

        window.makeKeyAndOrderFront(nil)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save Destination Changes Before Quitting?"
        alert.informativeText =
            "\(destination.title) has an unsaved draft. Save or discard it before quitting ProcessReporter."
        alert.addButton(withTitle: "Save and Quit")
        alert.addButton(withTitle: "Discard and Quit")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let disablesLastDestination = window.settingsStore
                .saveWouldDisableLastReadyDestination(destination)
            if disablesLastDestination, !confirmStoppingPresenceForTermination() {
                return .cancel
            }
            return .save(
                destination,
                allowDisablingLastReadyDestination: disablesLastDestination
            )
        case .alertSecondButtonReturn:
            window.settingsStore.discardDestinationDraft(destination)
            return .proceed
        default:
            return .cancel
        }
    }

    private func confirmStoppingPresenceForTermination() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Stop Presence Sharing?"
        alert.informativeText =
            "This draft disables the last ready destination. Saving it will turn off global Presence sharing before ProcessReporter quits."
        alert.addButton(withTitle: "Save, Stop Sharing, and Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
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
