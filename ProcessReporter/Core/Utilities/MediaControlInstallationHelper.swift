//
//  MediaControlInstallationHelper.swift
//  ProcessReporter
//
//  Created by Claude on 2025/7/12.
//

import Cocoa
import Foundation

class MediaControlInstallationHelper {

    static func checkAndPromptInstallation() {
        // Only check on macOS 15.4+ where CLI provider is used
        guard #available(macOS 15.4, *) else { return }

        // Don't show if already prompted before
        guard !PreferencesDataModel.hasShownMediaControlInstallPrompt.value else { return }

        // Don't show if media-control is already installed
        guard !CLIMediaInfoProvider.isMediaControlInstalled() else {
            // Mark as shown since it's installed
            PreferencesDataModel.hasShownMediaControlInstallPrompt.accept(true)
            return
        }

        // Show the installation prompt
        showInstallationPrompt()
    }

    private static func showInstallationPrompt() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Media Control Required"
            alert.informativeText = """
                ProcessReporter needs the 'media-control' tool to monitor media playback on macOS 15.4+.

                This tool allows the app to detect currently playing music and media information.

                Would you like to install it now?
                """

            alert.addButton(withTitle: "Install Now")
            alert.addButton(withTitle: "Manual Installation")
            alert.addButton(withTitle: "Skip")

            alert.alertStyle = .informational

            let response = alert.runModal()

            // Mark as shown regardless of choice
            PreferencesDataModel.hasShownMediaControlInstallPrompt.accept(true)

            switch response {
            case .alertFirstButtonReturn:  // Install Now
                openBrewInstallationInstructions()
            case .alertSecondButtonReturn:  // Manual Installation
                openGitHubRepository()
            case .alertThirdButtonReturn:  // Skip
                break
            default:
                break
            }
        }
    }

    private static func openBrewInstallationInstructions() {
        let alert = NSAlert()
        alert.messageText = "Installation Instructions"
        alert.informativeText = """
            To install media-control using Homebrew:

            1. Open Terminal
            2. Run: brew tap ungive/media-control && brew install media-control
            3. Restart ProcessReporter after installation

            If you don't have Homebrew installed, click "Manual Installation" for other options.
            """

        alert.addButton(withTitle: "Copy Command")
        alert.addButton(withTitle: "Manual Installation")
        alert.addButton(withTitle: "Close")

        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn:  // Copy Command
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString("brew tap ungive/media-control && brew install media-control", forType: .string)

            // Show confirmation
            let confirmation = NSAlert()
            confirmation.messageText = "Command Copied"
            confirmation.informativeText =
                "The installation command has been copied to your clipboard. Paste it in Terminal to install."
            confirmation.addButton(withTitle: "OK")
            confirmation.runModal()

        case .alertSecondButtonReturn:  // Manual Installation
            openGitHubRepository()

        default:
            break
        }
    }

    private static func openGitHubRepository() {
        if let url = URL(string: "https://github.com/ungive/media-control") {
            NSWorkspace.shared.open(url)
        }
    }
}
