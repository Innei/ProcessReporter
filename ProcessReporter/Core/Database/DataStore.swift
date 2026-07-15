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
    var decodedSyncPayload: DecodedSyncPayload
}

struct IconValue: Sendable {
    var name: String
    var applicationIdentifier: String
    var url: String
    var createdAt: Date
    var updatedAt: Date
}

/// Thread-safe ownership of the durable History suppression set.
///
/// Publication must be synchronous at the caller's generation gate: an actor
/// hop between checking the generation and removing suppression would reopen a
/// privacy-stale visibility race. The lock therefore protects only this small
/// set and its UserDefaults representation; all SwiftData access remains actor
/// isolated below.
private final class SuppressedReportRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private let defaults: UserDefaults
    private let defaultsKey: String
    private var reportIDs: Set<UUID>

    init(defaults: UserDefaults, defaultsKey: String) {
        self.defaults = defaults
        self.defaultsKey = defaultsKey
        let storedIDs = defaults.stringArray(forKey: defaultsKey) ?? []
        reportIDs = Set(storedIDs.compactMap(UUID.init(uuidString:)))
    }

    func snapshot() -> Set<UUID> {
        lock.lock()
        defer { lock.unlock() }
        return reportIDs
    }

    @discardableResult
    func insert(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wasInserted = reportIDs.insert(id).inserted
        if wasInserted {
            persistLocked()
        }
        return wasInserted
    }

    @discardableResult
    func remove(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard reportIDs.remove(id) != nil else { return false }
        persistLocked()
        return true
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        guard !reportIDs.isEmpty else { return }
        reportIDs.removeAll()
        persistLocked()
    }

    private func persistLocked() {
        defaults.set(
            reportIDs.map(\.uuidString).sorted(),
            forKey: defaultsKey
        )
    }
}

