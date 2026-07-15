//
//  ReporterStatusItemManager.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/10.
//

import Cocoa
import Combine

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
    private let menu = NSMenu()
    private var menuActions: PresenceMenuBuilder.Actions!

    private var aggregateStatusObservation: AnyCancellable?
    private var renderedStatus: PresenceAggregateStatus?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        let actionTarget = MenuActionTarget(owner: self)
        menuActions = PresenceMenuBuilder.Actions(
            target: actionTarget,
            toggleSharing: #selector(MenuActionTarget.toggleSharing(_:)),
            openPrivacyRule: #selector(MenuActionTarget.openPrivacyRule(_:)),
            openDestinations: #selector(MenuActionTarget.openDestinations(_:)),
            openDestination: #selector(MenuActionTarget.openDestination(_:)),
            openIconHosting: #selector(MenuActionTarget.openIconHosting(_:)),
            openSettings: #selector(MenuActionTarget.openSettings(_:)),
            checkForUpdates: #selector(MenuActionTarget.checkForUpdates(_:)),
            quit: #selector(MenuActionTarget.quit(_:))
        )

        configureStatusItem()
        configureMenu()
        observeAggregateStatus()
        applyStatusItemAppearance(model.aggregateStatus)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func beginDelivery(to destinationIDs: [PresenceDestinationID]) -> UUID {
        let deliveryID = model.beginDelivery(to: destinationIDs)
        rebuildMenu()
        return deliveryID
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
        rebuildMenu()
    }

    func publishCurrentPresence(_ report: ReportModel) {
        model.publishCurrentPresence(report)
        rebuildMenu()
    }

    func clearCurrentPresence() {
        model.clearCurrentPresence()
        rebuildMenu()
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
        rebuildMenu()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.setAccessibilityRole(.button)
    }

    private func configureMenu() {
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
    }

    private func rebuildMenu() {
        PresenceMenuBuilder.rebuild(
            menu,
            model: model,
            actions: menuActions
        )
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
        button.setAccessibilityHelp("Open Presence menu")
        button.toolTip = "ProcessReporter — \(status.displayText)"
    }

    @objc private func toggleSharing(_ sender: NSMenuItem) {
        model.setSharing(!model.isSharing)
        rebuildMenu()
    }

    @objc private func openPrivacyRule(_ sender: NSMenuItem) {
        guard let applicationIdentifier = sender.representedObject as? String else {
            return
        }
        openSettings(
            route: .privacyRules(applicationIdentifier: applicationIdentifier)
        )
    }

    @objc private func openDestinations(_ sender: NSMenuItem) {
        openSettings(route: .section(.destinations))
    }

    @objc private func openDestination(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let destinationID = PresenceDestinationID(rawValue: rawValue)
        else {
            return
        }
        openSettings(route: .destination(destinationID.settingsDestination))
    }

    @objc private func openIconHosting(_ sender: NSMenuItem) {
        openSettings(route: .destination(.applicationIconHosting))
    }

    private func openSettings(route: SettingsRoute? = nil) {
        Task { @MainActor in
            await Task.yield()
            SettingWindowManager.shared.showWindow(route: route)
        }
    }

    @objc private func showSettingsFromMenu(_ sender: Any?) {
        openSettings()
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.checkForUpdates(sender)
    }

    @MainActor
    private final class MenuActionTarget: NSObject {
        unowned let owner: ReporterStatusItemManager

        init(owner: ReporterStatusItemManager) {
            self.owner = owner
        }

        @objc func toggleSharing(_ sender: NSMenuItem) {
            owner.toggleSharing(sender)
        }

        @objc func openPrivacyRule(_ sender: NSMenuItem) {
            owner.openPrivacyRule(sender)
        }

        @objc func openDestinations(_ sender: NSMenuItem) {
            owner.openDestinations(sender)
        }

        @objc func openDestination(_ sender: NSMenuItem) {
            owner.openDestination(sender)
        }

        @objc func openIconHosting(_ sender: NSMenuItem) {
            owner.openIconHosting(sender)
        }

        @objc func openSettings(_ sender: Any?) {
            owner.showSettingsFromMenu(sender)
        }

        @objc func checkForUpdates(_ sender: Any?) {
            owner.checkForUpdates(sender)
        }

        @objc func quit(_ sender: Any?) {
            NSApp.terminate(sender)
        }
    }
}

extension ReporterStatusItemManager: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        model.refreshConfiguration()
        rebuildMenu()
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
