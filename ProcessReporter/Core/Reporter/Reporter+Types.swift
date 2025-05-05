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

protocol ReporterExtension {
    var name: String { get }
    var isEnabled: Bool { get }
    func register(to reporter: Reporter) async
    func unregister(from reporter: Reporter) async
    func createReporterOptions() -> ReporterOptions
}

// Default implementation
extension ReporterExtension {
    func register(to reporter: Reporter) async {
        await reporter.register(name: name, options: createReporterOptions())
    }
    
    func unregister(from reporter: Reporter) async {
        await reporter.unregister(name: name)
    }
}


