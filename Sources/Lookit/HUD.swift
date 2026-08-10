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
    private let previewBox = NSView()
    private let previewView = NSImageView()
    /// Swapped whenever the canvas shape changes, so the box always matches it.
    private var previewAspect: NSLayoutConstraint?
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
            // Provisional: buildContent sizes the panel to its content, and
            // setCanvasAspect resizes it again once OBS reports the canvas.
            contentRect: NSRect(x: 0, y: 0, width: HUD.previewWidth, height: 200),
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
        // maskImage, not layer.cornerRadius: a .behindWindow material is
        // composited by the window server outside the layer tree, so rounding
        // the layer leaves the blur itself square. This is the only knob that
        // shapes the material.
        background.maskImage = roundedMask(radius: 12)

        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        zoomLabel.alignment = .center
        stopsLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        stopsLabel.textColor = .secondaryLabelColor
        stopsLabel.alignment = .center

        let controls = NSStackView(views: [
            button("minus", .zoomOut),
            zoomLabel,
            button("plus", .zoomIn),
            button("arrow.counterclockwise", .reset),
        ])
        controls.orientation = .horizontal
        controls.spacing = 8
        controls.alignment = .centerY

        let stack = NSStackView(views: [buildPreview(), controls, stopsLabel])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 6, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
        ])

        panel.contentView = background
        statusLabel.isHidden = true
        resizeToFit()
    }

    /// The preview area, and the status text that shares it.
    ///
    /// They are never both wanted: whenever there is something to say, there is
    /// no frame worth showing. That is what lets one box serve both and why the
    /// panel no longer has to grow for a status line.
    private func buildPreview() -> NSView {
        previewBox.wantsLayer = true
        previewBox.layer?.cornerRadius = 6
        previewBox.layer?.masksToBounds = true
        previewBox.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        previewBox.translatesAutoresizingMaskIntoConstraints = false

        previewView.imageScaling = .scaleProportionallyUpOrDown
        previewView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        previewBox.addSubview(previewView)
        previewBox.addSubview(statusLabel)

        let aspect = previewBox.heightAnchor.constraint(
            equalTo: previewBox.widthAnchor, multiplier: 1 / HUD.defaultCanvasAspect
        )
        previewAspect = aspect

        NSLayoutConstraint.activate([
            previewBox.widthAnchor.constraint(equalToConstant: HUD.previewWidth),
            aspect,
            previewView.topAnchor.constraint(equalTo: previewBox.topAnchor),
            previewView.bottomAnchor.constraint(equalTo: previewBox.bottomAnchor),
            previewView.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: previewBox.trailingAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: previewBox.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: previewBox.trailingAnchor, constant: -8),
        ])
        return previewBox
    }

    /// A resizable rounded-rectangle mask for shaping the material.
    ///
    /// Cap insets are what let one small image shape any panel size: the four
    /// corners are drawn once and the middle is stretched, so the rounding
    /// survives the panel resizing when a status line arrives.
    private func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let mask = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        return mask
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

    /// Say what is wrong, in the preview's place.
    ///
    /// No resize: the panel is one size in every state now, so a warning
    /// arriving cannot make the HUD jump under the cursor.
    public func setStatus(_ text: String?) {
        statusLabel.stringValue = text ?? ""
        statusLabel.isHidden = text == nil
        statusLabel.toolTip = text  // the full text, since three lines can truncate
        previewView.isHidden = text != nil
    }

    /// Shape the preview to the OBS canvas, so what is framed here is what goes
    /// out. Until this arrives the box is 16:9, which is merely a guess.
    public func setCanvasAspect(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        let aspect = Double(width) / Double(height)

        previewAspect?.isActive = false
        let updated = previewBox.heightAnchor.constraint(
            equalTo: previewBox.widthAnchor, multiplier: 1 / aspect
        )
        updated.isActive = true
        previewAspect = updated

        resizeToFit()
    }

    /// Size the panel to its content, keeping the bottom-left origin so it does
    /// not appear to jump.
    private func resizeToFit() {
        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        guard size.width > 0, size.height > 0, panel.frame.size != size else { return }
        panel.setFrame(NSRect(origin: panel.frame.origin, size: size), display: true)
    }

    static let previewWidth: CGFloat = 240
    /// 16:9 until OBS says otherwise.
    static let defaultCanvasAspect: Double = 16.0 / 9.0
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
