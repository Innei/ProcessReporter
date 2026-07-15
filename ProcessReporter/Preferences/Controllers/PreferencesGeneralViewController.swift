//
//  PreferencesGeneralViewController.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/6.
//

import AppKit
import os.log
import ServiceManagement
import SnapKit

@MainActor
final class PreferencesGeneralViewController: NSViewController, SettingWindowProtocol {
    private let logger = Logger()
    final let frameSize: NSSize = .init(width: 600, height: 320)

    private var gridView: NSGridView!

    // MARK: - App UI Elements

    private var enabledButton: NSButton!
    private var startupButton: NSButton!

    // MARK: - Reporter UI Elements

    private var intervalPopup: NSPopUpButton!
    private var focusReportButton: NSButton!
    private var ignoreArtistButton: NSButton!

    // MARK: - Types UI Elements

    private var enabledProcessButton: NSButton!
    private var enabledMediaButton: NSButton!

    private var spacer: NSView {
        NSView()
    }

    override func loadView() {
        super.loadView()
        view.frame = NSRect(origin: .zero, size: frameSize)
        setupUI()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        synchronizeUI()
    }

    private func synchronizeUI() {
        enabledButton.state = PreferencesDataModel.shared.reportingAllowed ? .on : .off
        intervalPopup.selectItem(
            withTitle: PreferencesDataModel.shared.sendInterval.value.toString())
        focusReportButton.state = PreferencesDataModel.shared.focusReport.value ? .on : .off
        startupButton.state = checkWasLaunchedAtLogin() ? .on : .off
        enabledProcessButton.state = PreferencesDataModel.shared.enabledTypes.value.types.contains(.process) ? .on : .off
        enabledMediaButton.state = PreferencesDataModel.shared.enabledTypes.value.types.contains(.media) ? .on : .off
        ignoreArtistButton.state = PreferencesDataModel.shared.ignoreNullArtist.value ? .on : .off
    }

    private func setupUI() {
        gridView = NSGridView()
        gridView.rowSpacing = 16
        gridView.columnSpacing = 12

        view.addSubview(gridView)

        gridView.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.top.equalToSuperview().offset(40)
            make.width.lessThanOrEqualTo(560)
        }

        // Enabled checkbox

