//
//  PreferencesFilterViewController.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/13.
//

import AppKit
import SnapKit
import SwiftUI

@MainActor
final class PreferencesFilterViewController: NSViewController, SettingWindowProtocol {
    let frameSize: NSSize = .init(width: 600, height: 400)

    private var preferencesHostingController: PreferencesHostingController?
    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: frameSize))
        let hostingController = PreferencesHostingController()
        preferencesHostingController = hostingController
        view.addSubview(hostingController.view)
        addChild(hostingController)
        hostingController.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }
}
