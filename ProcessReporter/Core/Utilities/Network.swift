//
//  Network.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/12.
//

import Foundation
import Network

extension Notification.Name {
    /// Posted on the main queue whenever `NWPathMonitor` observes a transition
    /// between an available and unavailable network path.
    ///
    /// The notification object is always `nil`. The `userInfo` dictionary
    /// contains an `isAvailable` Boolean value.
    static let processReporterNetworkAvailabilityDidChange = Notification.Name(
        "ProcessReporterNetworkAvailabilityDidChange"
    )
}

enum NetworkAvailabilityNotificationKey {
    static let isAvailable = "isAvailable"
}

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
            let previousStatus = self.status
            self.status = path.status
            self.lock.unlock()

            let isAvailable = path.status != .unsatisfied
            let wasAvailable = previousStatus.map { $0 != .unsatisfied }
            // The first callback is itself a meaningful transition from
            // "unknown". Reporter treats unknown as unavailable so an initial
            // satisfied callback must wake the deferred fresh capture.
            guard wasAvailable == nil || wasAvailable != isAvailable else { return }
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .processReporterNetworkAvailabilityDidChange,
                    object: nil,
                    userInfo: [NetworkAvailabilityNotificationKey.isAvailable: isAvailable]
                )
            }
        }
        monitor.start(queue: monitorQueue)
    }

    deinit {
        monitor.cancel()
    }

    var isAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }

        // Fail closed until NWPathMonitor publishes its first path. The first
        // callback is always posted, so a satisfied path immediately schedules a
        // fresh capture instead of allowing a speculative startup delivery.
        return status.map { $0 != .unsatisfied } ?? false
    }
}

func isNetworkAvailable() -> Bool {
    NetworkAvailabilityMonitor.shared.isAvailable
}

/// Accepts only literal loopback names and addresses. Prefix matching is not
/// sufficient here because a hostname such as `127.attacker.example` is a
/// public DNS name even though it begins with the loopback network number.
func isLoopbackHost(_ host: String) -> Bool {
    let normalized = host.lowercased()
    if normalized == "localhost" || normalized == "[::1]" || normalized == "::1" {
        return true
    }

    let octets = normalized.split(separator: ".", omittingEmptySubsequences: false)
    guard octets.count == 4, octets.first == "127" else { return false }
    return octets.allSatisfy { UInt8($0) != nil }
}

/// Validates a durable public HTTP URL used for hosted application assets.
/// Remote hosts require HTTPS; loopback HTTP remains available for local testing.
func validatedSecurePublicURL(_ value: String) -> URL? {
    guard let components = URLComponents(string: value),
          let scheme = components.scheme?.lowercased(),
          let host = components.host,
          components.user == nil,
          components.password == nil,
          components.query == nil,
          components.fragment == nil,
          scheme == "https" || (scheme == "http" && isLoopbackHost(host))
    else { return nil }
    return components.url
}
