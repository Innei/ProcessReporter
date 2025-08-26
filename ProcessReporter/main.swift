import AppKit

var reporter: Reporter?

func main() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate

    Task { @MainActor in
        do {
            try await DataStore.shared.initialize()
            reporter = Reporter()
        } catch {
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

    setupMenu()
    _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
}

private func setupMenu() {
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

main()
