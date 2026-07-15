import AppKit

@MainActor
struct PresenceMenuBuilder {
    struct Actions {
        let target: NSObject
        let toggleSharing: Selector
        let openPrivacyRule: Selector
        let openDestinations: Selector
        let openDestination: Selector
        let openIconHosting: Selector
        let openSettings: Selector
        let checkForUpdates: Selector
        let quit: Selector
    }

    static func rebuild(
        _ menu: NSMenu,
        model: PresenceMenuBarModel,
        actions: Actions
    ) {
        menu.removeAllItems()

        addSharingItems(to: menu, model: model, actions: actions)
        menu.addItem(.separator())
        addCurrentPresenceItems(to: menu, model: model, actions: actions)
        menu.addItem(.separator())
        addDestinationItems(to: menu, model: model, actions: actions)
        menu.addItem(.separator())
        addApplicationItems(to: menu, actions: actions)
    }

    private static func addSharingItems(
        to menu: NSMenu,
        model: PresenceMenuBarModel,
        actions: Actions
    ) {
        let sharingItem = actionItem(
            title: "Share Presence",
            action: actions.toggleSharing,
            target: actions.target
        )
        sharingItem.state = model.isSharing ? .on : .off
        sharingItem.isEnabled = model.canShare || model.isSharing
        sharingItem.toolTip = sharingItem.isEnabled
            ? (model.isSharing ? "Pause Presence sharing" : "Resume Presence sharing")
            : "Set up and enable a destination before sharing Presence."
        menu.addItem(sharingItem)

        let statusItem = informationItem(
            title: model.aggregateStatus.displayText,
            systemImage: model.aggregateStatus.menuSymbolName
        )
        menu.addItem(statusItem)

        if let blockingMessage = model.blockingMessage {
            if blockingMessage == "Waiting for network" {
                menu.addItem(
                    informationItem(
                        title: blockingMessage,
                        systemImage: "network.slash"
                    )
                )
            } else {
                let item = actionItem(
                    title: "Sharing Needs Attention…",
                    action: actions.openSettings,
                    target: actions.target,
                    systemImage: "exclamationmark.triangle"
                )
                item.toolTip = blockingMessage
                menu.addItem(item)
            }
        }

        if let failureMessage = model.assetResolution.failureMessage {
            let item = actionItem(
                title: "Review Application Icon Hosting…",
                action: actions.openIconHosting,
                target: actions.target,
                systemImage: "photo.badge.exclamationmark"
            )
            item.toolTip = failureMessage
            menu.addItem(item)
        }

        let hasDestinationFailure = model.configuredDestinations.contains {
            $0.deliveryState.isFailure
        }
        if model.aggregateStatus == .error,
           model.blockingMessage == nil,
           !hasDestinationFailure
        {
            menu.addItem(
                actionItem(
                    title: "Review Sharing Error…",
                    action: actions.openSettings,
                    target: actions.target,
                    systemImage: "xmark.octagon"
                )
            )
        }
    }

    private static func addCurrentPresenceItems(
        to menu: NSMenu,
        model: PresenceMenuBarModel,
        actions: Actions
    ) {
        menu.addItem(.sectionHeader(title: "Current Presence"))

        if let presence = model.currentPresence {
            if presence.hasApplication {
                let title = [presence.applicationName, presence.windowTitle]
                    .compactMap { $0?.nonEmpty }
                    .joined(separator: " — ")
                    .menuTitle
                menu.addItem(
                    informationItem(
                        title: title,
                        image: presence.applicationIcon,
                        fallbackSystemImage: "app.fill",
                        accessibilityDescription: "Current application"
                    )
                )
            }

            if presence.hasMedia {
                let playbackState = presence.mediaIsPlaying ? "Playing" : "Paused"
                let media = [presence.mediaTitle, presence.mediaArtist]
                    .compactMap { $0?.nonEmpty }
                    .joined(separator: " — ")
                menu.addItem(
                    informationItem(
                        title: "\(playbackState): \(media)".menuTitle,
                        image: presence.mediaArtwork,
                        fallbackSystemImage: presence.mediaIsPlaying
                            ? "play.circle.fill"
                            : "pause.circle.fill",
                        accessibilityDescription: "Current media"
                    )
                )
            }
        } else {
            menu.addItem(
                informationItem(
                    title: model.isSharing
                        ? "Nothing to share right now"
                        : "Sharing is paused",
                    systemImage: model.isSharing ? "moon.stars" : "pause.circle"
                )
            )
        }

        guard let applicationIdentifier = model.privacyTargetApplicationIdentifier else {
            return
        }

        let applicationName = AppUtility.shared.getAppInfo(
            for: applicationIdentifier
        ).displayName
        let hasRule = PresencePrivacyRulesRepository.effectiveConfiguration()
            .rule(for: applicationIdentifier) != nil
        let verb = hasRule ? "Edit" : "Add"
        let ruleItem = actionItem(
            title: "\(verb) Rule for \(applicationName)…".menuTitle,
            action: actions.openPrivacyRule,
            target: actions.target,
            systemImage: "hand.raised"
        )
        ruleItem.representedObject = applicationIdentifier
        menu.addItem(ruleItem)
    }

