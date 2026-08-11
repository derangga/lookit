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
    /// Held rather than built inline so it can be greyed when OBS is absent,
    /// and so its tooltip can follow the program scene.
    private lazy var sceneButton = buildSceneButton()
    /// Held so its symbol can follow the state, and so it can carry the status
    /// text that has nowhere to go while the preview is collapsed.
    private lazy var previewButton = plainButton(
        "eye", "Hide preview", #selector(previewTapped)
    )
    /// Held so its title can follow the zoom and its menu can mark the stop.
    private lazy var zoomButton = buildZoomButton()
    /// Kept so a stops reload can restore the menu's checkmark to where the
    /// zoom is, and so the chip can say the multiplier without being asked.
    private var currentZoom: Double = 1.0
    private let previewBox = NSView()
    private let previewView = NSImageView()
    /// Swapped whenever the canvas shape changes, so the box always matches it.
    private var previewAspect: NSLayoutConstraint?
    private var previewVisible = true
    /// Kept so it can be shown again when the preview comes back, and so the
    /// collapsed chip can carry it as a tooltip meanwhile.
    private var status: String?
    private let perform: (HotkeyAction) -> Void
    /// Go straight to a stop. Separate from `perform` because a stop is a value,
    /// not one of the three named actions, and HotkeyAction must stay a plain
    /// enum — it is also the config key vocabulary.
    private let jump: (Double) -> Void
    private let onMove: (CGPoint) -> Void
    private let onQuit: () -> Void
    private let onActivateOBS: () -> Void
    /// So the frame feed can stop while there is nothing to show it in.
    private let onPreviewVisible: (Bool) -> Void
    private let onPickScene: (SceneName) -> Void

    private var stops: [Double] = Config.fallback.stops
    /// Cached, because `NSMenu.popUp` is synchronous and cannot wait on OBS.
    /// Kept fresh by the app from GetSceneList; empty means not connected.
    private var scenes: [SceneName] = []
    private var currentScene: SceneName?
    /// Kept so the controls can be greyed out when there is nothing to zoom.
    private var buttons: [NSButton] = []

    public init(
        savedPosition: CGPoint?,
        perform: @escaping (HotkeyAction) -> Void,
        jump: @escaping (Double) -> Void,
        onMove: @escaping (CGPoint) -> Void,
        onQuit: @escaping () -> Void,
        onActivateOBS: @escaping () -> Void,
        onPreviewVisible: @escaping (Bool) -> Void,
        onPickScene: @escaping (SceneName) -> Void
    ) {
        self.perform = perform
        self.jump = jump
        self.onMove = onMove
        self.onQuit = onQuit
        self.onActivateOBS = onActivateOBS
        self.onPreviewVisible = onPreviewVisible
        self.onPickScene = onPickScene

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

        // The gap is deliberate. Quit is the one control here that cannot be
        // taken back by clicking again, so it does not sit next to the ones
        // pressed mid-demo.
        let gap = NSView()
        gap.setContentHuggingPriority(.init(1), for: .horizontal)

        let controls = NSStackView(views: [
            plainButton("xmark", "Quit lookit", #selector(quitTapped)),
            previewButton,
            gap,
            sceneButton,
            button("arrow.counterclockwise", .reset),
            zoomButton,
        ])
        controls.orientation = .horizontal
        controls.spacing = 8
        controls.alignment = .centerY

        let preview = buildPreview()
        // Gravity areas rather than a plain list of views, and only because of
        // the collapse. A vertical stack puts everything in `.top`, so the
        // moment the preview hides the row has slack above it and jumps to the
        // top of a panel that has not shrunk yet — then rides the top edge back
        // down as it does. Anchoring the row to the bottom means the one edge
        // it sits on is the one edge the resize never moves, so it does not
        // move either.
        let stack = NSStackView()
        // Before the views go in: a gravity area means top or bottom only once
        // the stack knows which way it runs.
        stack.orientation = .vertical
        stack.addView(preview, in: .top)
        stack.addView(controls, in: .bottom)
        // Without this the row shrinks to its content and centres, and the gap
        // has no slack to push quit away from the cluster.
        //
        // Left active while the preview is collapsed, which is what keeps the
        // panel one width in both states: the hidden box is out of the stack's
        // layout but still 280 wide, so the row it is pinned to does not move.
        controls.widthAnchor.constraint(equalTo: preview.widthAnchor).isActive = true
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
        previewBox.layer?.cornerRadius = 8
        previewBox.layer?.masksToBounds = true
        // Neutral grey rather than the semantic `.labelColor` the chips use.
        // This one is a plain CGColor that never gets repainted, so it has to
        // be a colour with no light and dark variant to get wrong — and a well
        // reads as inset against either appearance. It is also only ever seen
        // empty: once a frame arrives the image covers it edge to edge.
        previewBox.layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.22).cgColor
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
        let button = Chip()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        button.toolTip = help
        button.target = self
        button.action = action
        style(button)
        return button
    }

    /// The scene chip: opens the program scenes, and OBS itself at the bottom.
    ///
    /// Icon only, deliberately. A chip wide enough for "Browser Demo" would eat
    /// the row, and one sized to the name would resize on every scene change —
    /// the same reason `zoomWidth` is a constant. The name is in the tooltip and
    /// checked in the menu, neither of which moves anything.
    ///
    /// The chevron is a glyph in the title rather than a second image, since a
    /// button has room for one image and the icon is the one worth having.
    private func buildSceneButton() -> NSButton {
        let button = Chip()
        button.image = NSImage(systemSymbolName: "video.fill", accessibilityDescription: "Scene")
        button.title = "▾"
        button.imagePosition = .imageLeft
        button.imageHugsTitle = true
        button.font = .systemFont(ofSize: 9, weight: .bold)
        button.toolTip = "Scene"
        button.target = self
        button.action = #selector(sceneTapped)
        style(button, width: HUD.sceneWidth)
        return button
    }

    /// The zoom chip: says where the zoom is, and opens the stops on click.
    ///
    /// Wider than the others by exactly the chevron. Without it nothing on the
    /// button says a menu is behind it, and a control you have to click to
    /// discover is a control most people never click.
    private func buildZoomButton() -> NSButton {
        let button = Chip()
        button.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        button.imagePosition = .imageRight
        // Otherwise AppKit pins the chevron to the button's right edge and
        // spends all the slack between it and the number — the chevron ends up
        // against the border stroke with a hole in the middle of the chip.
        // Hugging keeps the pair together and centres them as one.
        button.imageHugsTitle = true
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        button.toolTip = "Zoom level"
        button.target = self
        button.action = #selector(zoomTapped)
        style(button, width: HUD.zoomWidth)
        // Smaller than a chip's own icon: this is punctuation next to the
        // number, not a peer of the ✕ and ↺ symbols.
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
        return button
    }

    /// The shared look: a bordered, rounded target, square unless it carries a
    /// menu.
    ///
    /// Drawn rather than bezelled. Every AppKit bezel is designed against the
    /// system control background — `.texturedRounded` all but disappears on a
    /// `.hudWindow` blur — so the chrome is a layer instead, which is what
    /// makes `Chip` necessary: see the repaint there.
    ///
    /// The size is chosen, not measured. It used to be taken from the stop
    /// picker's `intrinsicContentSize` so the row would line up whatever
    /// metrics AppKit picked; that produced a consistent 24pt and a consistent
    /// 24pt is too small to hit mid-demo.
    private func style(_ button: NSButton, width: CGFloat = HUD.controlSide) {
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.layer?.borderWidth = 1
        // The title looks after itself: a borderless button draws it in
        // `.controlTextColor`, which is dynamic. Only the layer needs help.
        button.contentTintColor = .labelColor
        button.imageScaling = .scaleProportionallyDown
        button.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 13, weight: .medium
        )
        button.focusRingType = .none
        // Not cosmetic: a focusable control here lets a stray keystroke reframe
        // the shot, which is the promise .nonactivatingPanel makes about clicks.
        button.refusesFirstResponder = true
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: HUD.controlSide),
            button.widthAnchor.constraint(equalToConstant: width),
        ])
        (button as? Chip)?.paint()
    }

    @objc private func quitTapped() { onQuit() }
    @objc private func obsTapped() { onActivateOBS() }
    @objc private func previewTapped() { setPreviewVisible(!previewVisible) }

    /// Collapse the panel down to its control row, or bring the preview back.
    ///
    /// The frame feed is told either way: polling OBS for a picture nobody can
    /// see is the one part of this that costs something.
    private func setPreviewVisible(_ visible: Bool) {
        previewVisible = visible
        previewBox.isHidden = !visible
        let help = visible ? "Hide preview" : "Show preview"
        previewButton.image = NSImage(
            systemSymbolName: visible ? "eye" : "eye.slash", accessibilityDescription: help
        )
        previewButton.toolTip = help
        applyStatus()
        resizeToFit(animated: true)
        onPreviewVisible(visible)
    }

    /// Offer the stops, marking the one the zoom is nearest.
    ///
    /// Built on each click rather than held, because the stops are hot-reloaded
    /// from config and a menu built once would go stale the moment they change.
    @objc private func zoomTapped() {
        let menu = NSMenu()
        // Otherwise AppKit re-enables the header by validating it, and disables
        // every stop for the same reason.
        menu.autoenablesItems = false

        let header = NSMenuItem(title: "Zoom level", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let current = nearestStopIndex(stops: stops, current: currentZoom)
        for (index, stop) in stops.enumerated() {
            let item = NSMenuItem(
                title: zoomTitle(stop), action: #selector(stopPicked(_:)), keyEquivalent: ""
            )
            item.target = self
            item.tag = index
            item.state = index == current ? .on : .off
            menu.addItem(item)
        }

        popUp(menu, under: zoomButton)
    }

    /// Offer the program scenes, marking the live one, with OBS itself last.
    ///
    /// Built on each click from the cached list, for the same reason the stops
    /// menu is: OBS's scenes change while lookit is running, and a menu built
    /// once would go stale. The cache exists because `popUp` is synchronous —
    /// there is no point in the click where a round trip could be awaited.
    @objc private func sceneTapped() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        if !scenes.isEmpty {
            let header = NSMenuItem(title: "Scene", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            for scene in scenes {
                let item = NSMenuItem(
                    title: scene.raw, action: #selector(scenePicked(_:)), keyEquivalent: ""
                )
                item.target = self
                item.representedObject = scene.raw
                item.state = scene == currentScene ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        // Kept, and kept reachable when the list is empty: with OBS not running
        // there are no scenes to offer and opening it is the only useful thing
        // this chip can still do.
        let open = NSMenuItem(title: "Open OBS", action: #selector(obsTapped), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        popUp(menu, under: sceneButton)
    }

    /// Anchored in screen coordinates, from the chip's rect rather than a point
    /// inside it. A point in the chip's own space is ambiguous — the space
    /// turned out to be flipped, so `y: -4` put the menu's top edge *above* the
    /// chip, covering the number you opened it to change. A converted rect is
    /// flip-agnostic, and `minY` in screen space is the bottom whatever the view
    /// underneath believes.
    private func popUp(_ menu: NSMenu, under button: NSButton) {
        guard let window = button.window else { return }
        let onScreen = window.convertToScreen(button.convert(button.bounds, to: nil))
        menu.popUp(
            positioning: nil, at: NSPoint(x: onScreen.minX, y: onScreen.minY - 4), in: nil
        )
    }

    /// Grey the scene chip when OBS is not installed: there are no scenes to
    /// switch to and nothing to open.
    public func setOBSAvailable(_ available: Bool) {
        sceneButton.isEnabled = available
    }

    /// The scenes to offer, and which one is live. Empty while disconnected,
    /// which leaves the chip offering only "Open OBS".
    public func setScenes(_ scenes: [SceneName], current: SceneName?) {
        self.scenes = scenes
        currentScene = current
        sceneButton.toolTip = current.map { "Scene: \($0.raw)" } ?? "Scene"
    }

    private func button(_ symbol: String, _ action: HotkeyAction) -> NSButton {
        let button = Chip()
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

    @objc private func scenePicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        onPickScene(SceneName(raw))
    }

    @objc private func stopPicked(_ sender: NSMenuItem) {
        guard stops.indices.contains(sender.tag) else { return }
        jump(stops[sender.tag])
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
        // Nothing to build: the menu is made at click time, so a stops reload
        // only has to leave the chip saying the right thing.
        setZoom(currentZoom)
    }

    /// The zoom the user asked for — not the eased value on its way there.
    /// The chip prints this number, and a number that counts is a number that
    /// distracts during exactly the take it is not supposed to disturb.
    public func setZoom(_ zoom: Double) {
        currentZoom = zoom
        zoomButton.title = zoomTitle(zoom)
    }

    /// Grey the controls when there is nothing to zoom.
    ///
    /// The preview already says *why*; this says *that*, so a dead click reads
    /// as refused rather than broken.
    public func setZoomEnabled(_ enabled: Bool) {
        for button in buttons { button.isEnabled = enabled }
        zoomButton.isEnabled = enabled
    }

    /// Say what is wrong, in the preview's place.
    ///
    /// No resize: the panel is one size in every state now, so a warning
    /// arriving cannot make the HUD jump under the cursor.
    public func setStatus(_ text: String?) {
        status = text
        applyStatus()
    }

    private func applyStatus() {
        statusLabel.stringValue = status ?? ""
        statusLabel.isHidden = status == nil
        statusLabel.toolTip = status  // the full text, since three lines can truncate
        previewView.isHidden = status != nil
        // Collapsed, the box that says what is wrong is not on screen. The chip
        // that put it away carries the text instead, so a HUD minimised mid-demo
        // cannot swallow "not connected to OBS" with nowhere left to show it.
        if !previewVisible {
            previewButton.toolTip = status ?? "Show preview"
        }
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
    ///
    /// Animated only for the collapse, which is a thing the user did and should
    /// see happen. The canvas-aspect resize is not: it arrives on its own a
    /// moment after launch, and a panel that reshapes itself unasked reads as a
    /// glitch rather than as feedback.
    private func resizeToFit(animated: Bool = false) {
        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        guard size.width > 0, size.height > 0, panel.frame.size != size else { return }
        let frame = NSRect(origin: panel.frame.origin, size: size)

        guard animated else { return panel.setFrame(frame, display: true) }
        NSAnimationContext.runAnimationGroup { context in
            // Short enough to stay ahead of a second click, which is the only
            // way to interrupt it.
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    /// Wide enough for four bezelled controls without squeezing the preview,
    /// which is what should set the panel's width.
    static let previewWidth: CGFloat = 280
    /// Every chip's height, and the square chips' width. Sized to be hit
    /// without looking, mid-demo, on a panel that must not be aimed at.
    static let controlSide: CGFloat = 32
    /// The scene chip: a square plus room for its chevron.
    static let sceneWidth: CGFloat = 46
    /// The zoom chip: a square plus room for "1.5x" and its chevron.
    ///
    /// Fixed rather than fitted. Sizing to the label would shrink the chip on
    /// "1x" and grow it on "1.5x", so every zoom change would shuffle the row
    /// under the cursor — on the one panel that must stay clickable without
    /// being looked at. This is the widest default stop plus a small margin.
    static let zoomWidth: CGFloat = 50
    /// 16:9 until OBS says otherwise.
    static let defaultCanvasAspect: Double = 16.0 / 9.0
}

/// A control-row chip, repainted whenever the system flips appearance.
///
/// This class exists for one reason. `contentTintColor` is an `NSColor` and so
/// resolves at draw time — a symbol follows light and dark by itself. But
/// `layer.backgroundColor` is a `CGColor`, which is a colour that has *already*
/// been resolved, and a layer painted once at build time keeps the palette it
/// was born in. That is how the chrome ended up white-on-white: the panel's
/// material followed the system into light mode and the chips did not.
private final class Chip: NSButton {
    /// Auto Layout sizes the *alignment rect*; the layer paints the *frame*.
    ///
    /// `NSButton` pads the two apart to reserve focus-ring space, and the
    /// padding depends on the glyph — so one shared `heightAnchor == 32` gave
    /// `xmark` a 36.5pt frame, `video.fill` 37.5 and `arrow.counterclockwise`
    /// 40.5. Three visibly different chips from an identical constraint.
    /// Collapsing the insets makes the constraint mean what it says. Nothing is
    /// lost: these refuse first responder, so there is no ring to reserve for.
    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    /// Re-resolve the layer colours against whatever appearance is current now.
    func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.18).cgColor
        }
    }
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

/// How a stop is written where it needs a unit: on the chip, and in its menu.
///
/// The bare `stopLabel` is right on a row of stops, where the column says what
/// the numbers are. Standing alone on a button, `1.5` could be anything.
public func zoomTitle(_ stop: Double) -> String {
    stopLabel(stop) + "x"
}

/// Which stop the row should show as current, or nil when there are no stops.
///
/// Nearest rather than exact: mid-ease the zoom sits between stops, and the
/// highlight should still show where it is heading rather than blanking.
public func nearestStopIndex(stops: [Double], current: Double) -> Int? {
    stops.indices.min { abs(stops[$0] - current) < abs(stops[$1] - current) }
}