        enabledButton = NSButton(
            checkboxWithTitle: "Enabled", target: self, action: #selector(enabledButtonClicked))
        createRow(leftView: NSTextField(labelWithString: "App:"), rightView: enabledButton)

        startupButton = NSButton(
            checkboxWithTitle: "Start at login", target: self, action: #selector(toggleStartAtLogin))
        createRow(leftView: spacer, rightView: startupButton)

        focusReportButton = NSButton(
            checkboxWithTitle: "Report when application focused", target: self,
            action: #selector(focusReportButtonClicked))
        createRow(
            leftView: NSTextField(labelWithString: "Report:"), rightView: focusReportButton)

        ignoreArtistButton = NSButton(
            checkboxWithTitle: "When the artist is a null value then ignore report", target: self, action: #selector(ignoreArtistButtonClicked))
        createRow(leftView: spacer, rightView: ignoreArtistButton)

        // Send Interval label and popup
        intervalPopup = NSPopUpButton()
        intervalPopup.isEnabled = true
        intervalPopup.autoenablesItems = false
        intervalPopup.addItems(
            withTitles:
            SendInterval.toLabels()
        )
        intervalPopup.action = #selector(switchInterval)
        intervalPopup.target = self
        createRow(
            leftView: NSTextField(labelWithString: "Send Interval:"), rightView: intervalPopup)

        // Enabled Process/Media checkboxes
        enabledProcessButton = NSButton(
            checkboxWithTitle: "Process", target: self, action: #selector(enabledProcessButtonClicked))
        enabledMediaButton = NSButton(
            checkboxWithTitle: "Media", target: self, action: #selector(enabledMediaButtonClicked))
        let reportButtonGroup = NSStackView()
        reportButtonGroup.orientation = .horizontal
        reportButtonGroup.spacing = 8
        reportButtonGroup.addArrangedSubview(enabledProcessButton)
        reportButtonGroup.addArrangedSubview(enabledMediaButton)
        createRow(leftView: NSTextField(labelWithString: "Report Types:"), rightView: reportButtonGroup)

        // Separator
        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        separator.snp.makeConstraints { make in
            make.height.equalTo(1)
        }

        gridView.addRow(with: [spacer, separator])
//        gridView.row(at: gridView.numberOfRows - 1).mergeCells(in: NSRange(location: 0, length: 2))

        // Data Control Stack
        let dataControlStackView = NSStackView()
        dataControlStackView.orientation = .horizontal
        dataControlStackView.spacing = 8

        // Data Control Label
        let dataControlLabel = NSTextField(labelWithString: "Setting Backup:")
        dataControlLabel.isEditable = false

        // Import Data button
        let dataImportButton = NSButton(
            title: "Import Settings", target: self, action: #selector(importData))
        dataImportButton.bezelStyle = .rounded
        dataControlStackView.addArrangedSubview(dataImportButton)

        // Export Data button
        let dataExportButton = NSButton(
            title: "Export Settings", target: self, action: #selector(exportData))
        dataExportButton.bezelStyle = .rounded
        dataControlStackView.addArrangedSubview(dataExportButton)

        // 将整个 stack 添加到 gridView 中
        createRow(leftView: dataControlLabel, rightView: dataControlStackView)
    }

    private func checkWasLaunchedAtLogin() -> Bool {
        let appService = SMAppService.mainApp

        switch appService.status {
        case .enabled:
            return true
        case .notRegistered, .notFound:
            return false
        default:
            return false
        }
    }
}

// MARK: UI Utils

extension PreferencesGeneralViewController {
    private func createRow(leftView: NSView, rightView: NSView) {
        let row = gridView.addRow(with: [leftView, rightView])
        gridView.cell(for: leftView)?.xPlacement = .trailing
        row.height = 18
    }
}

// MARK: Actions

extension PreferencesGeneralViewController {
    @objc private func switchInterval(sender: NSPopUpButton) {
        guard let label = sender.selectedItem?.title,
              let interval = SendInterval.labelToValue(label)
        else { return }
        PreferencesDataModel.shared.sendInterval.accept(
            interval)
    }

    @objc private func enabledButtonClicked(sender: NSButton) {
        let requestedValue = sender.state == .on
        guard PreferencesDataModel.shared.setReportingEnabled(requestedValue) else {
            sender.state = .off
            ToastManager.shared.warning(
                "Reporting remains paused until the credential store is recovered"
            )
            return
        }
    }

    @objc private func focusReportButtonClicked(sender: NSButton) {
        PreferencesDataModel.shared.focusReport.accept(sender.state == .on)
    }

    @objc private func toggleStartAtLogin(sender: NSButton) {
        let isOn = sender.state == .on

        do {
            if isOn {
                switch SMAppService.mainApp.status {
                case .enabled:
                    break
                case .requiresApproval:
                    ToastManager.shared.warning(
                        "Allow ProcessReporter in System Settings > General > Login Items")
                default:
                    try SMAppService.mainApp.register()
                }
            } else {
                switch SMAppService.mainApp.status {
                case .notRegistered, .notFound:
                    break
                default:
                    try SMAppService.mainApp.unregister()
                }
            }
            sender.state = checkWasLaunchedAtLogin() ? .on : .off
        } catch {
            logger.error(
                "Failed to \(isOn ? "enable" : "disable") launch at login: \(error.localizedDescription)"
            )
            sender.state = checkWasLaunchedAtLogin() ? .on : .off
            ToastManager.shared.error("Could not update launch at login: \(error.localizedDescription)")
        }
    }

    @objc private func enabledProcessButtonClicked(sender: NSButton) {
        var types = PreferencesDataModel.shared.enabledTypes.value.types
        if sender.state == .on {
            types.insert(.process)
        } else {
            types.remove(.process)
        }
        PreferencesDataModel.shared.enabledTypes.accept(.init(types: types))
    }

    @objc private func enabledMediaButtonClicked(sender: NSButton) {
        var types = PreferencesDataModel.shared.enabledTypes.value.types
        if sender.state == .on {
            types.insert(.media)
        } else {
            types.remove(.media)
        }
        PreferencesDataModel.shared.enabledTypes.accept(.init(types: types))
    }

    @objc func ignoreArtistButtonClicked(sender: NSButton) {
        PreferencesDataModel.shared.ignoreNullArtist.accept(sender.state == .on)
    }

    @objc func exportData() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.canCreateDirectories = true
        openPanel.title = "Choose a directory to export data"
        openPanel.showsHiddenFiles = false
        openPanel.prompt = "Export"

        let fileName = "ProcessReporterData.plist"

        guard let data = PreferencesDataModel.shared.exportToPlist() else {
            ToastManager.shared.error("Export failed: Settings could not be encoded")
            return
        }

        if openPanel.runModal() == .OK {
            guard let selectedURL = openPanel.url else {
                return
            }

            let filePathURL = selectedURL.appendingPathComponent(fileName)

            do {
                // Atomic writing preserves the existing backup if the new write fails.
                try data.write(to: filePathURL, options: [.atomic])
                ToastManager.shared.success("Settings exported successfully; credentials were excluded")
            } catch {
                ToastManager.shared.error("Export failed: \(error.localizedDescription)")
            }
        }
    }

    @objc func importData() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false
        openPanel.canCreateDirectories = false
        openPanel.title = "Choose a file to import data"
        openPanel.showsHiddenFiles = true
        openPanel.prompt = "Import"
        openPanel.allowedContentTypes = [.propertyList]

        if openPanel.runModal() != .OK {
            return
        }

        guard let selectedURL = openPanel.url else {
            return
        }

        do {
            let data = try Data(contentsOf: selectedURL)
            SettingsMutationCoordinator.shared.enqueue { [self] in
                switch await PreferencesDataModel.importFromPlist(data: data) {
                case let .success(integrationsRequiringReview, ignoredFields):
                    var warnings: [String] = []
                    if !integrationsRequiringReview.isEmpty {
                        warnings.append(
                            "Review changed destinations before re-enabling "
                                + integrationsRequiringReview.joined(separator: " and ")
                                + "."
                        )
                    }
                    if !ignoredFields.isEmpty {
                        warnings.append(
                            "Ignored invalid fields: "
                                + ignoredFields.joined(separator: ", ")
                                + "."
                        )
                    }

                    if warnings.isEmpty {
                        ToastManager.shared.success("Settings imported successfully")
                    } else {
                        ToastManager.shared.warning("Settings imported. " + warnings.joined(separator: " "))
                    }
                    synchronizeUI()
                case .invalid:
                    ToastManager.shared.error("Import failed: Invalid data format")
                }
            }
        } catch {
            ToastManager.shared.error("Import failed: \(error.localizedDescription)")
        }
    }
}
