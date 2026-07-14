//
//  PreferencesIntegrationMixSpaceView.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/8.
//

import AppKit
import SnapKit
import SwiftUI

@MainActor
final class PreferencesIntegrationS3View: IntegrationView {
  // Controls
  private let enabledButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
  private lazy var bucketInput: NSScrollTextField = .init()
  private lazy var regionInput: NSScrollTextField = .init()
  private lazy var accessKeyInput: NSScrollTextField = .init()
  private lazy var secretKeyInput: NSScrollSecureTextField = .init()
  private lazy var endpointInput: NSScrollTextField = .init()
  private lazy var pathInput: NSScrollTextField = .init()
  private lazy var customDomainInput: NSScrollTextField = .init()
  private var displayedIntegration = S3Integration()

  private lazy var testButton: NSButton = {
    let button = NSButton(
      title: "Select App & Test Upload", target: self, action: #selector(testUpload)
    )
    button.bezelStyle = .rounded
    return button
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

    // Configure controls
    bucketInput.placeholderString = "Enter S3 bucket name"
    regionInput.placeholderString = "Enter region (e.g., us-east-1)"
    accessKeyInput.placeholderString = "Enter Access Key"
    secretKeyInput.placeholderString = "Enter Secret Key"
    endpointInput.placeholderString = "Custom endpoint (optional)"
    pathInput.placeholderString = "Object path (optional)"
    customDomainInput.placeholderString = "Public URL prefix (optional)"

    setupGridView()
    synchronizeUI()
    bindToCredentialReadiness(
      controls: [
        enabledButton, bucketInput, regionInput, accessKeyInput, secretKeyInput,
        endpointInput, pathInput, customDomainInput, testButton, resetButton, saveButton,
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
    let integration = PreferencesDataModel.s3Integration.value
    displayedIntegration = integration
    enabledButton.state = integration.isEnabled ? .on : .off
    bucketInput.stringValue = integration.bucket
    regionInput.stringValue = integration.region
    accessKeyInput.stringValue = integration.accessKey
    secretKeyInput.stringValue = integration.secretKey
    endpointInput.stringValue = integration.endpoint
    pathInput.stringValue = integration.path
    customDomainInput.stringValue = integration.customDomain
  }

  @objc private func reset() {
    synchronizeUI()
  }

  @objc private func save() {
    let formBaseline = displayedIntegration
    guard let requestedIntegration = integrationFromForm(
      baseline: formBaseline,
      requireCompleteConfiguration: false
    ) else { return }
    saveButton.isEnabled = false
    SettingsMutationCoordinator.shared.enqueue { [self] in
      let previousIntegration = PreferencesDataModel.s3Integration.value
      var integration = previousIntegration
      if requestedIntegration.isEnabled != formBaseline.isEnabled {
        integration.isEnabled = requestedIntegration.isEnabled
      }
      if requestedIntegration.bucket != formBaseline.bucket {
        integration.bucket = requestedIntegration.bucket
      }
      if requestedIntegration.region != formBaseline.region {
        integration.region = requestedIntegration.region
      }
      if requestedIntegration.accessKey != formBaseline.accessKey {
        integration.accessKey = requestedIntegration.accessKey
      }
      if requestedIntegration.secretKey != formBaseline.secretKey {
        integration.secretKey = requestedIntegration.secretKey
      }
      if requestedIntegration.endpoint != formBaseline.endpoint {
        integration.endpoint = requestedIntegration.endpoint
      }
      if requestedIntegration.path != formBaseline.path {
        integration.path = requestedIntegration.path
      }
      if requestedIntegration.customDomain != formBaseline.customDomain {
        integration.customDomain = requestedIntegration.customDomain
      }
      guard self.validate(integration, requireCompleteConfiguration: false) else {
        self.saveButton.isEnabled = true
        return
      }
      let persistenceResult = await integration.persistCredentialChanges(
        comparedTo: previousIntegration)
      self.saveButton.isEnabled = true
      guard persistenceResult.succeeded else {
        ToastManager.shared.error("Could not update the S3 credentials in Keychain")
        return
      }
      PreferencesDataModel.s3Integration.accept(integration)
      self.synchronizeUI()
      var warnings: [String] = []
      if persistenceResult.retainedClearedKeychainValue {
        warnings.append("an inaccessible Keychain copy may remain")
      }
      if persistenceResult.usedLocalFallback {
        warnings.append("new credentials were saved locally because Keychain was unavailable")
      }
      if warnings.isEmpty {
        ToastManager.shared.success("Saved!")
      } else {
        ToastManager.shared.warning("Saved, but " + warnings.joined(separator: "; "))
      }
    }
  }

  @objc private func testUpload() {
    guard let integration = integrationFromForm(
      baseline: PreferencesDataModel.s3Integration.value,
      requireCompleteConfiguration: true
    ) else { return }

    // Create app picker view
    AppPickerView.showAppPicker(for: testButton) { appId, appURL in
      guard appId != nil, let appURL = appURL else {
        return // User canceled
      }

      // Get app icon
      let appIcon = NSWorkspace.shared.icon(forFile: appURL.path)
      if let iconData = appIcon.data {
        // Perform upload
        Task { @MainActor in
          do {
            let url = try await S3Uploader.uploadIconToS3(
              iconData,
              appName: appURL.lastPathComponent,
              config: integration
            )
            ToastManager.shared.success("Upload successful: \(url)")
          } catch {
            ToastManager.shared.error("Upload failed: \(error.localizedDescription)")
          }
        }
      } else {
        ToastManager.shared.error("Failed to convert app icon to image data")
      }
    }
  }

  private func integrationFromForm(
    baseline: S3Integration,
    requireCompleteConfiguration: Bool
  ) -> S3Integration? {
    var integration = baseline
    integration.isEnabled = enabledButton.state == .on
    integration.bucket = bucketInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    integration.region = regionInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    integration.accessKey = accessKeyInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    integration.secretKey = secretKeyInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    integration.endpoint = endpointInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    integration.path = pathInput.stringValue
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    integration.customDomain = customDomainInput.stringValue
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

    guard validate(
      integration,
      requireCompleteConfiguration: requireCompleteConfiguration
    ) else { return nil }
    return integration
  }

  private func validate(
    _ integration: S3Integration,
    requireCompleteConfiguration: Bool
  ) -> Bool {
    let requiresCredentials = requireCompleteConfiguration || integration.isEnabled
    if requiresCredentials,
       [integration.bucket, integration.region, integration.accessKey, integration.secretKey]
       .contains(where: \.isEmpty)
    {
      ToastManager.shared.error("Bucket, region, access key, and secret key are required")
      return false
    }

    for (label, value) in [("endpoint", integration.endpoint), ("custom domain", integration.customDomain)]
      where !value.isEmpty
    {
      guard let components = URLComponents(string: value),
            let scheme = components.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            let host = components.host
      else {
        ToastManager.shared.error("The S3 \(label) must be a valid HTTP or HTTPS URL")
        return false
      }
      if label == "endpoint", scheme != "https", !isLoopbackHost(host) {
        ToastManager.shared.error(
          "The S3 \(label) must use HTTPS; HTTP is allowed only for localhost")
        return false
      }
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

    // Bucket row
    createRow(
      leftView: NSTextField(labelWithString: "Bucket"),
      rightView: bucketInput
    )

    // Region row
    createRow(
      leftView: NSTextField(labelWithString: "Region"),
      rightView: regionInput
    )

    // Access Key row
    createRow(
      leftView: NSTextField(labelWithString: "Access Key"),
      rightView: accessKeyInput
    )

    // Secret Key row
    createRow(
      leftView: NSTextField(labelWithString: "Secret Key"),
      rightView: secretKeyInput
    )

    // Endpoint row
    createRow(
      leftView: NSTextField(labelWithString: "Custom Endpoint"),
      rightView: endpointInput
    )

    // Custom Domain row
    createRow(
      leftView: NSTextField(labelWithString: "Custom Domain"),
      rightView: customDomainInput
    )

    // Path row
    createRow(
      leftView: NSTextField(labelWithString: "Path"),
      rightView: pathInput
    )

    // Test button row
    createRow(
      leftView: NSView(),
      rightView: testButton
    )
    gridView.cell(for: testButton)?.xPlacement = .trailing

    // Save button row
    let buttonStack = NSStackView()
    buttonStack.orientation = .horizontal
    buttonStack.spacing = 8
    buttonStack.addArrangedSubview(resetButton)
    buttonStack.addArrangedSubview(saveButton)
    let leftButtonStack = NSStackView()
    leftButtonStack.orientation = .horizontal
    let showDatabaseButton = NSButton(
      title: "Show Database", target: self, action: #selector(showDatabase)
    )
    leftButtonStack.addArrangedSubview(showDatabaseButton)
    gridView.addRow(with: [leftButtonStack, buttonStack])
    gridView.cell(for: buttonStack)?.xPlacement = .trailing
  }

  @objc private func showDatabase() {
    let viewController = PreferencesS3IconsViewController()
    // Open modal sheet
    NSApplication.shared.keyWindow?.contentViewController?.presentAsSheet(viewController)
  }
}
