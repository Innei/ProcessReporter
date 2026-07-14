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
    private var displayedIntegration = MixSpaceIntegration()

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
        bindToCredentialReadiness(
            controls: [
                enabledButton, endpointInput, methodSelect, apiKeyInput,
                resetButton, saveButton,
            ],
            onReady: { [weak self] in self?.synchronizeUI() }
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func synchronizeUI() {
        // Synchronize UI with data model
        let integration = PreferencesDataModel.shared.mixSpaceIntegration.value
        displayedIntegration = integration
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
        let formBaseline = displayedIntegration
        var requestedIntegration = formBaseline
        requestedIntegration.isEnabled = enabledButton.state == .on
        requestedIntegration.endpoint = endpointInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        requestedIntegration.requestMethod = methodSelect.selectedItem?.title ?? "POST"
        requestedIntegration.apiToken = apiKeyInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        guard validate(requestedIntegration) else { return }
        saveButton.isEnabled = false
        SettingsMutationCoordinator.shared.enqueue { [self] in
            let previousIntegration = PreferencesDataModel.shared.mixSpaceIntegration.value
            var integration = previousIntegration
            if requestedIntegration.isEnabled != formBaseline.isEnabled {
                integration.isEnabled = requestedIntegration.isEnabled
            }
            if requestedIntegration.endpoint != formBaseline.endpoint {
                integration.endpoint = requestedIntegration.endpoint
            }
            if requestedIntegration.requestMethod != formBaseline.requestMethod {
                integration.requestMethod = requestedIntegration.requestMethod
            }
            if requestedIntegration.apiToken != formBaseline.apiToken {
                integration.apiToken = requestedIntegration.apiToken
            }
            guard self.validate(integration) else {
                self.saveButton.isEnabled = true
                return
            }
            let persistenceResult = await integration.persistCredentialChanges(
                comparedTo: previousIntegration)
            self.saveButton.isEnabled = true
            guard persistenceResult.succeeded else {
                ToastManager.shared.error("Could not update the Mix Space API key in Keychain")
                return
            }
            PreferencesDataModel.shared.mixSpaceIntegration.accept(integration)
            self.synchronizeUI()
            if persistenceResult.retainedClearedKeychainValue {
                ToastManager.shared.warning(
                    "Saved, but an inaccessible Keychain copy may remain")
            } else if persistenceResult.usedLocalFallback {
                ToastManager.shared.warning(
                    "Saved locally because Keychain was unavailable")
            } else {
                ToastManager.shared.success("Saved!")
            }
        }
    }

    private func validate(_ integration: MixSpaceIntegration) -> Bool {
        guard integration.isEnabled else { return true }
        guard let components = URLComponents(string: integration.endpoint),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host,
              scheme == "https" || isLoopbackHost(host)
        else {
            ToastManager.shared.error(
                "Mix Space endpoint must use HTTPS; HTTP is allowed only for localhost")
            return false
        }
        guard !integration.apiToken.isEmpty else {
            ToastManager.shared.error("Mix Space API key is required when the integration is enabled")
            return false
        }
        return true
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
