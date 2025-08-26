//
//  PreferencesHistoryViewController.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/12.
//

import AppKit
import Foundation
import SnapKit

class PreferencesHistoryViewController: NSViewController, SettingWindowProtocol {
	final let frameSize: NSSize = .init(width: 1200, height: 600)

	private var tableView: NSTableView!
	private var scrollView: NSScrollView!
	private var sortDescriptor: NSSortDescriptor?
	private var fetchedResults: [ReportValue] = []
	private var allResults: [ReportValue] = []
	private var searchField: NSSearchField!
	private var observer: Any?

	// 分页参数
	private let pageSize = 50
	private var currentPage = 0
	private var hasMoreData = true
	private var isLoadingData = false

	override func loadView() {
		view = NSView(frame: NSRect(origin: .zero, size: frameSize))
		setupTableView()
		setupToolbar()
		setupContextMenu()
		fetchData()
	}

	override func viewDidAppear() {
		startObservingChanges()
	}

	override func viewWillDisappear() {
		stopObservingChanges()
	}

	deinit {
		stopObservingChanges()
	}

	private func setupToolbar() {
		let toolbar = NSView()
		view.addSubview(toolbar)

		// 创建搜索框
		searchField = NSSearchField()
		searchField.placeholderString = "Search by process or media name..."
		searchField.target = self
		searchField.action = #selector(searchTextChanged)
		searchField.sendsSearchStringImmediately = true
		searchField.sendsWholeSearchString = false
		toolbar.addSubview(searchField)

		// 创建按钮
		let clearButton = NSButton(
			title: "Clear History", target: self, action: #selector(clearHistory))
		clearButton.bezelStyle = .rounded

		let openDatabaseLocationButton = NSButton(
			title: "Open Database Location", target: self, action: #selector(openDatabaseLocation))
		openDatabaseLocationButton.bezelStyle = .rounded

		// 创建按钮栈
		let buttonStack = NSStackView(views: [openDatabaseLocationButton, clearButton])
		buttonStack.spacing = 8
		buttonStack.distribution = .fill
		toolbar.addSubview(buttonStack)

		toolbar.snp.makeConstraints { make in
			make.top.equalToSuperview().offset(8)
			make.left.equalToSuperview().offset(8)
			make.right.equalToSuperview().offset(-8)
			make.height.equalTo(30)
		}

		searchField.snp.makeConstraints { make in
			make.left.equalToSuperview()
			make.centerY.equalToSuperview()
			make.width.equalTo(toolbar.snp.width).multipliedBy(0.25)
		}

		buttonStack.snp.makeConstraints { make in
			make.right.equalToSuperview()
			make.top.bottom.equalToSuperview()
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

		// 创建 table view
		tableView = NSTableView()
		tableView.delegate = self
		tableView.dataSource = self
		tableView.style = .fullWidth
		tableView.usesAlternatingRowBackgroundColors = true
		tableView.allowsColumnResizing = true
		tableView.allowsColumnReordering = true
		tableView.allowsMultipleSelection = false
		tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

		// 添加列
		let timeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("time"))
		timeColumn.title = "Time"
		timeColumn.width = 150
		timeColumn.sortDescriptorPrototype = NSSortDescriptor(key: "timeStamp", ascending: false)

		let processColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("process"))
		processColumn.title = "Process"
		processColumn.width = 150
		processColumn.sortDescriptorPrototype = NSSortDescriptor(
			key: "processName", ascending: true)

		let mediaColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("media"))
		mediaColumn.title = "Media"
		mediaColumn.width = 200
		mediaColumn.sortDescriptorPrototype = NSSortDescriptor(key: "mediaName", ascending: true)

		let mediaProcessColumn = NSTableColumn(
			identifier: NSUserInterfaceItemIdentifier("mediaProcess"))
		mediaProcessColumn.title = "Media Process"
		mediaProcessColumn.width = 150
		mediaProcessColumn.sortDescriptorPrototype = NSSortDescriptor(
			key: "mediaProcessName", ascending: true)

		let integrationsColumn = NSTableColumn(
			identifier: NSUserInterfaceItemIdentifier("integrations"))
		integrationsColumn.title = "Integrations"
		integrationsColumn.width = 100

		// 为每列配置单元格
		let columns = [timeColumn, processColumn, mediaColumn, integrationsColumn]
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
				make.left.equalToSuperview().offset(4)
				make.right.equalToSuperview().offset(-4)
				make.centerY.equalToSuperview()
			}
		}

		tableView.addTableColumn(timeColumn)
		tableView.addTableColumn(processColumn)
		tableView.addTableColumn(mediaColumn)
		tableView.addTableColumn(mediaProcessColumn)
		tableView.addTableColumn(integrationsColumn)

		// 将表格视图设置为滚动视图的文档视图
		scrollView.documentView = tableView

		scrollView.snp.makeConstraints { make in
			make.top.equalToSuperview().offset(46)
			make.left.equalToSuperview()
			make.right.equalToSuperview()
			make.bottom.equalToSuperview()
		}

		// 添加滚动监听
		scrollView.contentView.postsBoundsChangedNotifications = true
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(scrollViewDidScroll),
			name: NSView.boundsDidChangeNotification,
			object: scrollView.contentView)
	}

	private func setupContextMenu() {
		let menu = NSMenu()
		menu.addItem(
			NSMenuItem(
				title: "Copy Cell Value", action: #selector(copyCellValue), keyEquivalent: "c"))
		menu.addItem(
			NSMenuItem(
				title: "Copy Row as JSON", action: #selector(copyRowAsJSON), keyEquivalent: "j"))
		tableView.menu = menu
	}

	private func startObservingChanges() {
		// 监听 DataStore 更改
		observer = NotificationCenter.default.addObserver(
			forName: DataStore.changedNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			self?.fetchData()
		}
	}

	private func stopObservingChanges() {
		if let observer = observer {
			NotificationCenter.default.removeObserver(observer)
		}
	}

	private func fetchData(isLoadingMore: Bool = false) {
		Task { @MainActor in
			if !isLoadingMore {
				// 重置分页参数
				currentPage = 0
				hasMoreData = true
				fetchedResults = []
			}

			let ascending = sortDescriptor?.ascending ?? false
			let offset = currentPage * pageSize
			let search = (searchField?.stringValue).flatMap { $0.isEmpty ? nil : $0 }
			let newResults = await DataStore.shared.fetchReports(
				searchText: search,
				offset: offset,
				limit: pageSize,
				ascending: ascending
			)

			// 检查是否还有更多数据
			hasMoreData = newResults.count == pageSize

			if isLoadingMore {
				// 追加新数据
				fetchedResults.append(contentsOf: newResults)
			} else {
				fetchedResults = newResults
			}

			tableView.reloadData()
			isLoadingData = false
		}
	}

	private func filterResultsWithSearchText(_ searchText: String) {
		if searchText.isEmpty {
			// 清空搜索时，重新从数据库获取数据（带分页）
			fetchData()
		} else {
			// 搜索模式下直接让 DataStore 过滤并返回结果（不分页）
			Task { @MainActor in
				let results = await DataStore.shared.fetchReports(
					searchText: searchText,
					offset: 0,
					limit: Int.max / 4,
					ascending: sortDescriptor?.ascending ?? false
				)
				fetchedResults = results
				hasMoreData = false
				tableView.reloadData()
			}
		}
	}

	@objc private func searchTextChanged(_ sender: NSSearchField) {
		filterResultsWithSearchText(sender.stringValue)
	}

	@objc private func openDatabaseLocation() {
		let fileManager = FileManager.default
		let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
			.first!
		let bundleID = Bundle.main.bundleIdentifier!
		let directoryURL = appSupportURL.appendingPathComponent(bundleID)

		// 在 Finder 中显示
		NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directoryURL.path)
	}

	@objc private func clearHistory() {
		Task { @MainActor in
			let alert = NSAlert()
			alert.messageText = "Clear History"
			alert.informativeText =
				"Are you sure you want to clear all history records? This action cannot be undone."
			alert.alertStyle = .warning

			alert.addButton(withTitle: "Clear")
			alert.addButton(withTitle: "Cancel")

			if alert.runModal() == .alertFirstButtonReturn {
				do {
					try await DataStore.shared.deleteAllReports()
					fetchData()
				} catch {
					print("Failed to clear history: \(error)")
				}
			}
		}
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
		case "time":
			let formatter = DateFormatter()
			formatter.dateStyle = .medium
			formatter.timeStyle = .medium
			valueToCopy = formatter.string(from: model.timeStamp)

		case "process":
			valueToCopy = model.processName ?? ""

		case "media":
			if let mediaName = model.mediaName {
				if let artist = model.artist {
					valueToCopy = "\(artist) - \(mediaName)"
				} else {
					valueToCopy = mediaName
				}
			} else {
				valueToCopy = "-"
			}

		case "integrations":
			valueToCopy = model.integrations
				.sorted()
				.joined(separator: ", ")

		case "mediaProcess":
			if let mediaProcessName = model.mediaProcessName {
				valueToCopy = mediaProcessName
			} else {
				valueToCopy = "-"
			}

		default:
			valueToCopy = ""
		}

		// 复制到剪贴板
		let pasteboard = NSPasteboard.general
		pasteboard.clearContents()
		pasteboard.setString(valueToCopy, forType: .string)
	}

	@objc private func copyRowAsJSON() {
		guard tableView.clickedRow >= 0, tableView.clickedRow < fetchedResults.count else {
			return
		}

		let model = fetchedResults[tableView.clickedRow]

		// 创建包含所有模型数据的字典
		var jsonDict: [String: Any] = [
			"id": model.id,
			"processName": model.processName ?? NSNull(),
			"timeStamp": model.timeStamp.description,
			"integrations": model.integrations,
		]

		if let mediaName = model.mediaName {
			jsonDict["mediaName"] = mediaName
		}

		if let artist = model.artist {
			jsonDict["artist"] = artist
		}

		if let mediaProcessName = model.mediaProcessName {
			jsonDict["mediaProcessName"] = mediaProcessName
		}

		if let mediaDuration = model.mediaDuration {
			jsonDict["mediaDuration"] = mediaDuration
		}

		if let mediaElapsedTime = model.mediaElapsedTime {
			jsonDict["mediaElapsedTime"] = mediaElapsedTime
		}

		// 转换为 JSON 字符串
		if let jsonData = try? JSONSerialization.data(
			withJSONObject: jsonDict, options: [.prettyPrinted]),
			let jsonString = String(data: jsonData, encoding: .utf8)
		{
			// 复制到剪贴板
			let pasteboard = NSPasteboard.general
			pasteboard.clearContents()
			pasteboard.setString(jsonString, forType: .string)
		}
	}

	@objc private func scrollViewDidScroll(_ notification: Notification) {
		guard let scrollView = notification.object as? NSClipView,
			scrollView == self.scrollView.contentView,
			!isLoadingData, hasMoreData
		else {
			return
		}

		let visibleRect = scrollView.documentVisibleRect
		let contentRect = scrollView.documentRect

		// 当滚动到底部附近时加载更多数据
		if visibleRect.maxY >= contentRect.height - 200 {
			loadMoreData()
		}
	}

	private func loadMoreData() {
		guard hasMoreData, !isLoadingData else { return }
		isLoadingData = true

		currentPage += 1
		fetchData(isLoadingMore: true)
	}
}

// MARK: - NSTableViewDataSource

extension PreferencesHistoryViewController: NSTableViewDataSource {
	func numberOfRows(in tableView: NSTableView) -> Int {
		return fetchedResults.count
	}

	func tableView(
		_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
	) {
		guard let sortDescriptor = tableView.sortDescriptors.first else { return }

		Task { @MainActor in
			let ascending = sortDescriptor.ascending

			// 重置分页并按新的排序条件获取数据
			currentPage = 0
			hasMoreData = true

			let offset = currentPage * pageSize
			let search = (searchField?.stringValue).flatMap { $0.isEmpty ? nil : $0 }
			fetchedResults = await DataStore.shared.fetchReports(
				searchText: search,
				offset: offset,
				limit: pageSize,
				ascending: ascending
			)
			tableView.reloadData()
		}
	}
}

// MARK: - NSTableViewDelegate

extension PreferencesHistoryViewController: NSTableViewDelegate {
	func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
		-> NSView?
	{
		guard let tableColumn = tableColumn else { return nil }
		guard row >= 0 && row < fetchedResults.count else { return nil }
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

		// 使用 SnapKit 设置文本字段的约束
		textField.snp.makeConstraints { make in
			make.left.equalToSuperview().offset(4)
			make.right.equalToSuperview().offset(-4)
			make.centerY.equalToSuperview()
		}

		switch tableColumn.identifier.rawValue {
		case "time":
			let formatter = DateFormatter()
			formatter.dateStyle = .medium
			formatter.timeStyle = .medium
			textField.stringValue = formatter.string(from: model.timeStamp)

		case "process":
			textField.stringValue = model.processName ?? "N/A"

		case "media":
			if let mediaName = model.mediaName {
				if let artist = model.artist {
					textField.stringValue = "\(artist) - \(mediaName)"
				} else {
					textField.stringValue = mediaName
				}
			} else {
				textField.stringValue = "-"
			}

		case "integrations":
			textField.stringValue = model.integrations
				.sorted()
				.joined(separator: ", ")

		case "mediaProcess":
			if let mediaProcessName = model.mediaProcessName {
				textField.stringValue = mediaProcessName
			} else {
				textField.stringValue = "-"
			}

		default:
			textField.stringValue = ""
		}

		return cell
	}
}
