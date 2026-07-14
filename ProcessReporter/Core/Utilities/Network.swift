//
//  Network.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/12.
//

import Foundation
import Network

private final class NetworkAvailabilityMonitor: @unchecked Sendable {
    static let shared = NetworkAvailabilityMonitor()

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "processreporter.network-path")
    private let lock = NSLock()
    private var status: NWPath.Status?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.status = path.status
            self.lock.unlock()
        }
        monitor.start(queue: monitorQueue)
    }

    deinit {
        monitor.cancel()
    }

    var isAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }

        // NWPathMonitor publishes asynchronously. Until the first path is known,
        // allow the real request to decide instead of dropping startup reports.
        // A path requiring a connection may also become usable on demand.
        return status != .unsatisfied
    }
}

func isNetworkAvailable() -> Bool {
    NetworkAvailabilityMonitor.shared.isAvailable
}
