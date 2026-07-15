import SwiftUI

struct SyncHistoryView: View {
    private struct Query: Hashable {
        let searchText: String
        let destination: SyncHistoryDestinationFilter
        let result: SyncHistoryResultFilter
    }

    @StateObject private var store = SyncHistoryStore()
    @State private var searchText = ""
    @State private var destinationFilter = SyncHistoryDestinationFilter.all
    @State private var resultFilter = SyncHistoryResultFilter.all
    @State private var selectedEventID: UUID?
    @State private var compactInspectorEvent: SyncEventValue?
    @State private var isConfirmingClear = false

    private var query: Query {
        Query(
            searchText: searchText,
            destination: destinationFilter,
            result: resultFilter
        )
    }

    private var selectedEvent: SyncEventValue? {
        guard let selectedEventID else { return nil }
        return store.events.first { $0.id == selectedEventID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if store.isLoading, store.events.isEmpty {
                ProgressView("Loading Sync History…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = store.errorMessage, store.events.isEmpty {
                ContentUnavailableView(
                    "Sync History Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.events.isEmpty {
                ContentUnavailableView(
                    "No Sync Events",
                    systemImage: "clock.arrow.circlepath",
                    description: Text(emptyDescription)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    if geometry.size.width < 680 {
                        compactEventList
                    } else {
                        HSplitView {
                            eventList
                                .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)

                            if let selectedEvent {
                                SyncEventInspector(
                                    event: selectedEvent,
                                    copyAction: { store.copyEventAsJSON(selectedEvent) }
                                )
                                .frame(minWidth: 320)
                            } else {
                                ContentUnavailableView(
                                    "Select a Sync Event",
                                    systemImage: "sidebar.right",
                                    description: Text(
                                        "Inspect the sanitized Presence and delivery results."
                                    )
                                )
                                .frame(
                                    minWidth: 320,
                                    maxWidth: .infinity,
                                    maxHeight: .infinity
                                )
                            }
                        }
                    }
                }
            }
        }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            await store.load(
                searchText: searchText,
                destination: destinationFilter,
                result: resultFilter
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: DataStore.changedNotification)) { _ in
            Task {
                await store.load(
                    searchText: searchText,
                    destination: destinationFilter,
                    result: resultFilter
                )
            }
        }
        .onChange(of: store.events.map(\.id)) { _, eventIDs in
            if let selectedEventID, eventIDs.contains(selectedEventID) {
                return
            }
            selectedEventID = eventIDs.first
        }
        .alert("Clear Sync History?", isPresented: $isConfirmingClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear History", role: .destructive) {
                compactInspectorEvent = nil
                selectedEventID = nil
                Task { await store.clearHistory() }
            }
        } message: {
            Text("This permanently removes all local Sync Events. Destination settings are preserved.")
        }
        .sheet(item: $compactInspectorEvent) { event in
            VStack(spacing: 0) {
                HStack {
                    Text("Sync Event")
                        .font(.headline)
                    Spacer()
                    Button("Done") { compactInspectorEvent = nil }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                Divider()
                SyncEventInspector(
                    event: event,
                    copyAction: { store.copyEventAsJSON(event) }
                )
            }
            .frame(minWidth: 500, minHeight: 600)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    headerTitle
                    Spacer()
                    clearHistoryButton
                }
                VStack(alignment: .leading, spacing: 10) {
                    headerTitle
                    clearHistoryButton
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    searchField
                        .frame(minWidth: 160)
                    destinationPicker
                        .frame(width: 145)
                    resultPicker
                        .frame(width: 112)
                }
                VStack(alignment: .leading, spacing: 10) {
                    searchField
                    HStack(spacing: 10) {
                        destinationPicker
                            .frame(width: 145)
                        resultPicker
                            .frame(width: 112)
                    }
                }
            }

            if let errorMessage = store.errorMessage, !store.events.isEmpty {
                SettingsInlineNotice(message: errorMessage)
            }
        }
        .padding(24)
    }

    private var headerTitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sync History")
                .font(.title2.weight(.semibold))
            Text("A local audit of sanitized Presence deliveries.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var clearHistoryButton: some View {
        Button("Clear Sync History…", role: .destructive) {
            isConfirmingClear = true
        }
        .disabled(store.totalCount == 0)
    }

    private var searchField: some View {
        TextField("Search applications or media", text: $searchText)
            .textFieldStyle(.roundedBorder)
    }

    private var destinationPicker: some View {
        Picker("Destination", selection: $destinationFilter) {
            ForEach(SyncHistoryDestinationFilter.allCases) { filter in
                Text(filter.title).tag(filter)
            }
        }
        .labelsHidden()
    }

    private var resultPicker: some View {
        Picker("Result", selection: $resultFilter) {
            ForEach(SyncHistoryResultFilter.allCases) { filter in
                Text(filter.title).tag(filter)
            }
        }
        .labelsHidden()
    }

    private var eventList: some View {
        List(store.events, selection: $selectedEventID) { event in
            SyncEventRow(event: event)
                .tag(event.id)
        }
        .listStyle(.inset)
    }

    private var compactEventList: some View {
        List(store.events) { event in
            Button {
                compactInspectorEvent = event
            } label: {
                SyncEventRow(event: event)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Open Sync Event details.")
        }
        .listStyle(.inset)
    }

    private var emptyDescription: String {
        if !searchText.isEmpty || destinationFilter != .all || resultFilter != .all {
            return "No events match the current search and filters."
        }
        return "Sanitized delivery records will appear after Presence is synchronized."
    }
}

