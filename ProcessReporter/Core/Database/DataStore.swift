//
//  DataStore.swift
//  ProcessReporter
//
//  Created by Innei on 2025/8/26.
//

import Foundation
import SwiftData
import AppKit

// Value object used to persist reports without exposing SwiftData models
struct ReportValue {
    var id: UUID
    var processName: String?
    var windowTitle: String?
    var timeStamp: Date

    var artist: String?
    var mediaName: String?
    var mediaProcessName: String?
    var mediaDuration: Double?
    var mediaElapsedTime: Double?
    var mediaImageData: Data?

    var integrations: [String]
}

struct IconValue {
    var name: String
    var applicationIdentifier: String
    var url: String
    var createdAt: Date
    var updatedAt: Date
}

// Centralized store that is the only place allowed to touch SwiftData
actor DataStore {
    static let shared = DataStore()

    // Initialize underlying database/container
    func initialize() async throws {
        try await Database.shared.initialize()
    }

    // MARK: - Icons

    func iconURL(for bundleID: String) async -> String? {
        do {
            return try await Database.shared.performBackgroundTask { context in
                let descriptor = FetchDescriptor<IconModel>(
                    predicate: #Predicate<IconModel> { icon in
                        icon.applicationIdentifier == bundleID
                    }
                )
                let results = try context.fetch(descriptor)
                return results.first?.url
            }
        } catch {
            NSLog("iconURL lookup failed: \(error.localizedDescription)")
            return nil
        }
    }

    func iconExists(for bundleID: String) async -> Bool {
        (await iconURL(for: bundleID)) != nil
    }

    func upsertIcon(name: String, url: String, bundleID: String) async throws {
        try await Database.shared.performBackgroundTask { context in
            let descriptor = FetchDescriptor<IconModel>(
                predicate: #Predicate<IconModel> { icon in
                    icon.applicationIdentifier == bundleID
                }
            )
            let results = try context.fetch(descriptor)
            if let existing = results.first {
                if existing.url != url {
                    existing.url = url
                    existing.updatedAt = .now
                }
            } else {
                let newIcon = IconModel(name: name, url: url, applicationIdentifier: bundleID)
                context.insert(newIcon)
            }
            try context.save()
        }
        NotificationCenter.default.post(name: DataStore.changedNotification, object: nil)
    }

    // MARK: - Reports

    func saveReport(_ report: ReportValue) async {
        do {
            try await Database.shared.performBackgroundTask { context in
                let model = ReportModel(
                    windowInfo: nil,
                    integrations: report.integrations,
                    mediaInfo: nil
                )
                // Copy fields
                model.id = report.id
                model.processName = report.processName
                model.windowTitle = report.windowTitle
                model.timeStamp = report.timeStamp
                model.artist = report.artist
                model.mediaName = report.mediaName
                model.mediaProcessName = report.mediaProcessName
                model.mediaDuration = report.mediaDuration
                model.mediaElapsedTime = report.mediaElapsedTime
                model.mediaImageData = report.mediaImageData

                context.insert(model)
                try context.save()
            }
        } catch {
            NSLog("Failed to save report: \(error.localizedDescription)")
            return
        }
        NotificationCenter.default.post(name: DataStore.changedNotification, object: nil)
    }

    // Fetch all icons sorted (value type only)
    enum IconSortKey { case name, applicationIdentifier, url }
    func fetchIconsSorted(by key: IconSortKey, ascending: Bool) async -> [IconValue] {
        do {
            return try await Database.shared.performBackgroundTask { context in
                let sort: [SortDescriptor<IconModel>]
                switch key {
                case .name:
                    sort = [SortDescriptor(\.name, order: ascending ? .forward : .reverse)]
                case .applicationIdentifier:
                    sort = [SortDescriptor(\.applicationIdentifier, order: ascending ? .forward : .reverse)]
                case .url:
                    sort = [SortDescriptor(\.url, order: ascending ? .forward : .reverse)]
                }
                let descriptor = FetchDescriptor<IconModel>(sortBy: sort)
                let models = try context.fetch(descriptor)
                return models.map { IconValue(name: $0.name, applicationIdentifier: $0.applicationIdentifier, url: $0.url, createdAt: $0.createdAt, updatedAt: $0.updatedAt) }
            }
        } catch {
            NSLog("fetchIconsSorted failed: \(error.localizedDescription)")
            return []
        }
    }

    func deleteIcon(applicationIdentifier: String) async throws {
        try await Database.shared.performBackgroundTask { context in
            let descriptor = FetchDescriptor<IconModel>(
                predicate: #Predicate<IconModel> { icon in
                    icon.applicationIdentifier == applicationIdentifier
                }
            )
            let results = try context.fetch(descriptor)
            for obj in results {
                context.delete(obj)
            }
            try context.save()
        }
        NotificationCenter.default.post(name: DataStore.changedNotification, object: nil)
    }

    // Reports fetching with pagination and optional search
    func fetchReports(searchText: String? = nil, offset: Int, limit: Int, ascending: Bool) async -> [ReportValue] {
        do {
            return try await Database.shared.performBackgroundTask { context in
                let sort = [SortDescriptor<ReportModel>(\.timeStamp, order: ascending ? .forward : .reverse)]
                if let q = searchText, !q.isEmpty {
                    // Fetch all, filter in memory, then paginate (keeps simplicity and avoids predicate portability issues)
                    let all = try context.fetch(FetchDescriptor<ReportModel>(sortBy: sort))
                    let lowercased = q.lowercased()
                    let filtered = all.filter { m in
                        if let pn = m.processName?.lowercased(), pn.contains(lowercased) { return true }
                        if let mn = m.mediaName?.lowercased(), mn.contains(lowercased) { return true }
                        if let ar = m.artist?.lowercased(), ar.contains(lowercased) { return true }
                        return false
                    }
                    let slice = filtered.dropFirst(offset).prefix(limit)
                    return slice.map { m in
                        ReportValue(
                            id: m.id,
                            processName: m.processName,
                            windowTitle: m.windowTitle,
                            timeStamp: m.timeStamp,
                            artist: m.artist,
                            mediaName: m.mediaName,
                            mediaProcessName: m.mediaProcessName,
                            mediaDuration: m.mediaDuration,
                            mediaElapsedTime: m.mediaElapsedTime,
                            mediaImageData: m.mediaImageData,
                            integrations: m.integrations
                        )
                    }
                } else {
                    var descriptor = FetchDescriptor<ReportModel>(sortBy: sort)
                    descriptor.fetchOffset = offset
                    descriptor.fetchLimit = limit
                    let page = try context.fetch(descriptor)
                    return page.map { m in
                        ReportValue(
                            id: m.id,
                            processName: m.processName,
                            windowTitle: m.windowTitle,
                            timeStamp: m.timeStamp,
                            artist: m.artist,
                            mediaName: m.mediaName,
                            mediaProcessName: m.mediaProcessName,
                            mediaDuration: m.mediaDuration,
                            mediaElapsedTime: m.mediaElapsedTime,
                            mediaImageData: m.mediaImageData,
                            integrations: m.integrations
                        )
                    }
                }
            }
        } catch {
            NSLog("fetchReports failed: \(error.localizedDescription)")
            return []
        }
    }

    func deleteAllReports() async throws {
        try await Database.shared.performBackgroundTask { context in
            try context.delete(model: ReportModel.self)
            try context.save()
        }
        NotificationCenter.default.post(name: DataStore.changedNotification, object: nil)
    }

    // MARK: - Maintenance

    func flush() async {
        await MainActor.run {
            Task { @MainActor in
                if let context = await Database.shared.mainContext {
                    try? context.save()
                }
            }
        }
    }
}

extension DataStore {
    static let changedNotification = Notification.Name("DataStoreChangedNotification")
}
