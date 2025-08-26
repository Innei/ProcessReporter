//
//  IconModel.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/14.
//

import Foundation
import SwiftData

// Current version of IconModel
@Model
class IconModel {
    var name: String
    var url: String
    @Attribute(.unique)
    var applicationIdentifier: String

    // Add timestamp for tracking
    var createdAt: Date
    var updatedAt: Date

    init(name: String, url: String, applicationIdentifier: String) {
        self.name = name
        self.url = url
        self.applicationIdentifier = applicationIdentifier
        self.createdAt = .now
        self.updatedAt = .now
    }
}
