//
//  PreferencesIntegrationDiscordView.swift
//  ProcessReporter
//
//  Created by Codex on 2025/8/27.
//

import AppKit
import SnapKit

private final class DiscordConnectionStatusTimer: @unchecked Sendable {
    var value: Timer?

    deinit {
        value?.invalidate()
    }
}

@MainActor
final class PreferencesIntegrationDiscordView: IntegrationView {
    private let connectionStatusTimer = DiscordConnectionStatusTimer()
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
    private lazy var useListeningForMediaCheckbox: NSButton = NSButton(
        checkboxWithTitle: "", target: nil, action: nil)
    private lazy var showTimestampsCheckbox: NSButton = NSButton(
        checkboxWithTitle: "", target: nil, action: nil)

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

    private lazy var debugTextView: NSTextView = {
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.usesFindBar = true
        tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.backgroundColor = .clear
        tv.textContainerInset = NSSize(width: 6, height: 6)
        return tv
    }()

    private lazy var debugScrollView: NSScrollView = {
        let sv = NSScrollView()
        sv.documentView = debugTextView
        sv.hasVerticalScroller = true
        sv.borderType = .bezelBorder
        return sv
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
        createRow(
            leftView: NSTextField(labelWithString: "Media Uses Listening"),
            rightView: useListeningForMediaCheckbox)

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

        // Debug
        createRowDescription(text: "Debug (updates every 2 seconds)")
        createRow(
            leftView: NSTextField(labelWithString: "Debug Info"),
            rightView: debugScrollView)
        debugScrollView.snp.makeConstraints { make in
            make.height.equalTo(160)
            make.width.greaterThanOrEqualTo(240)
        }

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
        useListeningForMediaCheckbox.state = cfg.useListeningForMedia ? .on : .off
        showTimestampsCheckbox.state = cfg.showTimestamps ? .on : .off
        customLargeImageKeyTextField.stringValue = cfg.customLargeImageKey
        customLargeImageTextTextField.stringValue = cfg.customLargeImageText
        brandSmallImageKeyTextField.stringValue = cfg.brandSmallImageKey
        updateConnectionStatus()
    }

    private func updateConnectionStatus() {
        let connected = DiscordClientProvider.shared.isConnected
        connectionStatusLabel.stringValue = connected ? "Connected" : "Not Connected"
        connectionStatusLabel.textColor = connected ? .systemGreen : .systemRed
        debugTextView.string = DiscordDebugStore.shared.formattedText()
    }

    @objc private func reset() { synchronizeUI() }

    @objc private func save() {
        var cfg = PreferencesDataModel.shared.discordIntegration.value
        cfg.isEnabled = enabledCheckbox.state == .on
        cfg.applicationId = applicationIdTextField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        cfg.showProcessInfo = processInfoCheckbox.state == .on
        cfg.showMediaInfo = mediaInfoCheckbox.state == .on
        cfg.prioritizeMedia = prioritizeMediaCheckbox.state == .on
        cfg.useListeningForMedia = useListeningForMediaCheckbox.state == .on
        cfg.showTimestamps = showTimestampsCheckbox.state == .on
        cfg.customLargeImageKey = customLargeImageKeyTextField.stringValue
        cfg.customLargeImageText = customLargeImageTextTextField.stringValue
        cfg.brandSmallImageKey = brandSmallImageKeyTextField.stringValue
        // The bundled Discord Game SDK has no activity-button fields. Preserve
        // historical label/URL values for forward compatibility, but never publish
        // an enabled option that this build cannot honor.
        cfg.enableButtons = false

        if cfg.isEnabled {
            guard !cfg.applicationId.isEmpty,
                  cfg.applicationId.allSatisfy(\.isNumber)
            else {
                ToastManager.shared.error("Discord Application ID must contain only digits")
                return
            }
        }

        PreferencesDataModel.shared.discordIntegration.accept(cfg)
        ToastManager.shared.success("Saved!")
		DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
			self?.updateConnectionStatus()
		}
        
    }

    private func startConnectionStatusTimer() {
        connectionStatusTimer.value = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateConnectionStatus()
            }
        }
    }

    private func stopConnectionStatusTimer() {
        connectionStatusTimer.value?.invalidate()
        connectionStatusTimer.value = nil
    }
}