    private static func addDestinationItems(
        to menu: NSMenu,
        model: PresenceMenuBarModel,
        actions: Actions
    ) {
        menu.addItem(.sectionHeader(title: "Destinations"))

        guard !model.configuredDestinations.isEmpty else {
            menu.addItem(
                actionItem(
                    title: "Set Up a Destination…",
                    action: actions.openDestinations,
                    target: actions.target,
                    systemImage: "dot.radiowaves.left.and.right"
                )
            )
            return
        }

        for destination in model.configuredDestinations {
            let title: String
            if model.aggregateStatus == .syncing,
               destination.configurationState == .ready,
               destination.deliveryState == .sending
            {
                // The aggregate status already communicates active delivery.
                // Repeating “Syncing” on every row adds no destination-specific signal.
                title = destination.id.displayName
            } else {
                title = "\(destination.id.displayName) — \(destination.menuStatusText)"
            }

            let item = actionItem(
                title: title,
                action: actions.openDestination,
                target: actions.target,
                image: destination.providerImage,
                fallbackSystemImage: destination.id.fallbackSymbolName,
                accessibilityDescription: destination.id.displayName
            )
            item.representedObject = destination.id.rawValue
            item.toolTip = destination.deliveryState.failureMessage
                ?? "Open \(destination.id.displayName) settings"
            menu.addItem(item)
        }
    }

    private static func addApplicationItems(
        to menu: NSMenu,
        actions: Actions
    ) {
        menu.addItem(
            actionItem(
                title: "Settings…",
                action: actions.openSettings,
                target: actions.target,
                keyEquivalent: ","
            )
        )
        menu.addItem(
            actionItem(
                title: "Check for Updates…",
                action: actions.checkForUpdates,
                target: actions.target
            )
        )
        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit ProcessReporter",
            action: actions.quit,
            keyEquivalent: "q"
        )
        quitItem.target = actions.target
        menu.addItem(quitItem)
    }

    private static func informationItem(
        title: String,
        systemImage: String
    ) -> NSMenuItem {
        informationItem(
            title: title,
            image: nil,
            fallbackSystemImage: systemImage,
            accessibilityDescription: title
        )
    }

    private static func informationItem(
        title: String,
        image: NSImage?,
        fallbackSystemImage: String,
        accessibilityDescription: String
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = menuImage(
            image,
            fallbackSystemImage: fallbackSystemImage,
            accessibilityDescription: accessibilityDescription
        )
        item.isEnabled = false
        return item
    }

    private static func actionItem(
        title: String,
        action: Selector,
        target: NSObject,
        keyEquivalent: String = "",
        systemImage: String? = nil
    ) -> NSMenuItem {
        actionItem(
            title: title,
            action: action,
            target: target,
            keyEquivalent: keyEquivalent,
            image: nil,
            fallbackSystemImage: systemImage,
            accessibilityDescription: title
        )
    }

    private static func actionItem(
        title: String,
        action: Selector,
        target: NSObject,
        keyEquivalent: String = "",
        image: NSImage?,
        fallbackSystemImage: String?,
        accessibilityDescription: String
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = target
        item.image = menuImage(
            image,
            fallbackSystemImage: fallbackSystemImage,
            accessibilityDescription: accessibilityDescription
        )
        return item
    }

    private static func menuImage(
        _ image: NSImage?,
        fallbackSystemImage: String?,
        accessibilityDescription: String
    ) -> NSImage? {
        let resolvedImage = image?.copy() as? NSImage
            ?? fallbackSystemImage.flatMap {
                NSImage(
                    systemSymbolName: $0,
                    accessibilityDescription: accessibilityDescription
                )
            }
        resolvedImage?.size = NSSize(width: 18, height: 18)
        return resolvedImage
    }
}

private extension PresenceAggregateStatus {
    var menuSymbolName: String {
        switch self {
        case .setupRequired: return "circle.dashed"
        case .paused: return "pause.circle"
        case .idle: return "minus.circle"
        case .ready: return "checkmark.circle"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .degraded: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }
}

private extension PresenceDestinationPresentation {
    var menuStatusText: String {
        configurationState == .ready
            ? deliveryState.displayText
            : configurationState.displayText
    }

    var providerImage: NSImage? {
        NSImage(named: id.assetName)
    }
}

private extension PresenceDeliveryState {
    var failureMessage: String? {
        if case .failed(let message, _) = self {
            return message
        }
        return nil
    }
}

private extension PresenceDestinationID {
    var fallbackSymbolName: String {
        switch self {
        case .mixSpace: return "network"
        case .slack: return "number"
        case .discord: return "bubble.left.and.bubble.right"
        }
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }

    var menuTitle: String {
        let limit = 72
        guard count > limit else { return self }
        return String(prefix(limit - 1)) + "…"
    }
}
