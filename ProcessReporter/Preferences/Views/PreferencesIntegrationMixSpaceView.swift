//
//  PreferencesIntegrationMixSpaceView.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/8.
//

import AppKit
import SnapKit

@MainActor
final class PreferencesIntegrationMixSpaceView: IntegrationView {
    // Controls
    private let enabledButton: NSButton
    private let endpointInput: NSTextField
    private let methodSelect: NSPopUpButton
    private let apiKeyInput: NSSecureTextField

    private lazy var saveButton: NSButton = {
        var saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.bezelStyle = .push
        saveButton.keyEquivalent = "\r"
        return saveButton
    }()

    private lazy var resetButton: NSButton = {
        var resetButton = NSButton(title: "Reset", target: self, action: #selector(reset))
        resetButton.bezelStyle = .rounded
        return resetButton
    }()

    init() {
        // Initialize controls
        enabledButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)

        endpointInput = NSScrollTextField()
        endpointInput.placeholderString = "Enter endpoint URL"

        // Enable standard key bindings

        endpointInput.cell?.sendsActionOnEndEditing = true

        methodSelect = NSPopUpButton(frame: .zero, pullsDown: false)
        methodSelect.addItems(withTitles: ["POST", "PUT", "DELETE", "PATCH"])
        methodSelect.controlSize = .regular
        methodSelect.font = .systemFont(ofSize: NSFont.systemFontSize)

        apiKeyInput = NSScrollSecureTextField()
        apiKeyInput.placeholderString = "Enter API Key"

        apiKeyInput.cell?.sendsActionOnEndEditing = true

        super.init(frame: .zero)

        setupGridView()
        synchronizeUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func synchronizeUI() {
        // Synchronize UI with data model
        let integration = PreferencesDataModel.shared.mixSpaceIntegration.value
        enabledButton.state = integration.isEnabled ? .on : .off
        endpointInput.stringValue = integration.endpoint
        methodSelect.selectItem(withTitle: integration.requestMethod)
        apiKeyInput.stringValue = integration.apiToken
    }

    @objc
    private func reset() {
        synchronizeUI()
    }

    @objc
    private func save() {
        // Save the integration settings
        let previousIntegration = PreferencesDataModel.shared.mixSpaceIntegration.value
        var integration = previousIntegration
        integration.isEnabled = enabledButton.state == .on
        integration.endpoint = endpointInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        integration.requestMethod = methodSelect.selectedItem?.title ?? "POST"
        integration.apiToken = apiKeyInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if integration.isEnabled {
            guard let components = URLComponents(string: integration.endpoint),
                  let scheme = components.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  let host = components.host,
                  scheme == "https" || isLoopbackHost(host)
            else {
                ToastManager.shared.error(
                    "Mix Space endpoint must use HTTPS; HTTP is allowed only for localhost")
                return
            }
            guard !integration.apiToken.isEmpty else {
                ToastManager.shared.error("Mix Space API key is required when the integration is enabled")
                return
            }
        }
        guard integration.persistCredentialChanges(comparedTo: previousIntegration) else {
            ToastManager.shared.error("Could not update the Mix Space API key in Keychain")
            return
        }
        PreferencesDataModel.shared.mixSpaceIntegration.accept(integration)
        ToastManager.shared.success("Saved!")
    }

    private func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.lowercased()
        return normalized == "localhost" || normalized == "::1" || normalized.hasPrefix("127.")
    }

    private func setupGridView() {
        setupUI()

        // Enabled row
        createRow(
            leftView: NSTextField(labelWithString: "Enabled"),
            rightView: enabledButton
        )

        // Endpoint row
        createRow(
            leftView: NSTextField(labelWithString: "Endpoint"),
            rightView: endpointInput
        )

        // Method row
        createRow(
            leftView: NSTextField(labelWithString: "Request Method"),
            rightView: methodSelect
        )

        // API Key row
        createRow(
            leftView: NSTextField(labelWithString: "API Key"),
            rightView: apiKeyInput
        )

        // Save button row
        let buttonStack = NSStackView()
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        buttonStack.addArrangedSubview(resetButton)
        buttonStack.addArrangedSubview(saveButton)
        gridView.addRow(with: [NSView(), buttonStack])
        gridView.cell(for: buttonStack)?.xPlacement = .trailing
    }
}
