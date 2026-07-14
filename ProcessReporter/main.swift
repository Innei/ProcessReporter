import AppKit

@MainActor
enum ApplicationState {
    static var reporter: Reporter?
    static var bootstrapTask: Task<Void, Never>?
    static var isTerminating = false
}

@MainActor
func main() {
    CredentialStore.recoverPendingPreferenceTransactions()
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate

    ApplicationState.bootstrapTask = SettingsMutationCoordinator.shared.enqueue {
        do {
            try await DataStore.shared.initialize()
            guard !Task.isCancelled, !ApplicationState.isTerminating else { return }
            await PreferencesDataModel.hydrateIntegrationCredentials()
            guard !Task.isCancelled, !ApplicationState.isTerminating else { return }
            ApplicationState.reporter = Reporter()
            if let warning = PreferencesDataModel.integrationCredentialRecoveryWarning {
                SettingWindowManager.shared.showWindow()
                if let window = SettingWindowManager.shared.settingWindow {
                    presentCredentialRecoveryWarning(warning, on: window)
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard !ApplicationState.isTerminating else { return }
            NSLog("Failed to initialize database: \(error)")
            // Show alert to user
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Database Initialization Failed"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApplication.shared.terminate(nil)
        }
    }

    setupMenu(appDelegate: delegate)
    _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
}

@MainActor
private func presentCredentialRecoveryWarning(_ warning: String, on window: NSWindow) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Integration Credentials Need Attention"
    alert.informativeText = warning

    guard PreferencesDataModel.integrationCredentialStoreUnavailable else {
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { _ in }
        return
    }

    alert.addButton(withTitle: "Keep Store")
    alert.addButton(withTitle: "Back Up Store and Quit")
    alert.beginSheetModal(for: window) { response in
        guard response == .alertSecondButtonReturn else { return }
        Task { @MainActor in
            let result = await CredentialStore.quarantineUnavailableJournal()
            let resultAlert = NSAlert()
            resultAlert.addButton(withTitle: "OK")

            switch result {
            case let .recovered(backupFileName):
                resultAlert.alertStyle = .informational
                resultAlert.messageText = "Credential Store Backed Up"
                resultAlert.informativeText =
                    "The unreadable store was preserved as \(backupFileName). "
                    + "Relaunch ProcessReporter and re-enter integration credentials."
                resultAlert.beginSheetModal(for: window) { _ in
                    NSApplication.shared.terminate(nil)
                }

            case .notRequired:
                resultAlert.alertStyle = .informational
                resultAlert.messageText = "Credential Store Is Readable"
                resultAlert.informativeText =
                    "The earlier failure was transient. Relaunch ProcessReporter to load credentials safely."
                resultAlert.beginSheetModal(for: window) { _ in
                    NSApplication.shared.terminate(nil)
                }

            case .failed:
                resultAlert.alertStyle = .critical
                resultAlert.messageText = "Credential Store Could Not Be Backed Up"
                resultAlert.informativeText =
                    "No credential data was replaced. Check permissions and available disk space, then try again."
                resultAlert.beginSheetModal(for: window) { _ in }
            }
        }
    }
}

@MainActor
private func setupMenu(appDelegate: AppDelegate) {
    let mainMenu = NSMenu()

    // MARK: - File Menu

    let fileMenu = NSMenu(title: "File")
    let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
    fileMenuItem.submenu = fileMenu

    fileMenu.addItem(NSMenuItem(
        title: "Close Window",
        action: #selector(NSWindow.performClose(_:)),
        keyEquivalent: "w"
    ))

    fileMenu.addItem(NSMenuItem(
        title: "Check for Updates…",
        action: #selector(AppDelegate.checkForUpdates(_:)),
        keyEquivalent: "",
        target: appDelegate
    ))

    fileMenu.addItem(NSMenuItem(
        title: "Quit App",
        action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"
    ))

    mainMenu.addItem(fileMenuItem)

    // MARK: - Edit menu

    let editMenu = NSMenu(title: "Edit")
    let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    editMenuItem.submenu = editMenu

    // 使用系统自带的 selector
    editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
    editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
    editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
    editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
    editMenu.addItem(NSMenuItem.separator())
    editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
    editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))

    mainMenu.addItem(editMenuItem)

    // 设置主菜单
    NSApp.mainMenu = mainMenu
}

MainActor.assumeIsolated {
    main()
}
