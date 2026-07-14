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

    private lazy var rightContentViewController: NSViewController = {
        let controller = NSViewController()
        controller.view = NSView()
        return controller
    }()

    private lazy var rightSplitViewItem: NSSplitViewItem = {
        let item = NSSplitViewItem(viewController: rightContentViewController)
        item.canCollapse = false
        return item
    }()
    private weak var currentContentView: NSView?

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
        let newView = type.view()
        let containerView = rightContentViewController.view

        currentContentView?.removeFromSuperview()
        containerView.addSubview(newView)
        newView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        currentContentView = newView
    }
}
