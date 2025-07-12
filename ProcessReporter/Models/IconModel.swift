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

// Extension for database operations
extension IconModel {
    @MainActor 
    static func findIcon(for bundleID: String) async -> IconModel? {
        guard let context = await Database.shared.mainContext else { return nil }
        
        let descriptor = FetchDescriptor<IconModel>(
            predicate: #Predicate<IconModel> { icon in
                icon.applicationIdentifier == bundleID
            }
        )
        
        do {
            let results = try context.fetch(descriptor)
            return results.first
        } catch {
            print("Failed to fetch icon for \(bundleID): \(error)")
            return nil
        }
    }
    
    // Background operation to find or create icon
    static func findOrCreate(name: String, url: String, bundleID: String) async throws -> IconModel {
        return try await Database.shared.performBackgroundTask { context in
            let descriptor = FetchDescriptor<IconModel>(
                predicate: #Predicate<IconModel> { icon in
                    icon.applicationIdentifier == bundleID
                }
            )
            
            let results = try context.fetch(descriptor)
            
            if let existing = results.first {
                // Update existing if URL changed
                if existing.url != url {
                    existing.url = url
                    existing.updatedAt = .now
                }
                return existing
            } else {
                // Create new
                let newIcon = IconModel(name: name, url: url, applicationIdentifier: bundleID)
                context.insert(newIcon)
                try context.save()
                return newIcon
            }
        }
    }
    
    // Batch fetch icons
    static func fetchIcons(for bundleIDs: [String]) async throws -> [String: IconModel] {
        return try await Database.shared.performBackgroundTask { context in
            let descriptor = FetchDescriptor<IconModel>(
                predicate: #Predicate<IconModel> { icon in
                    bundleIDs.contains(icon.applicationIdentifier)
                }
            )
            
            let icons = try context.fetch(descriptor)
            
            var iconMap: [String: IconModel] = [:]
            for icon in icons {
                iconMap[icon.applicationIdentifier] = icon
            }
            
            return iconMap
        }
    }
}

// Legacy version schemas - kept for reference
// Note: These are not used in the current migration plan