private struct SyncEventRow: View {
    let event: SyncEventValue

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(primarySummary)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Label(event.aggregateResult.displayName, systemImage: resultSymbol)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(resultColor)
                    .labelStyle(.titleAndIcon)
            }

            HStack(spacing: 8) {
                Text(event.capturedAt, format: .dateTime.month().day().hour().minute().second())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 4) {
                    ForEach(event.deliveryResults) { result in
                        Image(systemName: destinationSymbol(result.destinationID))
                            .foregroundStyle(deliveryColor(result.status))
                            .help("\(result.displayName): \(result.status.displayName)")
                            .accessibilityLabel(
                                "\(result.displayName), \(result.status.displayName)"
                            )
                    }
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    private var primarySummary: String {
        event.snapshot.mediaTitle
            ?? event.snapshot.applicationDisplayName
            ?? "Presence Update"
    }

    private var resultSymbol: String {
        switch event.aggregateResult {
        case .succeeded: return "checkmark.circle.fill"
        case .partial: return "exclamationmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .skipped: return "minus.circle.fill"
        case .legacy: return "clock.badge.questionmark"
        case .unreadable: return "questionmark.diamond.fill"
        }
    }

    private var resultColor: Color {
        switch event.aggregateResult {
        case .succeeded: return .green
        case .partial: return .orange
        case .failed, .unreadable: return .red
        case .skipped, .legacy: return .secondary
        }
    }
}

private struct SyncEventInspector: View {
    let event: SyncEventValue
    let copyAction: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.aggregateResult.displayName)
                            .font(.title3.weight(.semibold))
                        Text(event.capturedAt, format: .dateTime.year().month().day().hour().minute().second())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Copy Event as JSON", action: copyAction)
                }

                if event.kind == .unreadable {
                    SettingsInlineNotice(
                        message: "This record exists, but its audit metadata cannot be read. Its sanitized Presence fields remain available."
                    )
                }

                InspectorSection("Presence") {
                    InspectorValueRow("Application", value: event.snapshot.applicationDisplayName)
                    InspectorValueRow("Window Title", value: event.snapshot.windowTitle)
                    InspectorValueRow("Media", value: event.snapshot.mediaTitle)
                    InspectorValueRow("Artist", value: event.snapshot.mediaArtist)
                    InspectorValueRow("Media Application", value: event.snapshot.mediaApplicationName)
                }

                InspectorSection("Destinations") {
                    if event.deliveryResults.isEmpty {
                        Text("No destination audit metadata is available.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(12)
                    } else {
                        ForEach(Array(event.deliveryResults.enumerated()), id: \.element.id) {
                            index, result in
                            SyncDeliveryResultView(result: result)
                            if index < event.deliveryResults.count - 1 {
                                Divider().padding(.leading, 12)
                            }
                        }
                    }
                }

                if let assetResult = event.assetResult {
                    InspectorSection("Application Icon") {
                        InspectorValueRow("Result", value: assetResult.status.displayName)
                        if assetResult.usedFallback {
                            InspectorValueRow("Fallback", value: "Used cached public URL")
                        }
                        InspectorValueRow("Message", value: assetResult.message)
                    }
                }

                InspectorSection("Metadata") {
                    InspectorValueRow("Event ID", value: event.id.uuidString)
                    InspectorValueRow("Trigger", value: event.trigger.displayName)
                    InspectorValueRow("Format", value: event.kind.rawValue.capitalized)
                }
            }
            .padding(24)
            .frame(maxWidth: 620, alignment: .leading)
        }
    }
}

private struct SyncDeliveryResultView: View {
    let result: SyncDeliveryResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(result.displayName, systemImage: destinationSymbol(result.destinationID))
                    .font(.headline)
                Spacer()
                Text(result.status.displayName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(deliveryColor(result.status))
            }

            if let duration = result.durationMilliseconds {
                InspectorValueRow("Duration", value: formatDuration(duration))
            }
            if let output = result.outputSummary {
                InspectorValueRow("Output", value: output.title)
                InspectorValueRow("Secondary", value: output.subtitle)
                InspectorValueRow("Detail", value: output.detail)
                InspectorValueRow("Activity", value: output.activityKind)
            }
            InspectorValueRow("Error Code", value: result.errorCode)
            InspectorValueRow("Message", value: result.message)
        }
        .padding(12)
    }

    private func formatDuration(_ milliseconds: Int) -> String {
        if milliseconds < 1_000 { return "\(milliseconds) ms" }
        return String(format: "%.2f s", Double(milliseconds) / 1_000)
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.separator, lineWidth: 1)
            }
        }
    }
}

private struct InspectorValueRow: View {
    let label: String
    let value: String?

    init(_ label: String, value: String?) {
        self.label = label
        self.value = value
    }

    var body: some View {
        if let value, !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(label)
                    .foregroundStyle(.secondary)
                    .frame(width: 112, alignment: .leading)
                Text(value)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
    }
}

private func destinationSymbol(_ destinationID: String) -> String {
    switch PresenceDestinationID(rawValue: destinationID) {
    case .mixSpace: return "network"
    case .slack: return "number"
    case .discord: return "bubble.left.and.bubble.right"
    case nil: return "shippingbox"
    }
}

private func deliveryColor(_ status: SyncDeliveryStatus) -> Color {
    switch status {
    case .succeeded: return .green
    case .failed: return .red
    case .skipped, .unknown: return .secondary
    }
}
