//
//  PreferencesIntegrationViewController.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/6.
//

import AppKit
import SnapKit

enum IntegrationType: String, CaseIterable {
    case mxSpace = "Mix Space"
    case slack = "Slack"
    case s3 = "S3"
    case discord = "Discord"

    @MainActor
    func nsImage() -> NSImage {
        let assetName: String
        let fallbackSymbol: String
        switch self {
        case .mxSpace:
            assetName = "mx-space"
            fallbackSymbol = "network"
        case .slack:
            assetName = "slack"
            fallbackSymbol = "number"
        case .s3:
            assetName = "s3"
            fallbackSymbol = "externaldrive.badge.icloud"
        case .discord:
            assetName = "discord"
            fallbackSymbol = "bubble.left.and.bubble.right"
        }
        return NSImage(named: assetName)
            ?? NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: rawValue)
            ?? NSImage()
    }

    @MainActor
    func view() -> NSView {
        switch self {
        case .mxSpace:
            return PreferencesIntegrationMixSpaceView()
        case .slack:
            return PreferencesIntegrationSlackView()
        case .s3:
            return PreferencesIntegrationS3View()
        case .discord:
            return PreferencesIntegrationDiscordView()
        }
    }
}

private extension Notification.Name {
    static let integrationSelectionChanged = Notification.Name("IntegrationSelectionChanged")
}

@MainActor
final class SidebarViewController: NSViewController {
    private lazy var tableView: NSTableView = {
        let table = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("IntegrationColumn"))
        column.title = "Integrations"
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        // 设置斑马条纹
        table.usesAlternatingRowBackgroundColors = true

        table.rowHeight = 40
        table.delegate = self
        table.dataSource = self
        return table
    }()

    private lazy var scrollView: NSScrollView = {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.documentView = tableView
        return scroll
    }()

    override func loadView() {
        view = NSView()
        view.addSubview(scrollView)

        scrollView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }
}

extension SidebarViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return IntegrationType.allCases.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        let identifier = NSUserInterfaceItemIdentifier("IntegrationCell")
        var cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView

        let integrationType = IntegrationType.allCases[row]

        if cell == nil {
            cell = NSTableCellView()
            cell?.identifier = identifier

            let imageView = NSImageView()
            imageView.imageScaling = .scaleProportionallyDown
            imageView.setAccessibilityRole(.image)
            cell?.addSubview(imageView)

            let textField = NSTextField()
            textField.isEditable = false
            textField.isSelectable = false
            textField.isBordered = false
            textField.drawsBackground = false
            textField.backgroundColor = .clear
            cell?.addSubview(textField)
            cell?.textField = textField

            imageView.snp.makeConstraints { make in
                make.centerY.equalToSuperview()
                make.left.equalToSuperview().offset(8)
                make.size.equalTo(32)
            }

            textField.snp.makeConstraints { make in
                make.centerY.equalToSuperview()
                make.left.equalTo(imageView.snp.right).offset(8)
                make.right.equalToSuperview().offset(-8)
            }
        }

        if let imageView = cell?.subviews.first as? NSImageView {
            imageView.image = integrationType.nsImage()
            imageView.setAccessibilityLabel(integrationType.rawValue)
        }
        cell?.textField?.stringValue = integrationType.rawValue

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView = notification.object as? NSTableView else { return }
        let selectedRow = tableView.selectedRow
        if selectedRow >= 0 {
            let selectedType = IntegrationType.allCases[selectedRow]
            // 通知主视图控制器更新右侧内容
            NotificationCenter.default.post(
                name: .integrationSelectionChanged,
                object: selectedType)
        }
    }
}

@MainActor
final class PreferencesIntegrationViewController: NSViewController, SettingWindowProtocol {
    var frameSize: NSSize = NSSize(width: 600, height: 400)

    private lazy var splitViewController: NSSplitViewController = {
        let svc = NSSplitViewController()
        return svc
    }()

    private lazy var sidebarViewController: SidebarViewController = {
        SidebarViewController()
    }()

    private lazy var rightSplitViewItem: NSSplitViewItem = {
        let item = NSSplitViewItem(viewController: NSViewController())
        item.canCollapse = false
        return item
    }()
    private var pendingContentSwitch: DispatchWorkItem?

    override func loadView() {
        view = NSView()

        addChild(splitViewController)
        view.addSubview(splitViewController.view)

        // 配置分栏布局
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarViewController)
        sidebarItem.canCollapse = false
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 200

        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(rightSplitViewItem)

        splitViewController.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        updateContentView(for: IntegrationType.allCases[0])
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleIntegrationSelection(_:)),
            name: .integrationSelectionChanged,
            object: nil
        )
    }

    @objc private func handleIntegrationSelection(_ notification: Notification) {
        guard let integrationType = notification.object as? IntegrationType else { return }
        // 根据选择的类型更新右侧视图
        updateContentView(for: integrationType)
    }

    private func updateContentView(for type: IntegrationType) {
        let cancelledPendingSwitch = pendingContentSwitch != nil
        pendingContentSwitch?.cancel()
        pendingContentSwitch = nil
        if cancelledPendingSwitch {
            rightSplitViewItem.viewController.view.layer?.removeAnimation(forKey: "fadeOut")
            rightSplitViewItem.viewController.view.alphaValue = 1
        }

        let newView = type.view()
        newView.wantsLayer = true
        newView.alphaValue = 0

        // 为当前视图创建淡出动画
        let fadeOutAnimation = CASpringAnimation(keyPath: "opacity")
        fadeOutAnimation.fromValue = 1.0
        fadeOutAnimation.toValue = 0.0
        fadeOutAnimation.duration = 0.2
        fadeOutAnimation.damping = 12  // 弹簧阻尼，值越大弹性越小
        fadeOutAnimation.initialVelocity = 5  // 初始速度
        fadeOutAnimation.isRemovedOnCompletion = true

        rightSplitViewItem.viewController.view.layer?.add(fadeOutAnimation, forKey: "fadeOut")

        // 延迟一小段时间后切换视图并执行淡入动画
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pendingContentSwitch = nil
            self.splitViewController.removeSplitViewItem(self.rightSplitViewItem)
            self.rightSplitViewItem.viewController.view.removeFromSuperview()

            self.rightSplitViewItem.viewController.view = newView
            self.splitViewController.addSplitViewItem(self.rightSplitViewItem)

            // 为新视图创建淡入动画
            let fadeInAnimation = CASpringAnimation(keyPath: "opacity")
            fadeInAnimation.fromValue = 0.0
            fadeInAnimation.toValue = 1.0
            fadeInAnimation.duration = 0.2
            fadeInAnimation.damping = 12
            fadeInAnimation.initialVelocity = 5
            fadeInAnimation.isRemovedOnCompletion = true

            newView.layer?.add(fadeInAnimation, forKey: "fadeIn")
            newView.alphaValue = 1  // 设置最终状态
        }
        pendingContentSwitch = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }
}
