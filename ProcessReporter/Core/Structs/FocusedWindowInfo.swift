//
//  FocusedWindowInfo.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/15.
//

import Foundation
import Cocoa

struct FocusedWindowInfo {
    var appName: String
    var icon: NSImage?
    var applicationIdentifier: String

    var title: String?

    init(appName: String, icon: NSImage?, applicationIdentifier: String, title: String? = nil) {
        self.appName = appName
        self.icon = icon
        self.applicationIdentifier = applicationIdentifier
        self.title = title
    }
}
