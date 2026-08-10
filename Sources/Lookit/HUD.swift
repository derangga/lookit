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
    private let statusLabel = NSTextField(labelWithString: "")
    private let stopsControl = NSSegmentedControl()
    /// Held rather than built inline so it can be greyed when OBS is absent.
    private lazy var obsButton = plainButton("video.fill", "Open OBS", #selector(obsTapped))
    /// Kept so a stops reload can restore the selection to where the zoom is.
    private var currentZoom: Double = 1.0
    private let previewBox = NSView()
    private let previewView = NSImageView()
    /// Swapped whenever the canvas shape changes, so the box always matches it.
    private var previewAspect: NSLayoutConstraint?
    private let perform: (HotkeyAction) -> Void
    /// Go straight to a stop. Separate from `perform` because a stop is a value,
    /// not one of the three named actions, and HotkeyAction must stay a plain
    /// enum — it is also the config key vocabulary.
    private let jump: (Double) -> Void
    private let onMove: (CGPoint) -> Void
    private let onQuit: () -> Void
    private let onActivateOBS: () -> Void

    private var stops: [Double] = Config.fallback.stops
    /// Kept so the controls can be greyed out when there is nothing to zoom.
    private var buttons: [NSButton] = []

    public init(
        savedPosition: CGPoint?,
        perform: @escaping (HotkeyAction) -> Void,
        jump: @escaping (Double) -> Void,
        onMove: @escaping (CGPoint) -> Void,
        onQuit: @escaping () -> Void,
        onActivateOBS: @escaping () -> Void
    ) {
        self.perform = perform
        self.jump = jump
        self.onMove = onMove
        self.onQuit = onQuit
        self.onActivateOBS = onActivateOBS

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

        stopsControl.segmentStyle = .texturedRounded
        stopsControl.controlSize = .large
        stopsControl.trackingMode = .selectOne
        // Click-only. A focusable control here would let a stray keystroke
        // reframe the shot, which is the same promise .nonactivatingPanel makes
        // about clicks — observed changing the zoom from a synthetic keypress.
        stopsControl.refusesFirstResponder = true
        stopsControl.target = self
        stopsControl.action = #selector(stopPicked(_:))
        stopsControl.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        stopsControl.translatesAutoresizingMaskIntoConstraints = false
        stopsControl.heightAnchor.constraint(equalToConstant: HUD.controlHeight).isActive = true

        // The gap is deliberate. Quit is the one control here that cannot be
        // taken back by clicking again, so it does not sit next to the ones
        // pressed mid-demo.
        let gap = NSView()
        gap.setContentHuggingPriority(.init(1), for: .horizontal)

        let controls = NSStackView(views: [
            plainButton("xmark", "Quit lookit", #selector(quitTapped)),
            gap,
            obsButton,
            button("arrow.counterclockwise", .reset),
            stopsControl,
        ])
        controls.orientation = .horizontal
        controls.spacing = 8
        controls.alignment = .centerY

        let preview = buildPreview()
        let stack = NSStackView(views: [preview, controls])
        // Without this the row shrinks to its content and centres, and the gap
        // has no slack to push quit away from the cluster.
        controls.widthAnchor.constraint(equalTo: preview.widthAnchor).isActive = true
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

    /// A button that is not one of the three zoom actions, so it stays enabled
    /// when there is nothing to zoom — quitting and opening OBS are exactly what
    /// you want to reach when the target will not resolve.
    private func plainButton(_ symbol: String, _ help: String, _ action: Selector) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        button.toolTip = help
        button.target = self
        button.action = action
        style(button)
        return button
    }

    /// The shared look: a real bezel and a target big enough to hit without
    /// aiming, on a panel that floats over a live demo.
    ///
    /// `.texturedRounded` rather than the default push-button bezel, which
    /// renders as a light system control pasted onto a dark `.hudWindow` blur.
    /// The symbol configuration matters as much as the size — a bigger button
    /// alone just centres a small glyph in a large bezel.
    private func style(_ button: NSButton) {
        button.isBordered = true
        button.bezelStyle = .texturedRounded
        button.imageScaling = .scaleProportionallyDown
        button.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 13, weight: .medium
        )
        // Not cosmetic: a focusable control here lets a stray keystroke reframe
        // the shot, which is the promise .nonactivatingPanel makes about clicks.
        button.refusesFirstResponder = true
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: HUD.controlHeight + 6),
            button.heightAnchor.constraint(equalToConstant: HUD.controlHeight),
        ])
    }

    @objc private func quitTapped() { onQuit() }
    @objc private func obsTapped() { onActivateOBS() }

    /// Grey the OBS button when OBS is not installed, since nothing would open.
    public func setOBSAvailable(_ available: Bool) {
        obsButton.isEnabled = available
    }

    private func button(_ symbol: String, _ action: HotkeyAction) -> NSButton {
        let button = NSButton()
        defer { buttons.append(button) }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: action.rawValue)
        button.toolTip = action.rawValue
        button.target = self
        button.action = #selector(tapped(_:))
        button.tag = HotkeyAction.allCases.firstIndex(of: action) ?? 0
        style(button)
        return button
    }

    @objc private func tapped(_ sender: NSButton) {
        guard HotkeyAction.allCases.indices.contains(sender.tag) else { return }
        perform(HotkeyAction.allCases[sender.tag])
    }

    @objc private func stopPicked(_ sender: NSSegmentedControl) {
        guard stops.indices.contains(sender.selectedSegment) else { return }
        jump(stops[sender.selectedSegment])
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
        stopsControl.segmentCount = stops.count
        for (index, stop) in stops.enumerated() {
            stopsControl.setLabel(stopLabel(stop), forSegment: index)
            // 0 means "fit the label", which keeps the row honest when a config
            // supplies more stops than the default four.
            stopsControl.setWidth(0, forSegment: index)
        }
        setZoom(currentZoom)
    }

    public func setZoom(_ zoom: Double) {
        currentZoom = zoom
        guard let index = nearestStopIndex(stops: stops, current: zoom) else { return }
        stopsControl.selectedSegment = index
    }

    /// Grey the controls when there is nothing to zoom.
    ///
    /// The preview already says *why*; this says *that*, so a dead click reads
    /// as refused rather than broken.
    public func setZoomEnabled(_ enabled: Bool) {
        for button in buttons { button.isEnabled = enabled }
        stopsControl.isEnabled = enabled
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

    /// A frame, or nil for none. `dimmed` marks a frame that has stopped
    /// updating, so a stale picture cannot pass for a live one.
    public func setPreview(_ image: NSImage?, dimmed: Bool) {
        previewView.image = image
        previewView.alphaValue = dimmed ? 0.4 : 1.0
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

    /// Wide enough for four bezelled controls without squeezing the preview,
    /// which is what should set the panel's width.
    static let previewWidth: CGFloat = 280
    static let controlHeight: CGFloat = 26
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

/// How a stop is written on its button: `1`, `1.5`, `2`, `3`.
///
/// Whole numbers lose the decimal because a row of `1.0 1.5 2.0 3.0` is wider
/// and no clearer.
public func stopLabel(_ stop: Double) -> String {
    stop == stop.rounded()
        ? String(format: "%.0f", stop) : String(format: "%.1f", stop)
}

/// Which stop the row should show as current, or nil when there are no stops.
///
/// Nearest rather than exact: mid-ease the zoom sits between stops, and the
/// highlight should still show where it is heading rather than blanking.
public func nearestStopIndex(stops: [Double], current: Double) -> Int? {
    stops.indices.min { abs(stops[$0] - current) < abs(stops[$1] - current) }
}
