//
//  SettingWindow.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/6.
//

import AppKit
import SnapKit

@MainActor
final class SettingWindow: NSWindow {
	private static let contentSize = NSSize(width: 900, height: 500)

	private let rootViewController = NSViewController()

	// UserDefaults keys for window position and size
	private let windowFrameKey = "SettingWindowFrame"

	convenience init() {
		self.init(
			contentRect: NSRect(origin: .zero, size: Self.contentSize),
			styleMask: [.titled, .closable, .miniaturizable],
			backing: .buffered, defer: false)
		rootViewController.view.frame = NSRect(origin: .zero, size: Self.contentSize)
		rootViewController.preferredContentSize = Self.contentSize
		contentViewController = rootViewController

		isReleasedWhenClosed = false
		title = "Settings"
		delegate = self

		loadView()
		positionWindow()
		switchToTab(.general)
	}

	private func positionWindow() {
//        // Try to restore saved position and size
//        if let savedFrameData = UserDefaults.standard.data(forKey: windowFrameKey),
//           let nsValue = try? NSKeyedUnarchiver.unarchivedObject(
//               ofClass: NSValue.self, from: savedFrameData),
//           let savedFrame = nsValue.rectValue as NSRect?
//        {
//            // Check if the saved frame is visible on any current screen
//            var isOnScreen = false
//            for screen in NSScreen.screens {
//                if screen.frame.intersects(savedFrame) {
//                    isOnScreen = true
//                    break
//                }
//            }
//
//            if isOnScreen {
//                setFrame(savedFrame, display: true)
//            } else {
//                // Fallback to default center position
//                setFrame(.init(origin: .zero, size: defaultFrameSize), display: true)
//                centerWindowOnScreen()
//            }
//        } else {
//            // No saved data, use default
//            setFrame(.init(origin: .zero, size: defaultFrameSize), display: true)
//            centerWindowOnScreen()
//        }
#if DEBUG
		if let visibleFrame = NSScreen.main?.visibleFrame {
			setFrameOrigin(.init(
				x: visibleFrame.minX + 20,
				y: visibleFrame.midY - frame.height / 2
			))
		}
#else
		centerWindowOnScreen()
#endif
	}

	private func centerWindowOnScreen() {
		if let screen = NSScreen.main {
			let screenFrame = screen.frame
			let windowFrame = frame
			let x = screenFrame.midX - windowFrame.width / 2
			let y = screenFrame.midY - windowFrame.height / 2
			setFrameOrigin(NSPoint(x: x, y: y))
		}
	}

	func loadView() {
		let toolbar = NSToolbar(identifier: "PreferencesToolbar")
		toolbar.delegate = self
		toolbar.allowsUserCustomization = false
		toolbar.autosavesConfiguration = false
		toolbar.displayMode = .iconAndLabel
		toolbar.selectedItemIdentifier = .general
		toolbarStyle = .preference
		self.toolbar = toolbar
	}

	@objc private func switchToGeneral() {
		switchToTab(.general)
	}

	@objc private func switchToIntegration() {
		switchToTab(.integration)
	}

	@objc private func switchToHistory() {
		switchToTab(.history)
	}

	@objc private func switchToFilter() {
		switchToTab(.filter)
	}

	@objc private func switchToMapping() {
		switchToTab(.mapping)
	}

	private func switchToTab(_ tab: TabIdentifier) {
		let vcType: NSViewController.Type
		let currentViewController = rootViewController.children.first

		switch tab {
		case .general: vcType = PreferencesGeneralViewController.self
		case .integration: vcType = PreferencesIntegrationViewController.self
		case .filter: vcType = PreferencesFilterViewController.self
		case .history:
			vcType = PreferencesHistoryViewController.self
		case .mapping:
			vcType = PreferencesMappingViewController.self
		}
		if currentViewController?.isKind(of: vcType.classForCoder()) == true {
			toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(rawValue: tab.rawValue)
			return
		}

		let vc = vcType.init()

		for child in rootViewController.children {
			child.view.removeFromSuperview()
			child.removeFromParent()
		}

		rootViewController.addChild(vc)
		rootViewController.view.addSubview(vc.view)
		vc.view.snp.makeConstraints { make in
			make.edges.equalToSuperview()
		}

		toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(rawValue: tab.rawValue)
	}

	enum TabIdentifier: String {
		case general
		case integration
		case history
		case filter
		case mapping
	}

	//    private func saveWindowFrame() {
	//        let nsValue = NSValue(rect: frame)
	//        let frameData = try? NSKeyedArchiver.archivedData(
	//            withRootObject: nsValue, requiringSecureCoding: true)
	//        UserDefaults.standard.set(frameData, forKey: windowFrameKey)
	//    }

}

extension NSToolbarItem.Identifier {
	static let general = NSToolbarItem.Identifier("general")
	static let integration = NSToolbarItem.Identifier("integration")
	static let history = NSToolbarItem.Identifier("history")
	static let filter = NSToolbarItem.Identifier("filter")
	static let mapping = NSToolbarItem.Identifier("mapping")
}

// MARK: - Toolbar Delegate

extension SettingWindow: NSToolbarDelegate {
	func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
		return [.general, .integration, .filter, .mapping, .history]
	}

	func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
		return toolbarAllowedItemIdentifiers(toolbar)
	}

	func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
		return toolbarAllowedItemIdentifiers(toolbar)
	}

	func toolbar(
		_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
		willBeInsertedIntoToolbar flag: Bool
	) -> NSToolbarItem? {
		let item = NSToolbarItem(itemIdentifier: itemIdentifier)
		switch itemIdentifier {
		case .general:
			item.label = "General"
			item.image = NSImage(systemSymbolName: "gear", accessibilityDescription: "General")
			item.action = #selector(switchToGeneral)
			item.isEnabled = true

		case .integration:
			item.label = "Integration"
			item.image = NSImage(
				systemSymbolName: "puzzlepiece.extension", accessibilityDescription: "Integration")
			item.action = #selector(switchToIntegration)
			item.isEnabled = true

		case .history:
			item.label = "History"
			item.image = NSImage(
				systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "History")
			item.action = #selector(switchToHistory)
			item.isEnabled = true

		case .filter:
			item.label = "Filter"
			item.image = NSImage(systemSymbolName: "line.horizontal.3.decrease.circle", accessibilityDescription: "Filter")
			item.action = #selector(switchToFilter)
			item.isEnabled = true

		case .mapping:
			item.label = "Mapping"
			item.image = NSImage(systemSymbolName: "arrow.trianglehead.swap", accessibilityDescription: "Mapping")
			item.action = #selector(switchToMapping)
			item.isEnabled = true

		default:
			return nil
		}
		item.target = self
		return item
	}
}

// MARK: - Window Delegate

extension SettingWindow: NSWindowDelegate {
	func windowShouldClose(_ sender: NSWindow) -> Bool {
		return true
	}

	func windowWillClose(_ notification: Notification) {
		SettingWindowManager.shared.windowDidClose(self)
		NSApp.setActivationPolicy(.accessory)
	}

	func windowDidBecomeKey(_ notification: Notification) {
		NSApp.setActivationPolicy(.regular)
		NSApplication.shared.activate()
	}

	func windowDidResignKey(_ notification: Notification) {
		if let sender = notification.object as? NSWindow, !sender.isVisible {
			NSApp.setActivationPolicy(.accessory)
		}
	}

	// Save window position and size when window is moved or resized
	//    func windowDidResize(_ notification: Notification) {
	//        saveWindowFrame()
	//    }
//
	//    func windowDidMove(_ notification: Notification) {
	//        saveWindowFrame()
	//    }
}
