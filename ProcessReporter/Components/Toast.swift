import Cocoa
import SnapKit

enum ToastStyle: Sendable {
    case success
    case error
    case warning
    case info

    var gradientColors: (NSColor, NSColor) {
        switch self {
        case .success:
            return (
                NSColor(red: 0.88, green: 1.0, blue: 0.91, alpha: 0.95), // 薄荷绿
                NSColor(red: 0.78, green: 0.95, blue: 0.85, alpha: 0.95)
            )
        case .error:
            return (
                NSColor(red: 1.0, green: 0.87, blue: 0.9, alpha: 0.95), // 柔粉红
                NSColor(red: 0.98, green: 0.8, blue: 0.85, alpha: 0.95)
            )
        case .warning:
            return (
                NSColor(red: 1.0, green: 0.96, blue: 0.87, alpha: 0.95), // 淡橙黄
                NSColor(red: 1.0, green: 0.93, blue: 0.78, alpha: 0.95)
            )
        case .info:
            return (
                NSColor(red: 0.87, green: 0.95, blue: 1.0, alpha: 0.95), // 婴儿蓝
                NSColor(red: 0.8, green: 0.9, blue: 1.0, alpha: 0.95)
            )
        }
    }

    var icon: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .success: return "Success"
        case .error: return "Error"
        case .warning: return "Warning"
        case .info: return "Information"
        }
    }

    var textColor: NSColor {
        return .textColor
    }
}

private class BlurGradientView: NSVisualEffectView {
    private let gradientLayer = CAGradientLayer()

    var startColor: NSColor = .clear {
        didSet { updateGradient() }
    }

    var endColor: NSColor = .clear {
        didSet { updateGradient() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true

        if let layer = layer {
            gradientLayer.frame = layer.bounds
            gradientLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer.addSublayer(gradientLayer)
        }

        updateGradient()
    }

    private func updateGradient() {
        gradientLayer.colors = [startColor.cgColor, endColor.cgColor]
        gradientLayer.startPoint = CGPoint(x: 0, y: 0)
        gradientLayer.endPoint = CGPoint(x: 1, y: 1)
        gradientLayer.opacity = 0.4 // 降低渐变色的不透明度，让毛玻璃效果更明显
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let layer = layer {
            gradientLayer.frame = layer.bounds
        }
    }
}

class ToastWindow: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        hasShadow = false
        backgroundColor = .clear
        level = .floating
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
}

private class ToastView: NSView {
    private let blurGradientView = BlurGradientView()
    private let stackView = NSStackView()
    private let iconView = NSImageView()
    private let messageLabel = NSTextField()

    init(message: String, style: ToastStyle) {
        super.init(frame: .zero)
        setupUI(message: message, style: style)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        // 设置为视图高度的一半，实现胶囊形状
        layer?.cornerRadius = bounds.height / 2
        blurGradientView.layer?.cornerRadius = bounds.height / 2
    }

    private func setupUI(message: String, style: ToastStyle) {
        wantsLayer = true
        layer?.masksToBounds = true

        // Blur gradient background setup
        blurGradientView.wantsLayer = true
        blurGradientView.layer?.masksToBounds = true
        let colors = style.gradientColors
        blurGradientView.startColor = colors.0
        blurGradientView.endColor = colors.1
        addSubview(blurGradientView)

        // Stack view setup
        stackView.orientation = .horizontal
        stackView.spacing = 8
        addSubview(stackView)

        // Icon setup
        if let image = NSImage(
            systemSymbolName: style.icon,
            accessibilityDescription: style.accessibilityDescription)
        {
            iconView.image = image
            iconView.contentTintColor = style.textColor
            stackView.addArrangedSubview(iconView)
        }

        // Label setup
        messageLabel.stringValue = message
        messageLabel.textColor = style.textColor
        messageLabel.backgroundColor = .clear
        messageLabel.isBezeled = false
        messageLabel.isEditable = false
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.toolTip = message
        messageLabel.setAccessibilityLabel(message)
        messageLabel.font = .systemFont(ofSize: 13, weight: .medium)
        stackView.addArrangedSubview(messageLabel)

        blurGradientView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        stackView.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16))
        }
    }
}

final class ToastManager: @unchecked Sendable {
    static let shared = ToastManager()
    @MainActor
    private var activeToasts: [ToastWindow] = []
    private let padding: CGFloat = 100
    private let spacing: CGFloat = 10

    private init() {}

    @MainActor
    private func hideToast(windowNumber: Int) {
        guard let window = activeToasts.first(where: { $0.windowNumber == windowNumber }) else {
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            window.animator().alphaValue = 0
        }) { [weak self] in
            Task { @MainActor in
                self?.finishHidingToast(windowNumber: windowNumber)
            }
        }
    }

    @MainActor
    private func finishHidingToast(windowNumber: Int) {
        guard let window = activeToasts.first(where: { $0.windowNumber == windowNumber }) else {
            return
        }
        window.close()
        activeToasts.removeAll { $0.windowNumber == windowNumber }
        repositionToasts()
    }

    @MainActor
    private func repositionToasts() {
        guard let screen = NSScreen.main else { return }
        let screenRect = screen.visibleFrame

        var yOffset = screenRect.minY + padding

        for window in activeToasts {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                window.animator().setFrameOrigin(
                    NSPoint(
                        x: screenRect.midX - window.frame.width / 2,
                        y: yOffset
                    ))
            }
            yOffset += window.frame.height + spacing
        }
    }

    public func show(
        _ message: String,
        style: ToastStyle = .info,
        duration: TimeInterval = 3.0
    ) {
        let displayDuration = duration.isFinite ? max(0, duration) : 3.0
        DispatchQueue.main.async { [weak self] in
            self?.showOnMain(message, style: style, duration: displayDuration)
        }
    }

    @MainActor
    private func showOnMain(
        _ message: String,
        style: ToastStyle,
        duration: TimeInterval
    ) {
        guard let screen = NSScreen.main else { return }
        let screenRect = screen.visibleFrame

        // Create toast view
        let toastView = ToastView(message: message, style: style)
        toastView.frame.size = toastView.fittingSize

        // Create window
        let windowWidth = min(max(toastView.frame.width, 200), 400)
        let windowHeight = toastView.frame.height
        let windowRect = NSRect(
            x: screenRect.midX - windowWidth / 2,
            y: screenRect.minY + padding,
            width: windowWidth,
            height: windowHeight
        )

        let window = ToastWindow(contentRect: windowRect)
        window.contentView = toastView

        // Show window with animation
        window.orderFront(nil)

        activeToasts.append(window)
        repositionToasts()

        // Schedule hide
        let windowNumber = window.windowNumber
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.hideToast(windowNumber: windowNumber)
        }
    }
}

extension ToastManager {
    func success(_ message: String, duration: TimeInterval = 3.0) {
        show(message, style: .success, duration: duration)
    }

    func error(_ message: String, duration: TimeInterval = 3.0) {
        show(message, style: .error, duration: duration)
    }

    func warning(_ message: String, duration: TimeInterval = 3.0) {
        show(message, style: .warning, duration: duration)
    }

    func info(_ message: String, duration: TimeInterval = 3.0) {
        show(message, style: .info, duration: duration)
    }
}
