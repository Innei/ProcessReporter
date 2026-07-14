//
//  Database.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/10.
//
import Foundation
import SwiftData

actor Database {
    static let shared = Database()
    private var modelContainer: ModelContainer?

    // Main context for UI operations
    @MainActor
    var mainContext: ModelContext? {
        get async {
            guard let container = await modelContainer else { return nil }
            return container.mainContext
        }
    }

    // Background context for non-UI operations
    func createBackgroundContext() throws -> ModelContext {
        guard let container = modelContainer else {
            throw DatabaseError.contextUnavailable
        }
        return ModelContext(container)
    }

    func initialize() async throws {
        // Ensure we don't initialize multiple times
        guard modelContainer == nil else { return }

        // Set up default location in Application Support directory
        let fileManager = FileManager.default
        guard
            let appSupportURL = fileManager.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first,
            let bundleID = Bundle.main.bundleIdentifier
        else {
            throw DatabaseError.invalidConfiguration
        }

        let directoryURL = appSupportURL.appendingPathComponent(bundleID)
        let fileURL = directoryURL.appendingPathComponent("db.store")

        debugPrint("Database location: \(fileURL)")

        // Create schema
        let schema = Schema([ReportModel.self, IconModel.self])

        // Create directory if needed
        try fileManager.createDirectory(
            at: directoryURL, withIntermediateDirectories: true, attributes: nil)

        // Create ModelConfiguration
        let configuration = ModelConfiguration(bundleID, schema: schema, url: fileURL)

        // Create ModelContainer with migration plan
        do {
            modelContainer = try ModelContainer(
                for: schema,
                migrationPlan: MigrationPlan.self,
                configurations: configuration
            )
            print("Database initialized successfully with migration plan")
        } catch {
            // Container creation can fail for permissions, disk space, temporary
            // I/O, or an incompatible schema. None of those justify silently
            // deleting the user's activity history. Preserve the store and let
            // the caller present a recoverable error.
            throw DatabaseError.initializationFailed(error.localizedDescription)
        }
    }

    // Convenience method for performing background operations
    func performBackgroundTask<T>(_ operation: (ModelContext) throws -> T) async throws
        -> T
    {
        guard let container = modelContainer else {
            throw DatabaseError.contextUnavailable
        }

        // Database is an actor, so synchronous context operations here are
        // serialized off the main actor. This also prevents fetch-then-insert
        // races between independent SwiftData contexts.
        let context = ModelContext(container)
        return try operation(context)
    }

    func saveMainContext() async throws {
        guard let container = modelContainer else {
            throw DatabaseError.contextUnavailable
        }
        try await MainActor.run {
            try container.mainContext.save()
        }
    }

    // Batch insert with transaction support
    func batchInsert<T: PersistentModel>(_ models: [T]) async throws {
        try await performBackgroundTask { context in
            for model in models {
                context.insert(model)
            }
            try context.save()
        }
    }

    // Fetch with background context
    func fetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) async throws -> [T] {
        try await performBackgroundTask { context in
            try context.fetch(descriptor)
        }
    }

    // Cleanup resources
    func cleanup() async {
        modelContainer = nil
    }
}

// Database errors
enum DatabaseError: LocalizedError {
    case invalidConfiguration
    case contextUnavailable
    case initializationFailed(String)
    case migrationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Invalid database configuration"
        case .contextUnavailable:
            return "Database context is not available"
        case .initializationFailed(let reason):
            return "Database initialization failed; the existing store was preserved: \(reason)"
        case .migrationFailed(let reason):
            return "Migration failed: \(reason)"
        }
    }
}

// Simplified migration plan
enum MigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [CurrentSchema.self]
    }

    static var stages: [MigrationStage] {
        // No migration stages for now - start fresh
        []
    }
}

// Current schema for clean start
enum CurrentSchema: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [ReportModel.self, IconModel.self]
    }
}

// Backwards compatibility extension
extension Database {
    @MainActor
    var ctx: ModelContext? {
        get async {
            await mainContext
        }
    }
}
