//
//  PreferencesIntegrationSlackView.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/8.
//

import AppKit
import RxCocoa
import RxSwift
import SnapKit

private let statusExpirationOptions = [30, 60, 120, 300]

@MainActor
final class PreferencesIntegrationSlackView: IntegrationView {
    private var displayedIntegration = SlackIntegration()
    private lazy var enabledButton: NSButton = {
        let button = NSButton(
            checkboxWithTitle: "", target: nil, action: nil
        )

        return button
    }()

    private lazy var globalCustomEmojiInput: NSScrollTextField = {
        let textField = NSScrollTextField()
        textField.placeholderString = "Custom Emoji"

        return textField
    }()

    private lazy var emojiPickerButton: NSButton = {
        let button = NSButton(
            title: "😀", target: nil, action: #selector(NSApp.orderFrontCharacterPalette)
        )
        let emojiImage = NSImage(
            systemSymbolName: "face.smiling", accessibilityDescription: "open emoji panel"
        )
        button.image = emojiImage
        button.target = NSApp
        // Use .inline or .texturedRounded for a more compact look if desired
        button.bezelStyle = .inline
        button.isBordered = false  // Optional: remove border for tighter integration
        return button
    }()

    private lazy var statusTextTemplateStringInput: NSScrollTextField = {
        let textField = NSScrollTextField()
        textField.placeholderString = "Custom Status Text"
        return textField
    }()

    private lazy var apiKeyInput: NSScrollSecureTextField = {
        let textField = NSScrollSecureTextField()
        textField.placeholderString = "xoxp-"
        return textField
    }()

    private lazy var statusExpirationDropdown: NSPopUpButton = {
        let button = NSPopUpButton()
        button.addItems(withTitles: statusExpirationOptions.map { String($0) })

        return button
    }()

    private lazy var defaultEmojiInput: NSScrollTextField = {
        let textField = NSScrollTextField()
        textField.placeholderString = "Default Emoji"
        return textField
    }()

