//
//  PreferencesIntegrationDiscordView.swift
//  ProcessReporter
//
//  Created by Codex on 2025/8/27.
//

import AppKit

class PreferencesIntegrationDiscordView: IntegrationView {
    private lazy var enabledCheckbox: NSButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private lazy var applicationIdTextField: NSScrollTextField = {
        let tf = NSScrollTextField()
        tf.placeholderString = "Discord Application ID"
        return tf
    }()

    private lazy var connectionStatusLabel: NSTextField = {
        let tf = NSTextField(labelWithString: "未连接")
        tf.textColor = .systemRed
        return tf
    }()

    private lazy var processInfoCheckbox: NSButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private lazy var mediaInfoCheckbox: NSButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private lazy var prioritizeMediaCheckbox: NSButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private lazy var showTimestampsCheckbox: NSButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    private lazy var customLargeImageKeyTextField: NSScrollTextField = {
        let tf = NSScrollTextField()
        tf.placeholderString = "Asset Key (Large Image)"
        return tf
    }()
    private lazy var customLargeImageTextTextField: NSScrollTextField = {
        let tf = NSScrollTextField()
        tf.placeholderString = "Large Image Hover Text"
        return tf
    }()

    private lazy var brandSmallImageKeyTextField: NSScrollTextField = {
        let tf = NSScrollTextField()
        tf.placeholderString = "Brand Small Image Asset Key"
        return tf
    }()

    private lazy var saveButton: NSButton = {
        let button = NSButton(title: "Save", target: self, action: #selector(save))
        button.bezelStyle = .push
        button.keyEquivalent = "\r"
        return button
    }()

    private lazy var resetButton: NSButton = {
        let button = NSButton(title: "Reset", target: self, action: #selector(reset))
        button.bezelStyle = .rounded
        return button
    }()

    init() {
        super.init(frame: .zero)
        setupUI()
        synchronizeUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func setupUI() {
        super.setupUI()

        // Basic settings
        createRow(leftView: NSTextField(labelWithString: "启用 Discord Rich Presence"), rightView: enabledCheckbox)

        createRow(leftView: NSTextField(labelWithString: "Application ID"), rightView: applicationIdTextField)
        createRowDescription(text: "从 Discord Developer Portal 获取的应用程序 ID (仅需 Application ID)")

        createRow(leftView: NSTextField(labelWithString: "连接状态"), rightView: connectionStatusLabel)

        // Content settings
        createRowDescription(text: "内容设置")
        createRow(leftView: NSTextField(labelWithString: "显示应用信息"), rightView: processInfoCheckbox)
        createRow(leftView: NSTextField(labelWithString: "显示媒体信息"), rightView: mediaInfoCheckbox)
        createRow(leftView: NSTextField(labelWithString: "媒体优先"), rightView: prioritizeMediaCheckbox)

        // Visual settings
        createRowDescription(text: "视觉设置 (资源需在 Discord Developer Portal 中预先上传)")
        createRow(leftView: NSTextField(labelWithString: "自定义大图标"), rightView: customLargeImageKeyTextField)
        createRow(leftView: NSTextField(labelWithString: "大图标文本"), rightView: customLargeImageTextTextField)
        createRow(leftView: NSTextField(labelWithString: "品牌小图标"), rightView: brandSmallImageKeyTextField)
        createRow(leftView: NSTextField(labelWithString: "显示时间戳"), rightView: showTimestampsCheckbox)

        // Actions
        let buttonStack = NSStackView()
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        buttonStack.addArrangedSubview(resetButton)
        buttonStack.addArrangedSubview(saveButton)
        gridView.addRow(with: [NSView(), buttonStack])
        gridView.cell(for: buttonStack)?.xPlacement = .trailing
    }

    public func synchronizeUI() {
        let cfg = PreferencesDataModel.shared.discordIntegration.value
        enabledCheckbox.state = cfg.isEnabled ? .on : .off
        applicationIdTextField.stringValue = cfg.applicationId
        processInfoCheckbox.state = cfg.showProcessInfo ? .on : .off
        mediaInfoCheckbox.state = cfg.showMediaInfo ? .on : .off
        prioritizeMediaCheckbox.state = cfg.prioritizeMedia ? .on : .off
        showTimestampsCheckbox.state = cfg.showTimestamps ? .on : .off
        customLargeImageKeyTextField.stringValue = cfg.customLargeImageKey
        customLargeImageTextTextField.stringValue = cfg.customLargeImageText
        brandSmallImageKeyTextField.stringValue = cfg.brandSmallImageKey

        updateConnectionStatus()
    }

    private func updateConnectionStatus() {
        let connected = DiscordClientProvider.shared.isConnected
        connectionStatusLabel.stringValue = connected ? "已连接" : "未连接"
        connectionStatusLabel.textColor = connected ? .systemGreen : .systemRed
    }

    @objc private func reset() { synchronizeUI() }

    @objc private func save() {
        var cfg = PreferencesDataModel.shared.discordIntegration.value
        cfg.isEnabled = enabledCheckbox.state == .on
        cfg.applicationId = applicationIdTextField.stringValue
        cfg.showProcessInfo = processInfoCheckbox.state == .on
        cfg.showMediaInfo = mediaInfoCheckbox.state == .on
        cfg.prioritizeMedia = prioritizeMediaCheckbox.state == .on
        cfg.showTimestamps = showTimestampsCheckbox.state == .on
        cfg.customLargeImageKey = customLargeImageKeyTextField.stringValue
        cfg.customLargeImageText = customLargeImageTextTextField.stringValue
        cfg.brandSmallImageKey = brandSmallImageKeyTextField.stringValue
        PreferencesDataModel.shared.discordIntegration.accept(cfg)
        ToastManager.shared.success("Saved!")
        updateConnectionStatus()
    }
}

