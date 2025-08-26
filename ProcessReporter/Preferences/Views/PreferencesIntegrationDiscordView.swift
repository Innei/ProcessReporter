//
//  PreferencesIntegrationDiscordView.swift
//  ProcessReporter
//
//  Created by Codex on 2025/8/27.
//

import AppKit

class PreferencesIntegrationDiscordView: IntegrationView {
    private var connectionStatusTimer: Timer?
    private lazy var enabledCheckbox: NSButton = NSButton(
        checkboxWithTitle: "", target: nil, action: nil)
    private lazy var applicationIdTextField: NSScrollTextField = {
        let tf = NSScrollTextField()
        tf.placeholderString = "Discord Application ID"
        return tf
    }()

    private lazy var connectionStatusLabel: NSTextField = {
        let tf = NSTextField(labelWithString: "Not Connected")
        tf.textColor = .systemRed
        return tf
    }()

    private lazy var processInfoCheckbox: NSButton = NSButton(
        checkboxWithTitle: "", target: nil, action: nil)
    private lazy var mediaInfoCheckbox: NSButton = NSButton(
        checkboxWithTitle: "", target: nil, action: nil)
    private lazy var prioritizeMediaCheckbox: NSButton = NSButton(
        checkboxWithTitle: "", target: nil, action: nil)
    private lazy var showTimestampsCheckbox: NSButton = NSButton(
        checkboxWithTitle: "", target: nil, action: nil)

    private lazy var enableButtonsCheckbox: NSButton = NSButton(
        checkboxWithTitle: "", target: nil, action: nil)
    private lazy var buttonLabelTextField: NSScrollTextField = {
        let tf = NSScrollTextField()
        tf.placeholderString = "Button Label"
        return tf
    }()
    private lazy var buttonUrlTextField: NSScrollTextField = {
        let tf = NSScrollTextField()
        tf.placeholderString = "Button URL (https://...)"
        return tf
    }()

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
        startConnectionStatusTimer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        stopConnectionStatusTimer()
    }

    override func setupUI() {
        super.setupUI()

        // Basic settings
        createRow(
            leftView: NSTextField(labelWithString: "Enable"),
            rightView: enabledCheckbox)

        createRow(
            leftView: NSTextField(labelWithString: "Application ID"),
            rightView: applicationIdTextField)
        createRowDescription(
            text: "Application ID from Discord Developer Portal (only Application ID is needed)")

        createRow(
            leftView: NSTextField(labelWithString: "Connection Status"),
            rightView: connectionStatusLabel)

        // Content settings
        createRowDescription(text: "Content Settings")
        createRow(
            leftView: NSTextField(labelWithString: "Show Application Info"),
            rightView: processInfoCheckbox)
        createRow(
            leftView: NSTextField(labelWithString: "Show Media Info"), rightView: mediaInfoCheckbox)
        createRow(
            leftView: NSTextField(labelWithString: "Prioritize Media"),
            rightView: prioritizeMediaCheckbox)

        // Visual settings
        createRowDescription(
            text: "Visual Settings (assets must be pre-uploaded in Discord Developer Portal)")
        createRow(
            leftView: NSTextField(labelWithString: "Custom Large Image"),
            rightView: customLargeImageKeyTextField)
        createRow(
            leftView: NSTextField(labelWithString: "Large Image Text"),
            rightView: customLargeImageTextTextField)
        createRow(
            leftView: NSTextField(labelWithString: "Brand Small Image"),
            rightView: brandSmallImageKeyTextField)
        createRow(
            leftView: NSTextField(labelWithString: "Show Timestamps"),
            rightView: showTimestampsCheckbox)

        // Buttons
        createRowDescription(text: "Buttons (optional, up to 1; Discord supports 2)")
        createRow(
            leftView: NSTextField(labelWithString: "Enable Button"),
            rightView: enableButtonsCheckbox)
        createRow(
            leftView: NSTextField(labelWithString: "Button Label"),
            rightView: buttonLabelTextField)
        createRow(
            leftView: NSTextField(labelWithString: "Button URL"),
            rightView: buttonUrlTextField)

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
        enableButtonsCheckbox.state = cfg.enableButtons ? .on : .off
        buttonLabelTextField.stringValue = cfg.buttonLabel
        buttonUrlTextField.stringValue = cfg.buttonUrl

        updateConnectionStatus()
    }

    private func updateConnectionStatus() {
        let connected = DiscordClientProvider.shared.isConnected
        connectionStatusLabel.stringValue = connected ? "Connected" : "Not Connected"
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
        cfg.enableButtons = enableButtonsCheckbox.state == .on
        cfg.buttonLabel = buttonLabelTextField.stringValue
        cfg.buttonUrl = buttonUrlTextField.stringValue
        PreferencesDataModel.shared.discordIntegration.accept(cfg)
        ToastManager.shared.success("Saved!")
        updateConnectionStatus()
    }

    private func startConnectionStatusTimer() {
        connectionStatusTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) {
            [weak self] _ in
            DispatchQueue.main.async {
                self?.updateConnectionStatus()
            }
        }
    }

    private func stopConnectionStatusTimer() {
        connectionStatusTimer?.invalidate()
        connectionStatusTimer = nil
    }
}
