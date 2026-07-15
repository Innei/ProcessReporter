//
//  Reporter+Types.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/11.
//

import Foundation

extension Reporter {
    enum Types: String, CaseIterable {
        case process
        case media
    }
}

@MainActor
protocol ReporterExtension {
    var name: String { get }
    var isEnabled: Bool { get }
    func register(to reporter: Reporter)
    func unregister(from reporter: Reporter)
    func clearReportedState()
    func waitForPendingCleanup(until deadline: ContinuousClock.Instant) async
    func createReporterOptions() -> ReporterOptions
}

// Default implementation
extension ReporterExtension {
    func register(to reporter: Reporter) {
        reporter.register(name: name, options: createReporterOptions())
    }
    
    func unregister(from reporter: Reporter) {
        reporter.unregister(name: name)
    }

    func clearReportedState() {}

    func waitForPendingCleanup(until deadline: ContinuousClock.Instant) async {}
}
