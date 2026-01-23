//
//  DiscordDebugStore.swift
//  ProcessReporter
//
//  Created by Codex on 2026/1/23.
//

import Foundation

struct DiscordDebugSnapshot {
    var lastUpdate: Date?
    var lastOutcome: String = "No activity yet"
    var lastReason: String? = nil
    var lastReportSummary: String? = nil
    var lastPresenceSummary: String? = nil
    var clientKind: String = "unknown"
    var isConnected: Bool = false
}

final class DiscordDebugStore {
    static let shared = DiscordDebugStore()

    private let queue = DispatchQueue(label: "processreporter.discord.debug.store")
    private var snapshot = DiscordDebugSnapshot()

    func update(_ mutate: (inout DiscordDebugSnapshot) -> Void) {
        queue.sync {
            mutate(&snapshot)
            snapshot.lastUpdate = Date()
        }
        NotificationCenter.default.post(name: .discordDebugInfoDidChange, object: nil)
    }

    func read() -> DiscordDebugSnapshot {
        queue.sync { snapshot }
    }

    func formattedText() -> String {
        let snap = read()
        var lines: [String] = []
        lines.append("Client: \(snap.clientKind)")
        lines.append("Connected: \(snap.isConnected ? "yes" : "no")")
        if let lastUpdate = snap.lastUpdate {
            lines.append("Last Update: \(Self.formatDate(lastUpdate))")
        }
        lines.append("Outcome: \(snap.lastOutcome)")
        if let reason = snap.lastReason, !reason.isEmpty {
            lines.append("Reason: \(reason)")
        }
        if let report = snap.lastReportSummary, !report.isEmpty {
            lines.append("")
            lines.append("Report:")
            lines.append(report)
        }
        if let presence = snap.lastPresenceSummary, !presence.isEmpty {
            lines.append("")
            lines.append("Presence:")
            lines.append(presence)
        }
        return lines.joined(separator: "\n")
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

extension Notification.Name {
    static let discordDebugInfoDidChange = Notification.Name("discordDebugInfoDidChange")
}
