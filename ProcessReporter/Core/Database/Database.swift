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
            await modelContainer?.mainContext
        }
    }
    
    // Background context for non-UI operations
    func createBackgroundContext() -> ModelContext? {
        guard let container = modelContainer else { return nil }
        return ModelContext(container)
    }
    
    func initialize() async throws {
        // Set up default location in Application Support directory
        let fileManager = FileManager.default
        guard let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let bundleID = Bundle.main.bundleIdentifier else {
            throw DatabaseError.invalidConfiguration
        }
        
        let directoryURL = appSupportURL.appendingPathComponent(bundleID)
        let fileURL = directoryURL.appendingPathComponent("db.store")
        
        debugPrint("Database location: \(fileURL)")
        
        // Create schema
        let schema = Schema([ReportModel.self, IconModel.self])
        
        // Create directory if needed
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        
        // Create ModelConfiguration
        let configuration = ModelConfiguration(bundleID, schema: schema, url: fileURL)
        
        // Create ModelContainer with migration plan
        do {
            modelContainer = try ModelContainer(
                for: schema,
                migrationPlan: MigrationPlan.self,
                configurations: configuration
            )
        } catch {
            // If migration fails, remove the old database and create a new one
            print("Migration failed with error: \(error)")
            print("Removing old database and creating new one...")
            
            try? fileManager.removeItem(at: fileURL)
            
            // Try again without migration plan for a fresh start
            modelContainer = try ModelContainer(
                for: schema,
                configurations: configuration
            )
        }
    }
    
    // Convenience method for performing background operations
    func performBackgroundTask<T>(_ operation: @escaping (ModelContext) throws -> T) async throws -> T {
        guard let context = createBackgroundContext() else {
            throw DatabaseError.contextUnavailable
        }
        
        return try await Task {
            try operation(context)
        }.value
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
}

// Database errors
enum DatabaseError: LocalizedError {
    case invalidConfiguration
    case contextUnavailable
    case migrationFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Invalid database configuration"
        case .contextUnavailable:
            return "Database context is not available"
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
    static var versionIdentifier = Schema.Version(1, 0, 0)
    
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