import AppKit

@MainActor
enum MenuBarIconRenderer {
    private static let imageSize = NSSize(width: 18, height: 18)

    static func image(for status: PresenceAggregateStatus) -> NSImage {
        let image = NSImage(size: imageSize, flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            drawPresenceCard()
            drawStatusMark(for: status)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "ProcessReporter, \(status.accessibilityDescription)"
        return image
    }

    private static func drawPresenceCard() {
        let card = NSBezierPath(
            roundedRect: NSRect(x: 1.5, y: 3, width: 15, height: 12),
            xRadius: 2.6,
            yRadius: 2.6
        )
        card.lineWidth = 1.45
        card.stroke()

        drawLine(from: NSPoint(x: 4, y: 10.7), to: NSPoint(x: 9.2, y: 10.7), width: 1.35)
        drawLine(from: NSPoint(x: 4, y: 7.2), to: NSPoint(x: 8, y: 7.2), width: 1.35)
    }

    private static func drawStatusMark(for status: PresenceAggregateStatus) {
        switch status {
        case .setupRequired:
            drawLine(from: NSPoint(x: 13, y: 6), to: NSPoint(x: 13, y: 9.4), width: 1.35)
            drawLine(from: NSPoint(x: 11.3, y: 7.7), to: NSPoint(x: 14.7, y: 7.7), width: 1.35)

        case .paused:
            drawLine(from: NSPoint(x: 12.1, y: 6), to: NSPoint(x: 12.1, y: 9.4), width: 1.55)
            drawLine(from: NSPoint(x: 14.2, y: 6), to: NSPoint(x: 14.2, y: 9.4), width: 1.55)

        case .idle:
            drawLine(from: NSPoint(x: 11.5, y: 7.7), to: NSPoint(x: 14.5, y: 7.7), width: 1.45)

        case .ready:
            let dot = NSBezierPath(ovalIn: NSRect(x: 11.4, y: 6.1, width: 3.4, height: 3.4))
            dot.fill()

        case .syncing:
            drawChevron(
                from: NSPoint(x: 11.3, y: 8.5),
                through: NSPoint(x: 13, y: 9.8),
                to: NSPoint(x: 14.7, y: 8.5)
            )
            drawChevron(
                from: NSPoint(x: 14.7, y: 6.8),
                through: NSPoint(x: 13, y: 5.5),
                to: NSPoint(x: 11.3, y: 6.8)
            )

        case .degraded:
            drawLine(from: NSPoint(x: 13, y: 7.5), to: NSPoint(x: 13, y: 9.5), width: 1.45)
            NSBezierPath(ovalIn: NSRect(x: 12.25, y: 5.6, width: 1.5, height: 1.5)).fill()

        case .error:
            drawLine(from: NSPoint(x: 11.6, y: 6.2), to: NSPoint(x: 14.4, y: 9.2), width: 1.45)
            drawLine(from: NSPoint(x: 14.4, y: 6.2), to: NSPoint(x: 11.6, y: 9.2), width: 1.45)
        }
    }

    private static func drawChevron(from: NSPoint, through: NSPoint, to: NSPoint) {
        let path = NSBezierPath()
        path.move(to: from)
        path.line(to: through)
        path.line(to: to)
        path.lineWidth = 1.25
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    private static func drawLine(from: NSPoint, to: NSPoint, width: CGFloat) {
        let path = NSBezierPath()
        path.move(to: from)
        path.line(to: to)
        path.lineWidth = width
        path.lineCapStyle = .round
        path.stroke()
    }
}