// Centralized store that is the only place allowed to touch SwiftData
actor DataStore {
    static let shared = DataStore()

    // Maximum number of reports to keep.
    private let maxReportCount = 5000
    private static let suppressedReportIDsDefaultsKey =
        "privacyStaleSyncEventIDsPendingDeletion"
    // Every new report enters this registry before its database write. History
    // remains fail-closed until Reporter explicitly publishes the staged row.
    private nonisolated let suppressedReports: SuppressedReportRegistry

    private init() {
        suppressedReports = SuppressedReportRegistry(
            defaults: .standard,
            defaultsKey: Self.suppressedReportIDsDefaultsKey
        )
    }

    // Initialize underlying database/container
    func initialize() async throws {
        try await Database.shared.initialize()
        await retrySuppressedReportDeletions()
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
        Self.postChangedNotification()
    }

    func iconCount() async throws -> Int {
        try await Database.shared.performBackgroundTask { context in
            try context.fetchCount(FetchDescriptor<IconModel>())
        }
    }

    func deleteAllIcons() async throws {
        try await Database.shared.performBackgroundTask { context in
            try context.delete(model: IconModel.self)
            try context.save()
        }
        Self.postChangedNotification()
    }

    // MARK: - Reports

    func reportCount() async throws -> Int {
        let reportIDs = try await Database.shared.performBackgroundTask { context in
            try context.fetch(FetchDescriptor<ReportModel>()).map(\.id)
        }
        // Snapshot after the database read. Any report newly visible to that read
        // must already have been staged, so it cannot escape this filter.
        let suppressedIDs = suppressedReports.snapshot()
        return reportIDs.lazy.filter { !suppressedIDs.contains($0) }.count
    }

    /// Installs the durable, fail-closed half of the History two-phase commit.
    /// This is intentionally nonisolated and synchronous so Reporter can call it
    /// before any database suspension point.
    nonisolated func stageReportForPublication(id: UUID) {
        guard suppressedReports.insert(id) else { return }
        Self.postChangedNotification()
    }

    /// Saves a report that remains invisible to every History read API.
    func saveStagedReport(_ report: ReportValue) async throws {
        // Preserve the invariant even if a future caller forgets the explicit
        // staging call. Reporter still stages synchronously before awaiting here.
        stageReportForPublication(id: report.id)
        try await Database.shared.performBackgroundTask { context in
            try Task.checkCancellation()
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

            if case .modern(let payload) = report.decodedSyncPayload {
                try model.setStoredSyncEventPayload(payload)
            }

            context.insert(model)
            try Task.checkCancellation()
            try context.save()
        }

        // Check and cleanup if database is too large
        await cleanupOldRecordsIfNeeded()
    }

    /// Completes the two-phase commit by making a staged row visible.
    ///
    /// Reporter invokes this synchronously on MainActor immediately after its
    /// generation check. No suspension can therefore occur between validation
    /// and the suppression removal that is the publication linearization point.
    nonisolated func publishStagedReport(id: UUID) {
        guard suppressedReports.remove(id) else { return }
        Self.postChangedNotification()
    }

    func deleteReport(id: UUID) async throws {
        try await Database.shared.performBackgroundTask { context in
            var descriptor = FetchDescriptor<ReportModel>(
                predicate: #Predicate { $0.id == id }
            )
            descriptor.fetchLimit = 1
            guard let model = try context.fetch(descriptor).first else { return }
            context.delete(model)
            try context.save()
        }
        suppressedReports.remove(id)
        Self.postChangedNotification()
    }

    func quarantineAndDeleteReport(id: UUID) async throws {
        // Re-staging is idempotent. If the physical delete fails, the durable
        // marker remains and initialization retries the rollback on next launch.
        stageReportForPublication(id: id)
        try await deleteReport(id: id)
    }

    // Fetch all icons sorted (value type only)
    enum IconSortKey: Sendable { case name, applicationIdentifier, url }
    func fetchIcons() async throws -> [IconValue] {
        try await Database.shared.performBackgroundTask { context in
            try context.fetch(FetchDescriptor<IconModel>()).map {
                IconValue(
                    name: $0.name,
                    applicationIdentifier: $0.applicationIdentifier,
                    url: $0.url,
                    createdAt: $0.createdAt,
                    updatedAt: $0.updatedAt
                )
            }
        }
    }

    func fetchIconsSorted(by key: IconSortKey, ascending: Bool) async -> [IconValue] {
        do {
            let values = try await fetchIcons()
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
        Self.postChangedNotification()
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
            let reports = try await Database.shared.fetchReportValues(
                searchText: searchText,
                offset: 0,
                limit: maxReportCount,
                ascending: ascending
            )
            let suppressedIDs = suppressedReports.snapshot()
            return Array(
                reports.lazy
                    .filter { !suppressedIDs.contains($0.id) }
                    .dropFirst(offset)
                    .prefix(limit)
            )
        } catch is CancellationError {
            return []
        } catch {
            NSLog("fetchReports failed: \(error.localizedDescription)")
            return []
        }
    }

    func fetchSyncEvents(searchText: String? = nil) async throws -> [SyncEventValue] {
        try Task.checkCancellation()
        let reports = try await Database.shared.fetchReportValues(
            searchText: searchText,
            offset: 0,
            limit: maxReportCount,
            ascending: false
        )
        try Task.checkCancellation()
        let suppressedIDs = suppressedReports.snapshot()
        return reports
            .filter { !suppressedIDs.contains($0.id) }
            .map(\.syncEventValue)
    }

    func deleteAllReports() async throws {
        try await Database.shared.performBackgroundTask { context in
            try context.delete(model: ReportModel.self)
            try context.save()
        }
        suppressedReports.removeAll()
        Self.postChangedNotification()
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
                Self.postChangedNotification()
            }
        } catch {
            NSLog("Failed to cleanup old reports: \(error.localizedDescription)")
        }
    }

    func getReportCount() async -> Int {
        do {
            return try await reportCount()
        } catch {
            NSLog("getReportCount failed: \(error.localizedDescription)")
            return 0
        }
    }

    private func retrySuppressedReportDeletions() async {
        for reportID in suppressedReports.snapshot().sorted(by: {
            $0.uuidString < $1.uuidString
        }) {
            do {
                try await deleteReport(id: reportID)
            } catch {
                // Keep the durable suppression marker. History remains fail-closed,
                // and the next application launch will retry the physical rollback.
                NSLog(
                    "Deferred privacy-stale Sync Event deletion failed: %@",
                    error.localizedDescription
                )
            }
        }
    }
}

extension DataStore {
    static let changedNotification = Notification.Name("DataStoreChangedNotification")

    private nonisolated static func postChangedNotification() {
        let post = {
            NotificationCenter.default.post(name: changedNotification, object: nil)
        }
        if Thread.isMainThread {
            post()
        } else {
            DispatchQueue.main.async(execute: post)
        }
    }

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
            integrations: model.integrations,
            decodedSyncPayload: model.decodedSyncPayload
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