    private lazy var defaultStatusTextInput: NSScrollTextField = {
        let textField = NSScrollTextField()
        textField.placeholderString = "Default Status Text"
        return textField
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

    private lazy var conditionEmojiButton: NSButton = {
        let button = NSButton(
            title: "Condition", target: self, action: #selector(openConditionEmojiModal)
        )
        button.bezelStyle = .rounded
        return button
    }()

    init() {
        super.init(frame: .zero)

        setupUI()
        synchronizeUI()
        bindToCredentialReadiness(
            controls: [
                enabledButton, apiKeyInput, globalCustomEmojiInput,
                statusTextTemplateStringInput, statusExpirationDropdown,
                defaultEmojiInput, defaultStatusTextInput, conditionEmojiButton,
                resetButton, saveButton,
            ],
            onReady: { [weak self] in self?.synchronizeUI() }
        )
    }

    override func setupUI() {
        super.setupUI()

        // Enabled row
        createRow(
            leftView: NSTextField(labelWithString: "Enabled"),
            rightView: enabledButton
        )

        let text = "Go to https://api.slack.com/apps to create a new app"
        let url = "https://api.slack.com/apps"

        // 创建一个 NSMutableAttributedString 以便我们可以添加多个属性
        let attributedText = NSMutableAttributedString(string: text)

        // 设置整个文本的颜色
        attributedText.addAttribute(
            .foregroundColor,
            value: NSColor.secondaryLabelColor,
            range: NSRange(location: 0, length: text.count)
        )

        // 找到 URL 的范围
        if let urlRange = text.range(of: url) {
            let nsRange = NSRange(urlRange, in: text)

            // 添加链接属性
            attributedText.addAttributes(
                [
                    .link: URL(string: url)!,
                    .foregroundColor: NSColor.linkColor,  // 使用系统默认的链接颜色
                ], range: nsRange
            )
        }

        createRowDescription(attributedText: attributedText)

        createRowDescription(
            text: """
                1. Go to Oauth - Scopes - User Token Scopes.
                2. Add `users.profile:write`
                3. Install App to Workspace
                4. Copy the User OAuth Token, which starts with `xoxp-`
                """
        )

        // Api Key row
        createRow(
            leftView: NSTextField(labelWithString: "API Key"),
            rightView: apiKeyInput
        )

        // Custom Emoji row
        createRow(
            leftView: NSTextField(labelWithString: "Emoji"),
            rightView: {
                let stackView = NSStackView()
                stackView.orientation = .horizontal
                stackView.spacing = 8

                stackView.addArrangedSubview(globalCustomEmojiInput)
                stackView.addArrangedSubview(emojiPickerButton)
                globalCustomEmojiInput.snp.makeConstraints { make in
                    make.width.greaterThanOrEqualTo(160)
                }
                emojiPickerButton.snp.makeConstraints { make in
                    make.width.equalTo(24)
                }

                stackView.addArrangedSubview(conditionEmojiButton)
                return stackView
            }()
        )

        // Custom Status Text row
        createRow(
            leftView: NSTextField(labelWithString: "Status Text"),
            rightView: statusTextTemplateStringInput
        )

        // Status Expiration row
        createRow(
            leftView: NSTextField(labelWithString: "Status Expiration"),
            rightView: statusExpirationDropdown
        )

        // Default Emoji row
        createRow(
            leftView: NSTextField(labelWithString: "Default Emoji"),
            rightView: defaultEmojiInput
        )

        // Default Status Text row
        createRow(
            leftView: NSTextField(labelWithString: "Default Status Text"),
            rightView: defaultStatusTextInput
        )

        createRowDescription(
            text:
                """
                Template String Usage:
                1. {media_process_name}
                   - Current media process name
                2. {media_name}
                   - Current media name
                3. {artist}
                   - Current media artist
                4. {media_name_artist}
                   - Current media name and artist
                5. {process_name}
                   - Current process name
                """
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

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func synchronizeUI() {
        // Synchronize UI with data model
        let integration = PreferencesDataModel.shared.slackIntegration.value
        displayedIntegration = integration
        enabledButton.state = integration.isEnabled ? .on : .off
        globalCustomEmojiInput.stringValue = integration.globalCustomEmoji
        statusTextTemplateStringInput.stringValue = integration.statusTextTemplateString
        statusExpirationDropdown.selectItem(
            at: statusExpirationOptions.firstIndex(of: integration.expiration) ?? 0)
        defaultEmojiInput.stringValue = integration.defaultEmoji
        defaultStatusTextInput.stringValue = integration.defaultStatusText
        apiKeyInput.stringValue = integration.apiToken
    }

    @objc private func reset() {
        synchronizeUI()
    }

    @objc private func save() {
        let formBaseline = displayedIntegration
        let requestedIsEnabled = enabledButton.state == .on
        let requestedGlobalCustomEmoji = globalCustomEmojiInput.stringValue
        let requestedStatusTemplate = statusTextTemplateStringInput.stringValue
        guard statusExpirationOptions.indices.contains(statusExpirationDropdown.indexOfSelectedItem)
        else {
            ToastManager.shared.error("Select a valid status expiration")
            return
        }
        let requestedExpiration = statusExpirationOptions[statusExpirationDropdown.indexOfSelectedItem]
        let requestedDefaultEmoji = defaultEmojiInput.stringValue
        let requestedDefaultStatusText = defaultStatusTextInput.stringValue
        let requestedAPIToken = apiKeyInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if requestedIsEnabled && requestedAPIToken.isEmpty {
            ToastManager.shared.error("Slack API token is required when the integration is enabled")
            return
        }
        saveButton.isEnabled = false
        SettingsMutationCoordinator.shared.enqueue { [self] in
            let previousIntegration = PreferencesDataModel.shared.slackIntegration.value
            var integration = previousIntegration
            if requestedIsEnabled != formBaseline.isEnabled {
                integration.isEnabled = requestedIsEnabled
            }
            if requestedGlobalCustomEmoji != formBaseline.globalCustomEmoji {
                integration.globalCustomEmoji = requestedGlobalCustomEmoji
            }
            if requestedStatusTemplate != formBaseline.statusTextTemplateString {
                integration.statusTextTemplateString = requestedStatusTemplate
            }
            if requestedExpiration != formBaseline.expiration {
                integration.expiration = requestedExpiration
            }
            if requestedDefaultEmoji != formBaseline.defaultEmoji {
                integration.defaultEmoji = requestedDefaultEmoji
            }
            if requestedDefaultStatusText != formBaseline.defaultStatusText {
                integration.defaultStatusText = requestedDefaultStatusText
            }
            if requestedAPIToken != formBaseline.apiToken {
                integration.apiToken = requestedAPIToken
            }
            guard !integration.isEnabled || !integration.apiToken.isEmpty else {
                self.saveButton.isEnabled = true
                ToastManager.shared.error(
                    "Slack API token is required when the integration is enabled")
                return
            }
            let persistenceResult = await integration.persistCredentialChanges(
                comparedTo: previousIntegration)
            self.saveButton.isEnabled = true
            guard persistenceResult.succeeded else {
                ToastManager.shared.error("Could not update the Slack API token in Keychain")
                return
            }
            PreferencesDataModel.shared.slackIntegration.accept(integration)
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

    @objc private func openConditionEmojiModal() {
        NSApplication.shared.keyWindow?.contentViewController?.presentAsSheet(
            EmojiConditionViewController())
    }
}
