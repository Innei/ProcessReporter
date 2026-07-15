import AppKit
import Foundation

enum SyncHistoryDestinationFilter: String, CaseIterable, Identifiable {
    case all
    case mixSpace = "mixspace"
    case slack
    case discord

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All Destinations"
        case .mixSpace:
            return "MixSpace"
        case .slack:
            return "Slack"
        case .discord:
            return "Discord"
        }
    }
}

enum SyncHistoryResultFilter: String, CaseIterable, Identifiable {
    case all
    case succeeded
    case partial
    case failed
    case skipped
    case legacy
    case unreadable

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All Results"
        default:
            return rawValue.capitalized
        }
    }

    var aggregateResult: SyncAggregateResult? {
        guard self != .all else { return nil }
        return SyncAggregateResult(rawValue: rawValue)
    }
}

@MainActor
final class SyncHistoryStore: ObservableObject {
    @Published private(set) var events: [SyncEventValue] = []
    @Published private(set) var totalCount = 0
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private var loadGeneration = 0

    func load(
        searchText: String,
        destination: SyncHistoryDestinationFilter,
        result: SyncHistoryResultFilter
    ) async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        errorMessage = nil

        do {
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            async let fetchedEvents = DataStore.shared.fetchSyncEvents(
                searchText: query.isEmpty ? nil : query
            )
            async let fetchedCount = DataStore.shared.reportCount()
            let (fetched, totalCount) = try await (fetchedEvents, fetchedCount)
            try Task.checkCancellation()
            guard generation == loadGeneration else { return }

            self.totalCount = totalCount
            events = fetched.filter { event in
                let destinationMatches = destination == .all
                    || event.deliveryResults.contains {
                        $0.destinationID == destination.rawValue
                    }
                let resultMatches = result.aggregateResult == nil
                    || event.aggregateResult == result.aggregateResult
                return destinationMatches && resultMatches
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
            events = []
            totalCount = 0
            errorMessage = "Sync History could not be loaded."
            NSLog("Sync History load failed: \(error.localizedDescription)")
        }

        if generation == loadGeneration {
            isLoading = false
        }
    }

    func clearHistory() async {
        do {
            try await DataStore.shared.deleteAllReports()
            events = []
            totalCount = 0
            errorMessage = nil
        } catch {
            errorMessage = "Sync History could not be cleared."
            NSLog("Sync History clear failed: \(error.localizedDescription)")
        }
    }

    func copyEventAsJSON(_ event: SyncEventValue) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        do {
            let data = try encoder.encode(event)
            guard let value = String(data: data, encoding: .utf8) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        } catch {
            errorMessage = "This Sync Event could not be copied."
            NSLog("Sync Event JSON encoding failed: \(error.localizedDescription)")
        }
    }
}
