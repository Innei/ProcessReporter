//
//  PreferencesS3IconsViewController.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/14.
//

import AppKit
import Foundation
import SnapKit

@MainActor
final class PreferencesS3IconsViewController: NSViewController, SettingWindowProtocol {
    final let frameSize: NSSize = .init(width: 1000, height: 500)

    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var fetchedResults: [IconValue] = []
    private var allResults: [IconValue] = []
    private var searchField: NSSearchField!
    private var observer: Any?
    private var fetchTask: Task<Void, Never>?
    private var fetchGeneration = 0
    private var sortKey: DataStore.IconSortKey = .name
    private var sortAscending = true

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: frameSize))
        setupTableView()
        setupToolbar()
        setupContextMenu()
        addCloseButton()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        startObservingChanges()
        fetchData()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        stopObservingChanges()
        cancelFetch()
    }

    private func setupToolbar() {
        let toolbar = NSView()
        view.addSubview(toolbar)

        // Search field
        searchField = NSSearchField()
        searchField.placeholderString = "Search by app name or identifier..."
        searchField.target = self
        searchField.action = #selector(searchTextChanged)
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        toolbar.addSubview(searchField)

        let refreshButton = NSButton(
            title: "Refresh", target: self, action: #selector(refreshData))
        refreshButton.bezelStyle = .rounded

        // Button stack
        let buttonStack = NSStackView(views: [refreshButton])
        buttonStack.spacing = 8
        buttonStack.distribution = .fill
        toolbar.addSubview(buttonStack)

        // Setup constraints with SnapKit
        toolbar.snp.makeConstraints { make in
            make.top.equalTo(view).offset(8)
            make.left.equalTo(view).offset(8)
            make.right.equalTo(view).offset(-8)
            make.height.equalTo(30)
        }

        searchField.snp.makeConstraints { make in
            make.left.equalTo(toolbar)
            make.centerY.equalTo(toolbar)
            make.width.equalTo(toolbar.snp.width).multipliedBy(0.25)
        }

        buttonStack.snp.makeConstraints { make in
            make.right.equalTo(toolbar)
            make.top.bottom.equalTo(toolbar)
            make.left.greaterThanOrEqualTo(searchField.snp.right).offset(16)
        }
    }

    private func setupTableView() {
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        view.addSubview(scrollView)

        // Create table view
        tableView = NSTableView()
        tableView.delegate = self
        tableView.dataSource = self
        tableView.style = .fullWidth
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnResizing = true
        tableView.allowsColumnReordering = true
        tableView.allowsMultipleSelection = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        // Set up double-click action
        tableView.target = self
        tableView.doubleAction = #selector(tableViewDoubleClicked(_:))

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Name"
        nameColumn.width = 200
        nameColumn.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true)

        let appIdColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("appIdentifier"))
        appIdColumn.title = "Application ID"
        appIdColumn.width = 250
        appIdColumn.sortDescriptorPrototype = NSSortDescriptor(
            key: "applicationIdentifier", ascending: true)

        let urlColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("url"))
        urlColumn.title = "URL"
        urlColumn.width = 350
        urlColumn.sortDescriptorPrototype = NSSortDescriptor(key: "url", ascending: true)

        // Configure cells for each column
        let columns = [nameColumn, appIdColumn, urlColumn]
        for column in columns {
            let cellIdentifier = column.identifier
            let cell = NSTableCellView()
            let textField = NSTextField()
            textField.isBezeled = false
            textField.drawsBackground = false
            textField.isEditable = false
            textField.isSelectable = true
            textField.lineBreakMode = .byTruncatingTail
            cell.textField = textField
            cell.identifier = cellIdentifier
            cell.addSubview(textField)

            textField.snp.makeConstraints { make in
                make.left.equalTo(cell).offset(4)
                make.right.equalTo(cell).offset(-4)
                make.centerY.equalTo(cell)
            }
        }

        tableView.addTableColumn(nameColumn)
        tableView.addTableColumn(appIdColumn)
        tableView.addTableColumn(urlColumn)

        // Set table view as document view
        scrollView.documentView = tableView

        scrollView.snp.makeConstraints { make in
            make.top.equalTo(view).offset(46)
            make.left.right.equalTo(view)
            make.bottom.equalTo(view).inset(46)
        }
    }

    private func setupContextMenu() {
        let menu = NSMenu()
        menu.addItem(
            NSMenuItem(
                title: "Copy Cell Value", action: #selector(copyCellValue), keyEquivalent: "c",
                target: self))
        menu.addItem(
            NSMenuItem(
                title: "Copy Row as JSON", action: #selector(copyRowAsJSON), keyEquivalent: "j",
                target: self))
        menu.addItem(
            NSMenuItem(
                title: "Open URL in Browser", action: #selector(openURLInBrowser),
                keyEquivalent: "o", target: self))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            {
                let item = NSMenuItem(
                    title: "Delete Icon", action: #selector(deleteIcon), keyEquivalent: "\u{08}",
                    target: self)
                item.attributedTitle = NSAttributedString(
                    string: "Delete Icon",
                    attributes: [.foregroundColor: NSColor.red])

                return item
            }())

        tableView.menu = menu
    }

    private func startObservingChanges() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: DataStore.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.fetchData()
            }
        }
    }

    private func stopObservingChanges() {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

    private func cancelFetch() {
        fetchGeneration += 1
        fetchTask?.cancel()
        fetchTask = nil
    }

    private func fetchData() {
        fetchGeneration += 1
        let generation = fetchGeneration
        let requestedSortKey = sortKey
        let requestedSortAscending = sortAscending
        fetchTask?.cancel()

        fetchTask = Task { @MainActor [weak self] in
            let results = await DataStore.shared.fetchIconsSorted(
                by: requestedSortKey, ascending: requestedSortAscending)
            guard let self,
                  !Task.isCancelled,
                  generation == self.fetchGeneration
            else { return }

            self.allResults = results
            self.filterResultsWithSearchText(self.searchField?.stringValue ?? "")
            self.fetchTask = nil
        }
    }

    private func filterResultsWithSearchText(_ searchText: String) {
        if searchText.isEmpty {
            fetchedResults = allResults
        } else {
            let lowercasedSearchText = searchText.lowercased()

            fetchedResults = allResults.filter { model in
                // Search by name
                if model.name.lowercased().contains(lowercasedSearchText) {
                    return true
                }

                // Search by application identifier
                if model.applicationIdentifier.lowercased().contains(lowercasedSearchText) {
                    return true
                }

                // Search by URL
                if model.url.lowercased().contains(lowercasedSearchText) {
                    return true
                }

                return false
            }
        }

        tableView.reloadData()
    }

    @objc private func searchTextChanged(_ sender: NSSearchField) {
        filterResultsWithSearchText(sender.stringValue)
    }

    @objc private func refreshData() {
        fetchData()
    }

    @objc private func copyCellValue() {
        guard tableView.clickedRow >= 0 && tableView.clickedColumn >= 0,
            tableView.clickedRow < fetchedResults.count
        else {
            return
        }

        let model = fetchedResults[tableView.clickedRow]

        let columnID = tableView.tableColumns[tableView.clickedColumn].identifier.rawValue
        let valueToCopy: String

        switch columnID {
        case "name":
            valueToCopy = model.name

        case "appIdentifier":
            valueToCopy = model.applicationIdentifier

        case "url":
            valueToCopy = model.url

        default:
            valueToCopy = ""
        }

        // Copy to clipboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(valueToCopy, forType: .string)
    }

    @objc private func copyRowAsJSON() {
        guard tableView.clickedRow >= 0, tableView.clickedRow < fetchedResults.count else {
            return
        }

        let model = fetchedResults[tableView.clickedRow]

        // Create dictionary with all model data
        let jsonDict: [String: Any] = [
            "name": model.name,
            "applicationIdentifier": model.applicationIdentifier,
            "url": model.url,
        ]

        // Convert to JSON string
        if let jsonData = try? JSONSerialization.data(
            withJSONObject: jsonDict, options: [.prettyPrinted]),
            let jsonString = String(data: jsonData, encoding: .utf8)
        {
            // Copy to clipboard
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(jsonString, forType: .string)
        }
    }

    @objc private func openURLInBrowser() {
        guard tableView.clickedRow >= 0, tableView.clickedRow < fetchedResults.count else {
            return
        }

        let model = fetchedResults[tableView.clickedRow]

        guard let url = validatedWebURL(from: model.url) else {
            ToastManager.shared.error("The stored icon URL is invalid")
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func deleteIcon() {
        guard tableView.clickedRow >= 0, tableView.clickedRow < fetchedResults.count else {
            return
        }

        let model = fetchedResults[tableView.clickedRow]

        let alert = NSAlert()
        alert.messageText = "Delete Icon"
        alert.informativeText =
            "Are you sure you want to delete this icon record for '\(model.name)'?"
        alert.alertStyle = .warning

        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            Task { @MainActor in
                do {
                    try await DataStore.shared.deleteIcon(
                        applicationIdentifier: model.applicationIdentifier)
                    fetchData()
                } catch {
                    ToastManager.shared.error(
                        "Failed to delete icon: \(error.localizedDescription)")
                }
            }
        }
    }

    private func addCloseButton() {
        // Create close button
        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeModal))
        closeButton.bezelStyle = .rounded
        closeButton.bezelColor = .systemBlue
        closeButton.keyEquivalent = "\u{1B}"  // Escape key

        view.addSubview(closeButton)

        closeButton.snp.makeConstraints { make in
            make.trailing.equalTo(view).offset(-16)
            make.top.equalTo(scrollView.snp.bottom).offset(8)
        }
    }

    @objc private func closeModal() {
        // Dismiss the modal sheet
        if let presentingViewController = presentingViewController {
            presentingViewController.dismiss(self)
        }
    }

    @objc private func tableViewDoubleClicked(_ sender: Any) {
        guard tableView.clickedRow >= 0, tableView.clickedRow < fetchedResults.count else {
            return
        }

        let model = fetchedResults[tableView.clickedRow]
        guard let url = validatedWebURL(from: model.url) else {
            ToastManager.shared.error("The stored icon URL is invalid")
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func validatedWebURL(from value: String) -> URL? {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil
        else { return nil }
        return components.url
    }
}

// MARK: - NSTableViewDataSource

extension PreferencesS3IconsViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return fetchedResults.count
    }

    func tableView(
        _ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
    ) {
        guard let sortDescriptor = tableView.sortDescriptors.first else { return }

        switch sortDescriptor.key ?? "name" {
        case "name": sortKey = .name
        case "applicationIdentifier": sortKey = .applicationIdentifier
        case "url": sortKey = .url
        default: sortKey = .name
        }
        sortAscending = sortDescriptor.ascending
        fetchData()
    }
}

// MARK: - NSTableViewDelegate

extension PreferencesS3IconsViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        guard let tableColumn = tableColumn else { return nil }
        guard fetchedResults.indices.contains(row) else { return nil }
        let model = fetchedResults[row]

        let identifier = tableColumn.identifier
        let cell = NSTableCellView()
        let textField = NSTextField()
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.isEditable = false
        textField.isSelectable = true
        textField.lineBreakMode = .byTruncatingTail
        cell.textField = textField
        cell.identifier = identifier
        cell.addSubview(textField)

        textField.snp.makeConstraints { make in
            make.left.equalTo(cell).offset(4)
            make.right.equalTo(cell).offset(-4)
            make.centerY.equalTo(cell)
        }

        switch tableColumn.identifier.rawValue {

        case "name":
            textField.stringValue = model.name

        case "appIdentifier":
            textField.stringValue = model.applicationIdentifier

        case "url":
            textField.stringValue = model.url

        default:
            textField.stringValue = ""
        }

        return cell
    }
}
