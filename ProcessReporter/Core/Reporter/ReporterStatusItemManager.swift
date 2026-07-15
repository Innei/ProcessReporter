//
//  ReporterStatusItemManager.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/10.
//

import Cocoa
import Combine
import SwiftUI

@MainActor
final class ReporterStatusItemManager: NSObject {
    enum StatusItemIconStatus {
        case ready
        case syncing
        case offline
        case paused
        case partialError
        case error
    }

    private let statusItem: NSStatusItem
    private let model = PresenceMenuBarModel()
    private let popover = NSPopover()
    private let contextMenu = NSMenu()

    private var hostingController: NSHostingController<PresencePopoverView>!
    private var aggregateStatusObservation: AnyCancellable?
    private var renderedStatus: PresenceAggregateStatus?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        configureStatusItem()
        configurePopover()
        configureContextMenu()
        observeAggregateStatus()
        applyStatusItemAppearance(model.aggregateStatus)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func beginDelivery(to destinationIDs: [PresenceDestinationID]) -> UUID {
        model.beginDelivery(to: destinationIDs)
    }

    func completeDelivery(
        deliveryID: UUID,
        results: [PresenceDestinationDeliveryResult],
        assetResolution: PresenceAssetResolution,
        persistenceError: String? = nil
    ) {
        model.completeDelivery(
            deliveryID: deliveryID,
            results: results,
            assetResolution: assetResolution,
            persistenceError: persistenceError
        )
    }

    func publishCurrentPresence(_ report: ReportModel) {
        model.publishCurrentPresence(report)
    }

    func clearCurrentPresence() {
        model.clearCurrentPresence()
    }

    func toggleStatusItemIcon(_ status: StatusItemIconStatus) {
        switch status {
        case .ready:
            model.setRuntimeStatus(.ready)
        case .syncing:
            model.setRuntimeStatus(.syncing)
        case .offline:
            model.setRuntimeStatus(.waitingForNetwork)
        case .paused:
            model.setRuntimeStatus(.paused)
        case .partialError, .error:
            // Delivery completion is the source of truth for degraded and error
            // aggregation. Reporter retains these calls during the compatibility
            // phase, but they must not overwrite destination-aware state.
            break
        }
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemPressed(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.setAccessibilityRole(.button)
    }

    private func configurePopover() {
        let actions = PresencePopoverActions(
            openSettings: { [weak self] in
                self?.openSettings()
            },
            openPrivacyRules: { [weak self] applicationIdentifier in
                self?.openSettings(
                    route: .privacyRules(applicationIdentifier: applicationIdentifier)
                )
            },
            openDestinations: { [weak self] in
                self?.openSettings(route: .section(.destinations))
            },
            openDestination: { [weak self] destinationID in
                self?.openSettings(route: .destination(destinationID.settingsDestination))
            },
            openIconHosting: { [weak self] in
                self?.openSettings(route: .destination(.applicationIconHosting))
            },
            dismiss: { [weak self] in
                self?.popover.performClose(nil)
            },
            quit: { [weak self] in
                self?.popover.performClose(nil)
                NSApp.terminate(nil)
            }
        )
        let rootView = PresencePopoverView(model: model, actions: actions)
        hostingController = NSHostingController(rootView: rootView)
        hostingController.sizingOptions = [.preferredContentSize]

        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
        popover.contentSize = NSSize(width: 372, height: 420)
        popover.contentViewController = hostingController
    }

    private func configureContextMenu() {
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettingsFromMenu(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        contextMenu.addItem(settingsItem)

        let updateItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updateItem.target = self
        contextMenu.addItem(updateItem)

        contextMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit ProcessReporter",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        contextMenu.addItem(quitItem)
    }

    private func observeAggregateStatus() {
        aggregateStatusObservation = model.$aggregateStatus
            .removeDuplicates()
            .sink { [weak self] status in
                Task { @MainActor [weak self] in
                    self?.applyStatusItemAppearance(status)
                }
            }
    }

    private func applyStatusItemAppearance(_ status: PresenceAggregateStatus) {
        guard renderedStatus != status, let button = statusItem.button else { return }
        renderedStatus = status

        button.image = MenuBarIconRenderer.image(for: status)
        button.setAccessibilityLabel(
            "ProcessReporter, \(status.accessibilityDescription)"
        )
        button.setAccessibilityValue(status.displayText)
        button.setAccessibilityHelp("Open Presence status")
        button.toolTip = "ProcessReporter — \(status.displayText)"
    }

    @objc private func statusItemPressed(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            togglePopover(relativeTo: sender)
            return
        }

        if event.type == .rightMouseUp
            || (event.type == .leftMouseUp && event.modifierFlags.contains(.control))
        {
            popover.performClose(nil)
            NSMenu.popUpContextMenu(contextMenu, with: event, for: sender)
            return
        }

        togglePopover(relativeTo: sender)
    }

    private func togglePopover(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }

        model.refreshConfiguration()
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func openSettings(route: SettingsRoute? = nil) {
        popover.performClose(nil)
        DispatchQueue.main.async {
            SettingWindowManager.shared.showWindow(route: route)
        }
    }

    @objc private func showSettingsFromMenu(_ sender: Any?) {
        openSettings()
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.checkForUpdates(sender)
    }
}

extension ReporterStatusItemManager: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.highlight(false)
    }
}

private extension PresenceDestinationID {
    var settingsDestination: SettingsDestination {
        switch self {
        case .mixSpace:
            return .mixSpace
        case .slack:
            return .slack
        case .discord:
            return .discord
        }
    }
}
