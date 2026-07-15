//
//  SettingWindow.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/6.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class SettingWindow: NSWindow {
    private static let defaultContentSize = NSSize(width: 860, height: 620)
    private static let minimumContentSize = NSSize(width: 720, height: 500)
    private static let frameAutosaveName = "ProcessReporter.SettingsWindow"

    let settingsStore: SettingsStore
    private var allowNextClose = false
    private var isSavingBeforeClose = false
    private var isSavingBeforeNavigation = false
    private var onboardingSubscription: AnyCancellable?
    private var selectedSectionSubscription: AnyCancellable?

    init(initialRoute: SettingsRoute? = nil) {
        let store = SettingsStore(initialRoute: initialRoute)
        settingsStore = store

        super.init(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        contentMinSize = Self.minimumContentSize
        isReleasedWhenClosed = false
        tabbingMode = .disallowed
        delegate = self

        installContent(for: store.onboardingCompleted)
        observeContentState()
        restoreFrame()
    }

    func navigate(to route: SettingsRoute) {
        _ = requestNavigation(to: route)
    }

    @discardableResult
    private func requestNavigation(to route: SettingsRoute) -> Bool {
        guard !isSavingBeforeNavigation, !isSavingBeforeClose else { return false }
        guard settingsStore.destinationBusy == nil else { return false }
        guard let destination = settingsStore.anyDirtyDestination,
              routeLeavesDirtyDestination(route, destination: destination)
        else {
            settingsStore.navigate(to: route)
            return true
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save Destination Changes?"
        alert.informativeText =
            "\(destination.title) has an unsaved draft. Save or discard it before opening the requested Settings page."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let disablesLastDestination = settingsStore
                .saveWouldDisableLastReadyDestination(destination)
            if disablesLastDestination, !confirmStoppingPresenceSharing() {
                return false
            }
            isSavingBeforeNavigation = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result = await settingsStore.saveDestination(
                    destination,
                    allowDisablingLastReadyDestination: disablesLastDestination
                )
                isSavingBeforeNavigation = false
                guard result.succeeded else { return }
                settingsStore.navigate(to: route)
            }
            return false
        case .alertSecondButtonReturn:
            settingsStore.discardDestinationDraft(destination)
            settingsStore.navigate(to: route)
            return true
        default:
            return false
        }
    }

    private func installContent(for onboardingCompleted: Bool) {
        toolbar = nil

        if onboardingCompleted {
            let tabViewController = SettingsTabViewController(
                store: settingsStore,
                navigationHandler: { [weak self] route in
                    self?.requestNavigation(to: route) ?? false
                }
            )
            toolbarStyle = .preference
            contentViewController = tabViewController
            title = settingsStore.selectedSection.title
        } else {
            toolbarStyle = .automatic
            contentViewController = NSHostingController(
                rootView: OnboardingRootView(settingsStore: settingsStore)
            )
            title = "Settings"
        }
    }

    private func observeContentState() {
        onboardingSubscription = settingsStore.$onboardingCompleted
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] completed in
                self?.installContent(for: completed)
            }

        selectedSectionSubscription = settingsStore.$selectedSection
            .removeDuplicates()
            .sink { [weak self] section in
                guard let self, settingsStore.onboardingCompleted else { return }
                title = section.title
            }
    }

    private func routeLeavesDirtyDestination(
        _ route: SettingsRoute,
        destination: SettingsDestination
    ) -> Bool {
        if case .destination(let routedDestination) = route,
           routedDestination == destination,
           settingsStore.selectedSection == .destinations,
           settingsStore.destinationPath.last == destination
        {
            return false
        }
        return true
    }

    private func restoreFrame() {
        _ = setFrameAutosaveName(Self.frameAutosaveName)
        if !setFrameUsingName(Self.frameAutosaveName) {
            center()
        }
        constrainRestoredFrameToVisibleScreen()
    }

    private func constrainRestoredFrameToVisibleScreen() {
        guard !NSScreen.screens.isEmpty else { return }

        let targetScreen = NSScreen.screens.max { lhs, rhs in
            lhs.visibleFrame.intersection(frame).area
                < rhs.visibleFrame.intersection(frame).area
        } ?? NSScreen.main ?? NSScreen.screens[0]

        let constrainedFrame = constrainFrameRect(frame, to: targetScreen)
        if constrainedFrame != frame {
            setFrame(constrainedFrame, display: false)
        }
    }
}

private extension NSRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else { return 0 }
        return width * height
    }
}

extension SettingWindow: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowNextClose {
            allowNextClose = false
            return true
        }
        guard settingsStore.destinationBusy == nil else { return false }
        guard !isSavingBeforeClose,
              !isSavingBeforeNavigation,
              let destination = settingsStore.anyDirtyDestination
        else {
            return !isSavingBeforeClose && !isSavingBeforeNavigation
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save Destination Changes?"
        alert.informativeText =
            "\(destination.title) has an unsaved draft. Save or discard it before closing Settings."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let disablesLastDestination = settingsStore
                .saveWouldDisableLastReadyDestination(destination)
            if disablesLastDestination, !confirmStoppingPresenceSharing() {
                return false
            }
            isSavingBeforeClose = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result = await settingsStore.saveDestination(
                    destination,
                    allowDisablingLastReadyDestination: disablesLastDestination
                )
                isSavingBeforeClose = false
                guard result.succeeded else { return }
                allowNextClose = true
                performClose(nil)
            }
            return false
        case .alertSecondButtonReturn:
            settingsStore.discardDestinationDraft(destination)
            return true
        default:
            return false
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        settingsStore.refreshCapabilities()
    }

    func windowWillClose(_ notification: Notification) {
        SettingWindowManager.shared.windowDidClose(self)
    }

    private func confirmStoppingPresenceSharing() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Stop Presence Sharing?"
        alert.informativeText =
            "This is the last ready destination. Saving will turn off global Presence sharing."
        alert.addButton(withTitle: "Save and Stop Sharing")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
