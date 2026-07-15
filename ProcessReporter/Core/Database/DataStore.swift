//
//  DataStore.swift
//  ProcessReporter
//
//  Created by Innei on 2025/8/26.
//

@preconcurrency import Foundation
@preconcurrency import SwiftData

// Value object used to persist reports without exposing SwiftData models
struct ReportValue: Sendable {
    var id: UUID
    var processName: String?
    var windowTitle: String?
    var timeStamp: Date

    var artist: String?
    var mediaName: String?
    var mediaProcessName: String?
    var mediaDuration: Double?
    var mediaElapsedTime: Double?
    var integrations: [String]
}

struct IconValue: Sendable {
    var name: String
    var applicationIdentifier: String
    var url: String
    var createdAt: Date
    var updatedAt: Date
}

// Centralized store that is the only place allowed to touch SwiftData
actor DataStore {
    static let shared = DataStore()

    // Maximum number of reports to keep.
    private let maxReportCount = 5000

    // Initialize underlying database/container
    func initialize() async throws {
        try await Database.shared.initialize()
    }

    // MARK: - Icons

    func iconURL(for bundleID: String) async -> String? {
        do {
            return try await Database.shared.performBackgroundTask { context in
                let models = try context.fetch(FetchDescriptor<IconModel>())
                return models.first { $0.applicationIdentifier == bundleID }?.url
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
        let didChange = try await Database.shared.performBackgroundTask { context in
            let models = try context.fetch(FetchDescriptor<IconModel>())
            if let existing = models.first(where: { $0.applicationIdentifier == bundleID }) {
                guard existing.url != url || existing.name != name else { return false }
                existing.url = url
                existing.name = name
                existing.updatedAt = .now
            } else {
                let newIcon = IconModel(name: name, url: url, applicationIdentifier: bundleID)
                context.insert(newIcon)
            }
            try context.save()
            return true
        }
        guard didChange else { return }
        NotificationCenter.default.post(name: DataStore.changedNotification, object: nil)
    }

    // MARK: - Reports

    func saveReport(_ report: ReportValue) async throws {
        try await Database.shared.performBackgroundTask { context in
            let model = ReportModel(
                windowInfo: nil,
                integrations: report.integrations,
                mediaInfo: nil
            )
            model.id = report.id
            model.processName = report.processName
            model.windowTitle = report.windowTitle
            model.timeStamp = report.timeStamp
            model.artist = report.artist
            model.mediaName = report.mediaName
            model.mediaProcessName = report.mediaProcessName
            model.mediaDuration = report.mediaDuration
            model.mediaElapsedTime = report.mediaElapsedTime

            context.insert(model)
            try context.save()
        }
        NotificationCenter.default.post(name: DataStore.changedNotification, object: nil)

        // Check and cleanup if database is too large
        await cleanupOldRecordsIfNeeded()
    }

    // Fetch all icons sorted (value type only)
    enum IconSortKey: Sendable { case name, applicationIdentifier, url }
    func fetchIconsSorted(by key: IconSortKey, ascending: Bool) async -> [IconValue] {
        do {
            return try await Database.shared.performBackgroundTask { context in
                let models = try context.fetch(FetchDescriptor<IconModel>())
                let values = models.map {
                    IconValue(
                        name: $0.name,
                        applicationIdentifier: $0.applicationIdentifier,
                        url: $0.url,
                        createdAt: $0.createdAt,
                        updatedAt: $0.updatedAt
                    )
                }
                return values.sorted { lhs, rhs in
                    let comparison: ComparisonResult
                    switch key {
                    case .name:
                        comparison = lhs.name.compare(rhs.name)
                    case .applicationIdentifier:
                        comparison = lhs.applicationIdentifier.compare(rhs.applicationIdentifier)
                    case .url:
                        comparison = lhs.url.compare(rhs.url)
                    }
                    if comparison == .orderedSame {
                        return ascending
                            ? lhs.applicationIdentifier < rhs.applicationIdentifier
                            : lhs.applicationIdentifier > rhs.applicationIdentifier
                    }
                    return ascending
                        ? comparison == .orderedAscending
                        : comparison == .orderedDescending
                }
            }
        } catch {
            NSLog("fetchIconsSorted failed: \(error.localizedDescription)")
            return []
        }
    }

    func deleteIcon(applicationIdentifier: String) async throws {
        try await Database.shared.performBackgroundTask { context in
            let models = try context.fetch(FetchDescriptor<IconModel>())
            for obj in models where obj.applicationIdentifier == applicationIdentifier {
                context.delete(obj)
            }
            try context.save()
        }
        NotificationCenter.default.post(name: DataStore.changedNotification, object: nil)
    }

    // Reports fetching with pagination and optional search
    func fetchReports(
        searchText: String? = nil,
        offset: Int,
        limit: Int,
        ascending: Bool
    ) async -> [ReportValue] {
        guard limit > 0 else { return [] }

        do {
            try Task.checkCancellation()
            return try await Database.shared.fetchReportValues(
                searchText: searchText,
                offset: offset,
                limit: limit,
                ascending: ascending
            )
        } catch is CancellationError {
            return []
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
        do {
            try await Database.shared.saveMainContext()
        } catch {
            NSLog("Failed to flush database: \(error.localizedDescription)")
        }
    }

    // MARK: - Database Size Management

    func cleanupOldRecordsIfNeeded() async {
        do {
            let deletedCount = try await Database.shared.trimReports(
                toMaximumCount: maxReportCount
            )

            if deletedCount > 0 {
                NSLog("Cleaned up \(deletedCount) old reports")
                NotificationCenter.default.post(name: DataStore.changedNotification, object: nil)
            }
        } catch {
            NSLog("Failed to cleanup old reports: \(error.localizedDescription)")
        }
    }

    func getReportCount() async -> Int {
        do {
            return try await Database.shared.performBackgroundTask { context in
                let descriptor = FetchDescriptor<ReportModel>()
                return try context.fetchCount(descriptor)
            }
        } catch {
            NSLog("getReportCount failed: \(error.localizedDescription)")
            return 0
        }
    }
}

extension DataStore {
    static let changedNotification = Notification.Name("DataStoreChangedNotification")

    fileprivate static func reportHistoryProperties() -> [PartialKeyPath<ReportModel>] {
        [
            \.id,
            \.processName,
            \.windowTitle,
            \.timeStamp,
            \.artist,
            \.mediaName,
            \.mediaProcessName,
            \.mediaDuration,
            \.mediaElapsedTime,
            \.integrationsData,
        ]
    }

    fileprivate static func reportValue(_ model: ReportModel) -> ReportValue {
        ReportValue(
            id: model.id,
            processName: model.processName,
            windowTitle: model.windowTitle,
            timeStamp: model.timeStamp,
            artist: model.artist,
            mediaName: model.mediaName,
            mediaProcessName: model.mediaProcessName,
            mediaDuration: model.mediaDuration,
            mediaElapsedTime: model.mediaElapsedTime,
            integrations: model.integrations
        )
    }
}

extension Database {
    func fetchReportValues(
        searchText: String?,
        offset: Int,
        limit: Int,
        ascending: Bool
    ) throws -> [ReportValue] {
        try Task.checkCancellation()
        let context = try createBackgroundContext()
        let order: SortOrder = ascending ? .forward : .reverse
        let sort = [
            SortDescriptor<ReportModel>(\.timeStamp, order: order),
            SortDescriptor<ReportModel>(\.id, order: order),
        ]
        var descriptor = FetchDescriptor<ReportModel>(sortBy: sort)
        descriptor.propertiesToFetch = DataStore.reportHistoryProperties()

        let safeOffset = max(0, offset)
        let safeLimit = max(0, limit)
        guard let query = searchText, !query.isEmpty else {
            // The common history path must remain database-paginated. Fetching
            // and sorting all 5,000 rows for every page delays report writes on
            // the same actor and makes infinite scrolling progressively slower.
            descriptor.fetchOffset = safeOffset
            descriptor.fetchLimit = safeLimit
            let page = try context.fetch(descriptor)
            try Task.checkCancellation()
            return page.map(DataStore.reportValue)
        }

        // SwiftData does not provide a portable case-insensitive contains
        // predicate for these optional fields. Search the bounded history in
        // memory, but stop promptly when a newer query cancels this task.
        let models = try context.fetch(descriptor)
        try Task.checkCancellation()
        let lowercasedQuery = query.lowercased()
        var skippedMatches = 0
        var results: [ReportValue] = []
        results.reserveCapacity(min(safeLimit, models.count))

        for (index, model) in models.enumerated() {
            if index.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            let matches = model.processName?.lowercased().contains(lowercasedQuery) == true
                || model.mediaName?.lowercased().contains(lowercasedQuery) == true
                || model.artist?.lowercased().contains(lowercasedQuery) == true
            guard matches else { continue }
            if skippedMatches < safeOffset {
                skippedMatches += 1
                continue
            }
            results.append(DataStore.reportValue(model))
            if results.count == safeLimit { break }
        }
        return results
    }

    func trimReports(toMaximumCount maximumCount: Int) throws -> Int {
        let context = try createBackgroundContext()
        let totalCount = try context.fetchCount(FetchDescriptor<ReportModel>())
        guard totalCount > maximumCount else { return 0 }

        let deleteCount = totalCount - maximumCount
        // Delete exactly the excess rows. A timestamp predicate could remove
        // more than requested when multiple reports share the same timestamp.
        var descriptor = FetchDescriptor<ReportModel>(sortBy: [
            SortDescriptor(\.timeStamp, order: .forward),
            SortDescriptor(\.id, order: .forward),
        ])
        descriptor.propertiesToFetch = [\.id, \.timeStamp]
        descriptor.fetchLimit = deleteCount
        let oldestReports = try context.fetch(descriptor)
        for report in oldestReports {
            context.delete(report)
        }
        try context.save()
        return oldestReports.count
    }
}
