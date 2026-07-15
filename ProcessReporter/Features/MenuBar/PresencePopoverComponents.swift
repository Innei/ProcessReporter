import AppKit
import SwiftUI

@MainActor
struct PresenceStatusMark: View {
    let status: PresenceAggregateStatus

    var body: some View {
        Group {
            if status == .syncing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: status.symbolName)
                    .foregroundStyle(status.color)
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}

@MainActor
struct PresencePreviewView: View {
    let presence: PresencePresentation
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 10) {
                    if presence.hasApplication {
                        applicationRow
                    }
                    if presence.hasMedia {
                        mediaRow
                    }
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 11))
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presence.accessibilitySummary)
        .accessibilityHint("Open Privacy and Rules for this Presence.")
    }

    private var applicationRow: some View {
        HStack(spacing: 9) {
            if let icon = presence.applicationIcon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .presenceArtwork(size: 34, cornerRadius: 8)
                    .accessibilityHidden(true)
            } else {
                PresenceArtworkPlaceholder(symbolName: "app.fill", size: 34)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(presence.applicationName ?? "Application")
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if let windowTitle = presence.windowTitle?.nonEmpty {
                    Text(windowTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private var mediaRow: some View {
        HStack(spacing: 9) {
            if let artwork = presence.mediaArtwork {
                Image(nsImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .presenceArtwork(size: 34, cornerRadius: 7)
                    .accessibilityHidden(true)
            } else {
                PresenceArtworkPlaceholder(symbolName: "music.note", size: 34)
            }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: presence.mediaIsPlaying ? "play.fill" : "pause.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(presence.mediaTitle ?? "Media")
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                }
                if let artist = presence.mediaArtist?.nonEmpty {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

@MainActor
struct DestinationStatusRow: View {
    let destination: PresenceDestinationPresentation
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(nsImage: destination.providerImage)
                    .resizable()
                    .scaledToFit()
                    .presenceArtwork(size: 28, cornerRadius: 7)
                    .accessibilityHidden(true)

                Text(destination.id.displayName)
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 1) {
                    Label(destination.statusText, systemImage: destination.statusSymbolName)
                        .font(.caption)
                        .foregroundStyle(destination.statusColor)
                    if destination.configurationState == .ready,
                       let eventDate = destination.deliveryState.eventDate
                    {
                        Text(eventDate, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .frame(minHeight: 40)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(destination.id.displayName), \(destination.statusText)")
        .accessibilityHint("Open destination settings.")
    }
}

enum PresenceNoticeKind {
    case information
    case warning
    case error

    var symbolName: String {
        switch self {
        case .information: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .information: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
}

@MainActor
struct PresenceInlineNotice: View {
    let kind: PresenceNoticeKind
    let title: String
    let detail: String
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: kind.symbolName)
                .foregroundStyle(kind.color)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(kind.color.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

@MainActor
struct EmptyPresenceView: View {
    let symbolName: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbolName)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 30)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

@MainActor
private struct PresenceArtworkPlaceholder: View {
    let symbolName: String
    let size: CGFloat

    var body: some View {
        Image(systemName: symbolName)
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }
}

private extension View {
    func presenceArtwork(size: CGFloat, cornerRadius: CGFloat) -> some View {
        frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
            }
    }
}

private extension PresenceAggregateStatus {
    var symbolName: String {
        switch self {
        case .setupRequired: return "circle.dashed"
        case .paused: return "pause.circle.fill"
        case .idle: return "minus.circle.fill"
        case .ready: return "checkmark.circle.fill"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .degraded: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .setupRequired, .paused, .idle: return .secondary
        case .ready: return .green
        case .syncing: return .blue
        case .degraded: return .orange
        case .error: return .red
        }
    }
}

private extension PresencePresentation {
    var accessibilitySummary: String {
        var components = [String]()
        if let applicationName = applicationName?.nonEmpty {
            components.append(applicationName)
        }
        if let windowTitle = windowTitle?.nonEmpty {
            components.append(windowTitle)
        }
        if let mediaTitle = mediaTitle?.nonEmpty {
            components.append(mediaTitle)
        }
        if let mediaArtist = mediaArtist?.nonEmpty {
            components.append("by \(mediaArtist)")
        }
        return components.joined(separator: ", ")
    }
}

private extension PresenceDestinationPresentation {
    var providerImage: NSImage {
        NSImage(named: id.assetName)
            ?? NSImage(
                systemSymbolName: id.fallbackSymbolName,
                accessibilityDescription: id.displayName
            )
            ?? NSImage()
    }

    var statusText: String {
        configurationState == .ready
            ? deliveryState.displayText
            : configurationState.displayText
    }

    var statusSymbolName: String {
        guard configurationState == .ready else {
            switch configurationState {
            case .notConfigured: return "circle.dashed"
            case .disabled: return "pause.circle"
            case .invalid: return "exclamationmark.circle"
            case .ready: break
            }
            return "circle"
        }

        switch deliveryState {
        case .never: return "checkmark.circle"
        case .sending: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .skipped: return "forward.circle"
        }
    }

    var statusColor: Color {
        guard configurationState == .ready else {
            return configurationState == .invalid ? .orange : .secondary
        }

        switch deliveryState {
        case .never, .skipped: return .secondary
        case .sending: return .blue
        case .succeeded: return .green
        case .failed: return .red
        }
    }
}

private extension PresenceDestinationID {
    var fallbackSymbolName: String {
        switch self {
        case .mixSpace: return "network"
        case .slack: return "number"
        case .discord: return "bubble.left.and.bubble.right"
        }
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
