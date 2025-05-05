//
//  ReporterStatusItemManager.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/10.
//

import Cocoa
import RxCocoa
import RxSwift
import SnapKit
import SwiftUI

@MainActor
class ReporterStatusItemManager: NSObject {
	private var statusItem: NSStatusItem!

	// MARK: - Items

	private var enabledItem: NSMenuItem!

	private var currentProcessItem: NSMenuItem!
	private var currentMediaNameItem: NSMenuItem!

	private var lastSendProcessNameItem: NSMenuItem!
	private var lastSendProcessTimeItem: NSMenuItem!
	private var lastSendMediaNameItem: NSMenuItem!

	private var lastReportTime: Date?
	private var updateTimer: Timer?

	// Action
	private var enableMediaReportButton: NSMenuItem!
	private var enableProcessReportButton: NSMenuItem!

	#if DEBUG
		private var debugItem: NSMenuItem!
	#endif

	override init() {
		super.init()
		statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

		setupStatusItem()
		synchronizeUI()
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	private func synchronizeUI() {
		let preferences = PreferencesDataModel.shared
		enabledItem.state = preferences.isEnabled.value ? .on : .off
		enableMediaReportButton.state =
			preferences.enabledTypes.value.types.contains(.media) ? .on : .off
		enableProcessReportButton.state =
			preferences.enabledTypes.value.types.contains(.process) ? .on : .off
	}

	private func setupStatusItem() {
		toggleStatusItemIcon(.ready)

		let menu = NSMenu()
		currentProcessItem = NSMenuItem(
			title: "No Process", action: #selector(noop), keyEquivalent: "", target: self)
		menu.addItem(NSMenuItem.sectionHeader(title: "Current Process"))
		menu.addItem(currentProcessItem)

		menu.addItem(NSMenuItem.separator())
		menu.addItem(NSMenuItem.sectionHeader(title: "Current Media"))
		currentMediaNameItem = NSMenuItem(
			title: "No Media", action: #selector(noop), keyEquivalent: "", target: self)
		menu.addItem(currentMediaNameItem)

		menu.addItem(NSMenuItem.separator())

		menu.addItem(
			NSMenuItem.sectionHeader(title: "Last Send"))

		lastSendProcessNameItem = NSMenuItem(
			title: "..Last Process", action: #selector(noop), keyEquivalent: "", target: self)
		menu.addItem(lastSendProcessNameItem)
		lastSendMediaNameItem = NSMenuItem(
			title: "..Last Media", action: #selector(noop), keyEquivalent: "", target: self)
		menu.addItem(lastSendMediaNameItem)
		lastSendProcessTimeItem = NSMenuItem(
			title: "..Last Time", action: #selector(noop), keyEquivalent: "", target: self)
		menu.addItem(lastSendProcessTimeItem)

		menu.addItem(NSMenuItem.separator())

		enabledItem = NSMenuItem(
			title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "s", target: self)
		menu.addItem(enabledItem)
		menu.addItem(
			NSMenuItem(
				title: "Settings", action: #selector(showSettings), keyEquivalent: ",", target: self))

		menu.addItem(NSMenuItem.separator())

		menu.addItem(NSMenuItem.sectionHeader(title: "Enabled Reporters"))
		enableMediaReportButton = NSMenuItem(
			title: "Media", action: #selector(toggleEnableMedia), keyEquivalent: "", target: self)
		enableProcessReportButton = NSMenuItem(
			title: "Process", action: #selector(toggleEnableProcess), keyEquivalent: "",
			target: self)
		menu.addItem(enableMediaReportButton)
		menu.addItem(enableProcessReportButton)

		menu.addItem(NSMenuItem.separator())

		#if DEBUG
			debugItem = NSMenuItem(
				title: "Debug UI", action: nil, keyEquivalent: "", target: self)

			debugItem.view = DebugUICell()

			menu.addItem(debugItem)
			debugItem.view!.snp.makeConstraints { make in
				make.width.equalToSuperview()
				make.height.equalTo(22)
			}

		#endif
		menu.addItem(
			NSMenuItem(title: "Quit", action: #selector(NSApp.terminate), keyEquivalent: "q"))

		menu.delegate = self
		statusItem.menu = menu

		setupUpdateTimer()
	}

	private func setupUpdateTimer() {
		updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
			Task { @MainActor in
				self?.updateLastSendTimeDisplay()
			}
		}
		RunLoop.main.add(updateTimer!, forMode: .common)
	}

	private func updateLastSendTimeDisplay() {
		guard let lastTime = lastReportTime else { return }
		lastSendProcessTimeItem.title = lastTime.relativeTimeDescription()
	}

	enum StatusItemIconStatus {
		case ready
		case syncing
		case offline
		case paused
		case partialError
		case error
	}

	func toggleStatusItemIcon(_ status: StatusItemIconStatus) {
		guard let button = statusItem?.button else { return }
		switch status {
		case .ready:
			button.image = NSImage(
				systemSymbolName: "icloud.fill", accessibilityDescription: "Ready")
		case .offline:
			button.image = NSImage(
				systemSymbolName: "icloud.slash.fill", accessibilityDescription: "Network Error")
		case .paused:
			button.image = NSImage(
				systemSymbolName: "icloud.slash.fill", accessibilityDescription: "Paused")
		case .syncing:
			button.image = NSImage(
				systemSymbolName: "arrow.trianglehead.2.clockwise.rotate.90.icloud.fill",
				accessibilityDescription: "Syncing")
		case .partialError:
			button.image = NSImage(
				systemSymbolName: "exclamationmark.icloud",
				accessibilityDescription: "Partial Error")
		case .error:
			button.image = NSImage(
				systemSymbolName: "exclamationmark.icloud.fill", accessibilityDescription: "Error")
		}
	}

	func updateCurrentProcessItem(_ info: FocusedWindowInfo) {
		currentProcessItem.title = info.appName
		currentProcessItem.image = {
			let icon = info.icon
			icon?.size = NSSize(width: 16, height: 16)
			return icon
		}()
	}

	func updateCurrentMediaItem(
		_ mediaInfo: MediaInfo? = nil
	) {
		if let mediaInfo = mediaInfo, let name = mediaInfo.name {
			currentMediaNameItem.title = formatMediaName(name, mediaInfo.artist)
			if let base64 = mediaInfo.image, let data = Data(base64Encoded: base64) {
				let firstLine = name + "\n"
				let secondLine = mediaInfo.artist ?? "-"
				let fullString = firstLine + secondLine

				let attributedString = NSMutableAttributedString(string: fullString)

				// First line: Bold font
				let firstLineRange = NSRange(location: 0, length: firstLine.count)
				attributedString.addAttribute(.font, value: NSFont.systemFont(ofSize: 16, weight: .medium), range: firstLineRange)

				// Second line: Secondary color
				let secondLineRange = NSRange(location: firstLine.count, length: secondLine.count)
				attributedString.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: secondLineRange)

				currentMediaNameItem.attributedTitle = attributedString
				currentMediaNameItem.image = NSImage(data: data, size: .init(width: 40, height: 40))?.withRoundedCorners(radius: 8)
			}

		} else {
			currentMediaNameItem.title = "..No Media"
		}
	}

	func updateLastSendProcessNameItem(_ info: ReportModel) {
		lastSendProcessNameItem.title = info.processName ?? "N/A"
		lastReportTime = info.timeStamp
		updateLastSendTimeDisplay()

		lastSendMediaNameItem.title = formatMediaName(info.mediaName, info.artist)
	}

	func formatMediaName(_ mediaName: String?, _ artist: String?) -> String {
		if let mediaName = mediaName, let artist = artist {
			return "\(mediaName) - \(artist)"
		}
		return mediaName == nil ? "No Media" : mediaName!
	}
}

// MARK: - Menu Delegate

extension ReporterStatusItemManager: NSMenuDelegate {
	func menuWillOpen(_ menu: NSMenu) {
		synchronizeUI()
		#if DEBUG
			if debugItem.view == nil {
				debugItem.view = DebugUICell()
			}
		#endif
		guard let info = ApplicationMonitor.shared.getFocusedWindowInfo() else { return }
		updateCurrentProcessItem(info)

		guard let mediaInfo = MediaInfoManager.getMediaInfo() else { return }
		if mediaInfo.playing {
			updateCurrentMediaItem(mediaInfo)
		}
	}
}

// MARK: - Menu Actions

extension ReporterStatusItemManager {
	@objc private func noop() {}

	@objc private func toggleEnabled() {
		let isEnabled = PreferencesDataModel.shared.isEnabled.value
		PreferencesDataModel.shared.isEnabled.accept(!isEnabled)
	}

	@objc private func showSettings() {
		SettingWindowManager.shared.showWindow()
	}

	@objc private func toggleEnableMedia(sender: NSMenuItem) {
		let currentState = sender.state

		var snapshot = PreferencesDataModel.shared.enabledTypes.value.types
		if currentState == .on {
			snapshot.remove(.media)
		} else {
			snapshot.insert(.media)
		}
		PreferencesDataModel.shared.enabledTypes.accept(.init(types: snapshot))
	}

	@objc private func toggleEnableProcess(sender: NSMenuItem) {
		let currentState = sender.state

		var snapshot = PreferencesDataModel.shared.enabledTypes.value.types
		if currentState == .on {
			snapshot.remove(.process)
		} else {
			snapshot.insert(.process)
		}
		PreferencesDataModel.shared.enabledTypes.accept(.init(types: snapshot))
	}
}

#if DEBUG
	class DebugUICell: NSStackView {
		var backgroundView: NSVisualEffectView!
		var trackingArea: NSTrackingArea?

		var debugLabel: NSTextField!
		var debugIcon: NSImageView!

		convenience init() {
			self.init(frame: .zero)

			let stackView = self
			stackView.orientation = .horizontal
			stackView.spacing = 8

			// 使用系统菜单项选中样式
			backgroundView = NSVisualEffectView()
			// 菜单项高亮使用 .selection 材质
			backgroundView.material = .selection
			backgroundView.state = .active
			backgroundView.wantsLayer = true
			backgroundView.layer?.cornerRadius = 4
			backgroundView.alphaValue = 0

			// 一个小技巧：设置为强调模式以获取更蓝的外观
			backgroundView.isEmphasized = true

			// 移除任何可能影响颜色的背景
			backgroundView.layer?.backgroundColor = nil

			stackView.addSubview(backgroundView)
			backgroundView.snp.makeConstraints { make in
				make.horizontalEdges.equalToSuperview().inset(5)
				make.verticalEdges.equalToSuperview()
			}

			debugIcon = NSImageView(
				image: NSImage(systemSymbolName: "snowflake", accessibilityDescription: "Debug UI")!
			)
			debugIcon.frame.size = NSSize(width: 16, height: 16)
			stackView.addArrangedSubview(debugIcon)
			debugIcon.snp.makeConstraints { make in
				make.left.equalTo(24)
			}

			debugLabel = NSTextField(labelWithString: "Debug UI")
			debugLabel.isEditable = false
			debugLabel.isBezeled = false
			debugLabel.drawsBackground = false
			stackView.addArrangedSubview(debugLabel)

			stackView.gestureRecognizers = [
				NSClickGestureRecognizer(target: self, action: #selector(debugUI)),
			]

			// 确保视图被布局后更新 tracking areas
			DispatchQueue.main.async {
				self.updateTrackingAreas()
			}
		}

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			// 当视图添加到窗口时更新 tracking areas
			updateTrackingAreas()
		}

		override func viewDidMoveToSuperview() {
			super.viewDidMoveToSuperview()
			// 当视图添加到父视图时更新 tracking areas
			updateTrackingAreas()
		}

		override func updateTrackingAreas() {
			super.updateTrackingAreas()

			// 移除旧的 tracking area
			if let trackingArea = trackingArea {
				removeTrackingArea(trackingArea)
			}

			// 创建并添加新的 tracking area
			let newTrackingArea = NSTrackingArea(
				rect: bounds,
				options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
				owner: self,
				userInfo: nil)
			addTrackingArea(newTrackingArea)
			trackingArea = newTrackingArea
		}

		@objc private func debugUI() {
			let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
				sleep(50)
			}
			RunLoop.main.add(timer, forMode: .common)
		}

		override func mouseEntered(with event: NSEvent) {
			backgroundView.alphaValue = 1
			// 修改文本和图标为白色以匹配选中状态
			debugLabel.textColor = .white
			debugIcon.contentTintColor = .white
		}

		override func mouseExited(with event: NSEvent) {
			backgroundView.alphaValue = 0
			// 恢复文本和图标为默认颜色
			debugLabel.textColor = .labelColor
			debugIcon.contentTintColor = nil
		}
	}
#endif
