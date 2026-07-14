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
	private lazy var generalVC = PreferencesGeneralViewController()

	private let rootViewController = NSViewController()

	private lazy var defaultFrameSize: NSSize = generalVC.frameSize

	// UserDefaults keys for window position and size
	private let windowFrameKey = "SettingWindowFrame"
	private var pendingTabSwitch: DispatchWorkItem?

	convenience init() {
		self.init(
			contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable],
			backing: .buffered, defer: false)
		contentViewController = rootViewController

		rootViewController.view.frame.size = generalVC.frameSize
		self.isReleasedWhenClosed = false
		title = "Settings"

		positionWindow()

		delegate = self

		loadView()
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
			setFrame(
				.init(
					origin: .init(
						x: visibleFrame.minX + 20,
						y: visibleFrame.midY - defaultFrameSize.height / 2),
					size: defaultFrameSize),
				display: true)
		} else {
			setFrame(.init(origin: .zero, size: defaultFrameSize), display: true)
		}
#else
		setFrame(.init(origin: .zero, size: defaultFrameSize), display: true)
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
		let cancelledPendingSwitch = pendingTabSwitch != nil
		pendingTabSwitch?.cancel()
		pendingTabSwitch = nil
		if cancelledPendingSwitch {
			for child in rootViewController.children {
				child.view.layer?.removeAnimation(forKey: "fadeOut")
				child.view.alphaValue = 1
			}
		}

		if currentViewController?.isKind(of: vcType.classForCoder()) == true {
			toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(rawValue: tab.rawValue)
			return
		}

		let vc = vcType.init()

		// 为当前视图创建淡出动画
		for child in rootViewController.children {
			let fadeOutAnimation = CASpringAnimation(keyPath: "opacity")
			fadeOutAnimation.fromValue = 1.0
			fadeOutAnimation.toValue = 0.0
			fadeOutAnimation.duration = 0.2
			fadeOutAnimation.damping = 12
			fadeOutAnimation.initialVelocity = 5
			fadeOutAnimation.isRemovedOnCompletion = true

			child.view.layer?.add(fadeOutAnimation, forKey: "fadeOut")
		}

		// 延迟一小段时间后切换视图
		let workItem = DispatchWorkItem { [weak self] in
			guard let self = self else { return }
			self.pendingTabSwitch = nil

			// Remove existing view controllers
			for child in self.rootViewController.children {
				child.view.removeFromSuperview()
				child.removeFromParent()
			}

			// 准备新视图
			vc.view.alphaValue = 0
			self.rootViewController.addChild(vc)
			self.rootViewController.view.addSubview(vc.view)
			vc.view.snp.makeConstraints { make in
				make.edges.equalToSuperview()
			}

			// 为新视图创建淡入动画
			let fadeInAnimation = CASpringAnimation(keyPath: "opacity")
			fadeInAnimation.fromValue = 0.0
			fadeInAnimation.toValue = 1.0
			fadeInAnimation.duration = 0.2
			fadeInAnimation.damping = 12
			fadeInAnimation.initialVelocity = 5
			fadeInAnimation.isRemovedOnCompletion = true

			vc.view.layer?.add(fadeInAnimation, forKey: "fadeIn")
			vc.view.alphaValue = 1

			self.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(rawValue: tab.rawValue)

			let targetSize = (vc as? SettingWindowProtocol)?.frameSize ?? self.defaultFrameSize

			self.adjustFrameForNewContentSize(targetSize)
		}
		pendingTabSwitch = workItem
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
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

	func adjustFrameForNewContentSize(_ contentSize: NSSize) {
		NSAnimationContext.runAnimationGroup(
			{ context in
				context.allowsImplicitAnimation = true
				context.duration = 0.25
				context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

				let newWindowSize = frameRect(
					forContentRect: CGRect(origin: .zero, size: contentSize)
				).size
				var frame = self.frame

				guard let screen = screen ?? NSScreen.main else { return }
				let screenFrame = screen.visibleFrame

				// 计算新的窗口位置
				let newHeight = newWindowSize.height

				// 默认向下调整（保持窗口顶部位置不变）
				frame.origin.y = frame.origin.y + (frame.height - newHeight)

				frame.size = newWindowSize
				frame.origin.y = max(
					screenFrame.minY,
					min(frame.origin.y, screenFrame.maxY - min(frame.height, screenFrame.height)))
				frame.origin.x = max(
					screenFrame.minX,
					min(frame.origin.x, screenFrame.maxX - min(frame.width, screenFrame.width)))

				animator().setFrame(frame, display: true)
			}, completionHandler: nil)
	}
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
