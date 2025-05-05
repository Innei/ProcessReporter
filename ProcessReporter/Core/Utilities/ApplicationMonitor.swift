//
//  ApplicationMonitor.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/7.
//

import Accessibility
import AppKit
import Foundation

class ApplicationMonitor {
    static let shared = ApplicationMonitor()

    private var mouseEventMonitor: Any?
    private var windowFocusObserver: Any?

    // Mouse event callback
    var onMouseClicked: ((MouseClickInfo) -> Void)?
    // Window focus change callback
    var onWindowFocusChanged: ((FocusedWindowInfo) -> Void)?

    private init() {
        checkAndRequestAccessibilityPermissions()
    }

    private func checkAndRequestAccessibilityPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let accessibilityEnabled = AXIsProcessTrustedWithOptions(options as CFDictionary)

        if !accessibilityEnabled {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Need Accessibility Permissions"
                alert.informativeText =
                    "ProcessReporter needs accessibility permissions to monitor window changes. Please grant permissions in System Preferences.\n\nPath: System Preferences > Security & Privacy > Accessibility"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Open System Preferences")
                alert.addButton(withTitle: "Later")

                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(
                        URL(
                            string:
                                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                        )!)
                }
            }
        }
    }

    func isAccessibilityEnabled() -> Bool {
        return AXIsProcessTrusted()
    }

    private func getWindowTitle(forPID pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)

        var mainWindow: CFTypeRef?
        let mainWindowError = AXUIElementCopyAttributeValue(
            appElement, kAXMainWindowAttribute as CFString, &mainWindow)
        let window = mainWindow
        guard mainWindowError == .success else {
            return nil
        }

        var title: CFTypeRef?
        let titleError = AXUIElementCopyAttributeValue(
            window as! AXUIElement, kAXTitleAttribute as CFString, &title)
        guard titleError == .success, let titleString = title as? String else {
            return nil
        }

        return titleString
    }

    func getFocusedWindowInfo() -> FocusedWindowInfo? {
        guard isAccessibilityEnabled() else {
            ToastManager.shared.error(
                "Accessibility permissions are required to monitor window changes.")
            return nil
        }

        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        let applicationIdentifier = app.bundleIdentifier ?? ""

        if IgnoreSystemApplication.contains(applicationIdentifier) {
            return nil
        }

        let appName = app.localizedName ?? "Unknown"
        let icon = app.icon
        let title = getWindowTitle(forPID: app.processIdentifier)

        return FocusedWindowInfo(
            appName: appName, icon: icon,
            applicationIdentifier: applicationIdentifier,
            title: title
        )
    }

    func startMouseMonitoring() {
        guard isAccessibilityEnabled() else {
            checkAndRequestAccessibilityPermissions()
            return
        }

        // Stop existing monitor if any
        stopMouseMonitoring()

        // Create new monitor for mouse down events
        mouseEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [
            .leftMouseDown, .rightMouseDown,
        ]) { [weak self] event in
            let clickInfo = MouseClickInfo(
                location: event.locationInWindow,
                timestamp: event.timestamp
            )
            self?.onMouseClicked?(clickInfo)
        }
    }

    func stopMouseMonitoring() {
        if let monitor = mouseEventMonitor {
            NSEvent.removeMonitor(monitor)
            mouseEventMonitor = nil
        }
    }

    func startWindowFocusMonitoring() {
        guard isAccessibilityEnabled() else {
            checkAndRequestAccessibilityPermissions()
            return
        }

        // Stop existing observer if any
        stopWindowFocusMonitoring()

        // Start observing active application changes
        windowFocusObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self,
                let windowInfo = self.getFocusedWindowInfo()
            else {
                return
            }
            self.onWindowFocusChanged?(windowInfo)
        }
    }

    func stopWindowFocusMonitoring() {
        if let observer = windowFocusObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            windowFocusObserver = nil
        }
    }

    deinit {
        stopMouseMonitoring()
        stopWindowFocusMonitoring()
    }
}
