// The always-visible floating panel.
//
// Two things are non-negotiable here. It must not steal focus when clicked —
// adjusting the zoom must not break the demo being recorded — and it must never
// appear in the capture (invariant 4).

import AppKit
import LookitCore

@MainActor
public final class HUD {
    private let panel: NSPanel
    private let zoomLabel = NSTextField(labelWithString: "1.0×")
    private let stopsLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let perform: (HotkeyAction) -> Void
    private let onMove: (CGPoint) -> Void

    private var stops: [Double] = Config.fallback.stops
    /// Kept so the controls can be greyed out when there is nothing to zoom.
    private var buttons: [NSButton] = []

    public init(
        savedPosition: CGPoint?,
        perform: @escaping (HotkeyAction) -> Void,
        onMove: @escaping (CGPoint) -> Void
    ) {
        self.perform = perform
        self.onMove = onMove

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: HUD.width, height: HUD.baseHeight),
            // .nonactivatingPanel is the whole point: clicking + must not pull
            // focus away from the app being captured.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configurePanel()
        buildContent()
        position(savedPosition)

        NotificationCenter.default.addObserver(
            self, selector: #selector(panelMoved),
            name: NSWindow.didMoveNotification, object: panel
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Panel

    private func configurePanel() {
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        // Invariant 4, layer two. Window capture cannot include a different
        // window, but this is what keeps the HUD out of the shot if a source is
        // ever switched to display capture — and out of screenshots.
        //
        // LOOKIT_HUD_CAPTURABLE exists only so the verification can tell
        // "excluded from capture" apart from "never drawn at all". Without a way
        // to make the panel capturable on demand, a blank screenshot proves
        // nothing. It is opt-in and never set in normal use.
        panel.sharingType =
            ProcessInfo.processInfo.environment["LOOKIT_HUD_CAPTURABLE"] == "1"
            ? .readOnly : .none

        // Follow the user across Spaces and stay put during Exposé, so it does
        // not vanish mid-stream.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
    }

    private func buildContent() {
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true

        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        zoomLabel.alignment = .center
        stopsLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        stopsLabel.textColor = .secondaryLabelColor
        stopsLabel.alignment = .center
        statusLabel.font = .systemFont(ofSize: 9)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        // Without this the label refuses to shrink, the stack grows to fit, and
        // a long warning spills outside the panel's rounded background.
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let controls = NSStackView(views: [
            button("minus", .zoomOut),
            zoomLabel,
            button("plus", .zoomIn),
            button("arrow.counterclockwise", .reset),
        ])
        controls.orientation = .horizontal
        controls.spacing = 8
        controls.alignment = .centerY

        let stack = NSStackView(views: [controls, stopsLabel, statusLabel])
        stack.orientation = .vertical
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.widthAnchor.constraint(equalToConstant: HUD.width),
        ])

        panel.contentView = background
        statusLabel.isHidden = true
    }

    private func button(_ symbol: String, _ action: HotkeyAction) -> NSButton {
        let button = NSButton()
        defer { buttons.append(button) }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: action.rawValue)
        button.isBordered = false
        button.bezelStyle = .inline
        button.target = self
        button.action = #selector(tapped(_:))
        button.tag = HotkeyAction.allCases.firstIndex(of: action) ?? 0
        return button
    }

    @objc private func tapped(_ sender: NSButton) {
        guard HotkeyAction.allCases.indices.contains(sender.tag) else { return }
        perform(HotkeyAction.allCases[sender.tag])
    }

    // MARK: - Position

    private func position(_ saved: CGPoint?) {
        let size = panel.frame.size
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrameOrigin(
            hudOrigin(
                saved: saved,
                visible: (visible.minX, visible.minY, visible.width, visible.height),
                size: (size.width, size.height)
            )
        )
    }

    @objc private func panelMoved() {
        onMove(panel.frame.origin)
    }

    // MARK: - Display

    public func show() {
        // orderFrontRegardless, not makeKeyAndOrderFront: the panel appears
        // without the app taking focus.
        panel.orderFrontRegardless()
    }

    public func setStops(_ stops: [Double]) {
        self.stops = stops
    }

    public func setZoom(_ zoom: Double) {
        zoomLabel.stringValue = String(format: "%.1f×", zoom)
        stopsLabel.stringValue = stopsRuler(stops: stops, current: zoom)
    }

    /// Grey the controls when there is nothing to zoom.
    ///
    /// The status line already says *why*; this says *that*, so a dead keypress
    /// reads as refused rather than broken.
    public func setZoomEnabled(_ enabled: Bool) {
        for button in buttons { button.isEnabled = enabled }
        zoomLabel.textColor = enabled ? .labelColor : .disabledControlTextColor
    }

    public func setStatus(_ text: String?) {
        statusLabel.stringValue = text ?? ""
        statusLabel.isHidden = text == nil
        statusLabel.toolTip = text  // the full text, since the label truncates

        // Grow for the extra line rather than letting it overlap the ruler.
        // Resizing keeps the bottom-left origin, so the panel does not appear
        // to jump when a warning arrives.
        let height = text == nil ? HUD.baseHeight : HUD.baseHeight + HUD.statusHeight
        guard panel.frame.height != height else { return }
        let origin = panel.frame.origin
        panel.setFrame(
            NSRect(x: origin.x, y: origin.y, width: HUD.width, height: height), display: true
        )
    }

    static let width: CGFloat = 168
    static let baseHeight: CGFloat = 56
    static let statusHeight: CGFloat = 14
}

// MARK: - Pure bits

/// Where the panel sits: the saved position when it is still on a screen,
/// otherwise the bottom-right corner.
///
/// A saved position is discarded when it falls outside the visible area, which
/// happens after unplugging the display it was dragged onto. Restoring it there
/// would leave the HUD permanently invisible with no way to get it back.
public func hudOrigin(
    saved: CGPoint?,
    visible: (x: Double, y: Double, width: Double, height: Double),
    size: (width: Double, height: Double)
) -> CGPoint {
    let margin = 24.0

    if let saved,
        saved.x >= visible.x - size.width + margin,
        saved.x <= visible.x + visible.width - margin,
        saved.y >= visible.y - size.height + margin,
        saved.y <= visible.y + visible.height - margin
    {
        return saved
    }

    return CGPoint(
        x: visible.x + visible.width - size.width - margin,
        y: visible.y + margin
    )
}

/// A one-line ruler of the configured stops with the current one marked.
///
///     1 · 1.5 ·●· 3
public func stopsRuler(stops: [Double], current: Double) -> String {
    guard !stops.isEmpty else { return "" }

    // Nearest rather than exact: mid-animation the zoom sits between stops, and
    // the marker should still show where it is heading.
    let nearest = stops.min { abs($0 - current) < abs($1 - current) }

    return stops.map { stop in
        let text = stop == stop.rounded() ? String(format: "%.0f", stop) : String(format: "%.1f", stop)
        return stop == nearest ? "●\(text)" : text
    }
    .joined(separator: " · ")
}
