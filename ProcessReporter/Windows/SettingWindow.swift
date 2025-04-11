//
//  SettingWindow.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/6.
//

import AppKit
import SnapKit

class SettingWindow: NSWindow {
    private let generalVC = PreferencesGeneralViewController()
    private let integrationVC = PreferencesIntegrationViewController()

    private let rootViewController = NSViewController()
    public static let shared = SettingWindow()

    private let defaultFrameSize: NSSize = .init(width: 800, height: 0)

    // UserDefaults keys for window position and size
    private let windowFrameKey = "SettingWindowFrame"

    convenience init() {
        self.init(
            contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        contentViewController = rootViewController

        rootViewController.view.frame.size = defaultFrameSize

        title = "Settings"

        // Try to restore saved position and size
        if let savedFrameData = UserDefaults.standard.data(forKey: windowFrameKey),
           let nsValue = try? NSKeyedUnarchiver.unarchivedObject(
               ofClass: NSValue.self, from: savedFrameData),
           let savedFrame = nsValue.rectValue as NSRect?
        {
            // Check if the saved frame is visible on any current screen
            var isOnScreen = false
            for screen in NSScreen.screens {
                if screen.frame.intersects(savedFrame) {
                    isOnScreen = true
                    break
                }
            }

            if isOnScreen {
                setFrame(savedFrame, display: true)
            } else {
                // Fallback to default center position
                setFrame(.init(origin: .zero, size: defaultFrameSize), display: true)
                centerWindowOnScreen()
            }
        } else {
            // No saved data, use default
            setFrame(.init(origin: .zero, size: defaultFrameSize), display: true)
            centerWindowOnScreen()
        }

        delegate = self

        loadView()
        switchToTab(.general)
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

    private func switchToTab(_ tab: TabIdentifier) {
        let vc: NSViewController

        switch tab {
        case .general: vc = generalVC
        case .integration: vc = integrationVC
        }

        // 为当前视图创建淡出动画
        for child in rootViewController.children {
            let fadeOutAnimation = CASpringAnimation(keyPath: "opacity")
            fadeOutAnimation.fromValue = 1.0
            fadeOutAnimation.toValue = 0.0
            fadeOutAnimation.duration = 0.2
            fadeOutAnimation.damping = 12
            fadeOutAnimation.initialVelocity = 5
            fadeOutAnimation.isRemovedOnCompletion = false
            fadeOutAnimation.fillMode = .forwards

            child.view.layer?.add(fadeOutAnimation, forKey: "fadeOut")
        }

        // 延迟一小段时间后切换视图
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }

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
            fadeInAnimation.isRemovedOnCompletion = false
            fadeInAnimation.fillMode = .forwards

            vc.view.layer?.add(fadeInAnimation, forKey: "fadeIn")
            vc.view.alphaValue = 1

            self.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(rawValue: tab.rawValue)

            let targetSize =
                ((vc as? SettingWindowProtocol) != nil)
                    ? (vc as! SettingWindowProtocol).frameSize : self.defaultFrameSize

            self.adjustFrameForNewContentSize(targetSize)
        }
    }

    enum TabIdentifier: String {
        case general
        case integration
    }

    @objc func closeWindow() {
        orderOut(nil)
    }

    private func saveWindowFrame() {
        let nsValue = NSValue(rect: frame)
        let frameData = try? NSKeyedArchiver.archivedData(
            withRootObject: nsValue, requiringSecureCoding: true)
        UserDefaults.standard.set(frameData, forKey: windowFrameKey)
    }

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

                // 检查是否会超出屏幕底部
                if frame.origin.y < screenFrame.origin.y {
                    // 如果会超出屏幕底部，先将窗口底部对齐到屏幕可见区域底部
                    let screenBottom = screenFrame.origin.y

                    // 计算需要向上移动的距离
                    let adjustmentNeeded = frame.origin.y - screenBottom // 这是负值，表示超出的距离

                    // 设置新的 Y 坐标（窗口底部对齐屏幕可见区域底部，然后向上调整超出的距离）
                    frame.origin.y = self.frame.origin.y + adjustmentNeeded
                }

                frame.size = newWindowSize

                animator().setFrame(frame, display: true)
            }, completionHandler: nil)
    }
}

extension NSToolbarItem.Identifier {
    static let general = NSToolbarItem.Identifier("general")
    static let integration = NSToolbarItem.Identifier("integration")
}

// MARK: - Toolbar Delegate

extension SettingWindow: NSToolbarDelegate {
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [.general, .integration]
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
        sender.orderOut(nil)
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }

    func windowDidResignKey(_ notification: Notification) {
        let sender = notification.object as! NSWindow
        if !sender.isVisible {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // Save window position and size when window is moved or resized
    func windowDidResize(_ notification: Notification) {
        saveWindowFrame()
    }

    func windowDidMove(_ notification: Notification) {
        saveWindowFrame()
    }
}
