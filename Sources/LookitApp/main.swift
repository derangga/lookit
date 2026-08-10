// The menubar shell. Deliberately thin: it owns the app lifecycle and nothing
// else, so the layers below stay testable without a running NSApplication.

import AppKit
import Lookit
import LookitCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let configStore = ConfigStore.live()
    private let journal = JournalStore.live()
    private var restored = false
    private var config = Config.fallback
    private var warnings: [ConfigWarning] = []
    private var hud: HUD?
    private var watcher: ConfigWatcher?
    private var connection: OBSConnection?
    private var scope: DirtyScope?
    private var sender: TransformSender?
    private var tickTask: Task<Void, Never>?
    private var loop: TickLoop?
    /// Which capture the user picked, per scene, when a scene had several.
    ///
    /// In memory only: a scene with two captures is rare, the choice is one
    /// click, and persisting it would mean a config schema for something that
    /// may never be used twice.
    private var preferred: [SceneName: InputName] = [:]
    private var connectionState: Connection = .disconnected(.notStarted)
    private var obsVersion: String?
    /// Nil until the first resolve runs. hudStatus reads nil as "nothing to
    /// say about the target yet", which is different from unresolved.
    private var target: TargetState?
    private var zoom = 1.0

    func applicationDidFinishLaunching(_: Notification) {
        loadConfig()
        installConfiguredHotkeys()
        buildHUD()
        buildStatusItem()
        startWatchingConfig()
        connect()
    }

    /// No release on quit, deliberately. Termination cannot await a round-trip
    /// to OBS, and a journal left on disk is exactly what restore-on-launch
    /// exists to consume. Trying to be tidy here would risk a half-write.
    func applicationWillTerminate(_: Notification) {
        HotkeyCenter.shared.unregisterAll()
        connection?.stop()
    }

    // MARK: - OBS

    private func connect() {
        let connection = OBSConnection { [weak self] state in
            self?.connectionState = state
            self?.obsVersion = nil
            // The only window onto a menubar app run from a terminal. One line
            // per transition, not a log framework.
            FileHandle.standardError.write(Data("lookit: \(state.message)\n".utf8))
            self?.refresh()
            if state.isUsable { self?.onIdentified() }
        } onEvent: { [weak self] event in
            self?.handle(event)
        }
        connection.start(config.obs)
        self.connection = connection
        // The scope needs a live connection to put the pristine back, so it is
        // built here rather than at launch.
        scope = DirtyScope(journal: journal) { pristine throws(ObsError) in
            try await connection.call(
                "SetSceneItemTransform", SetSceneItemTransformRequest(pristine)
            )
        }
        sender = TransformSender { request throws(ObsError) in
            try await connection.call("SetSceneItemTransform", request)
        }
    }

    /// Restore comes before anything else touches the scene, per §2.
    private func onIdentified() {
        Task { [weak self] in
            await self?.restoreDirtyLayout()
            await self?.readVersion()
            await self?.readCanvas()
            await self?.resolve()
        }
    }

    /// Find what to zoom. Runs on connect and after every scene change; both
    /// are the only moments the answer can change.
    private func resolve() async {
        guard let connection else { return }
        target = await resolveTarget(
            connection: connection, locate: WindowLocator.unverified.locate, owner: windowOwner,
            preferring: { [weak self] scene in self?.preferred[scene] }
        )
        let described = switch target {
        case let .resolved(t): "target \(t.inputName.raw) #\(t.itemId.raw) window \(t.window.raw) \(t.bundleID ?? "?")"
        case let .unresolved(reason): "no target — \(reason.message)"
        case nil: "no target"
        }
        FileHandle.standardError.write(Data("lookit: \(described)\n".utf8))
        refresh()
    }

    /// Once per launch, not once per connection. A journal written by *this*
    /// run belongs to a target that is still live, and a mid-session reconnect
    /// must not undo the zoom the user is currently looking at.
    private func restoreDirtyLayout() async {
        guard !restored, let connection else { return }
        // Set before the attempt: a failed restore keeps its journal and waits
        // for the next launch rather than retrying on every reconnect.
        restored = true

        do {
            try await restoreJournalIfPresent(journal: journal) { pristine throws(ObsError) in
                try await connection.call(
                    "SetSceneItemTransform", SetSceneItemTransformRequest(pristine)
                )
            }
        } catch {
            warnings.append(ConfigWarning(key: "restore", detail: error.message))
            FileHandle.standardError.write(Data("lookit: \(error.message)\n".utf8))
            refresh()
        }
    }

    private func handle(_ event: ObsEvent) {
        switch event {
        case let .sceneChanged(scene):
            FileHandle.standardError.write(Data("lookit: scene → \(scene.raw)\n".utf8))
            Task { [weak self] in await self?.switchScene() }
        }
    }

    /// Invariant 2, and the order is the whole point: the outgoing target is
    /// given back before the incoming one can be taken.
    ///
    /// If the release fails the scope stays dirty, and `acquire` then refuses
    /// the new target rather than leaving two items altered.
    private func switchScene() async {
        stopTicking()
        loop?.stopHolding()
        loop = nil
        await releaseScope()
        zoom = config.stops.first ?? 1.0
        hud?.setZoom(zoom)
        await resolve()
    }

    /// Shown in the menu, and the cheapest possible proof the round-trip works.
    /// Shape the preview to the canvas. Failing is harmless — the box keeps its
    /// 16:9 guess — so this is a `try?` rather than a state the HUD reports.
    private func readCanvas() async {
        guard let connection else { return }
        guard
            let video = try? await connection.call(
                "GetVideoSettings", NoBody(), as: VideoSettingsResponse.self
            )
        else { return }
        hud?.setCanvasAspect(width: video.baseWidth, height: video.baseHeight)
    }

    private func readVersion() async {
        guard let connection else { return }
        let version = try? await connection.call("GetVersion", NoBody(), as: ObsVersion.self)
        obsVersion = version?.obsVersion
        FileHandle.standardError.write(Data("lookit: OBS \(version?.obsVersion ?? "?")\n".utf8))
        refresh()
    }

    // MARK: - Config

    private func loadConfig() {
        switch configStore.load() {
        case let .loaded(loaded, loadWarnings):
            config = loaded
            warnings = loadWarnings
        case let .seeded(defaults):
            config = defaults
            warnings = []
        case let .rejected(reason):
            // Invariant 6: a bad config never stops the app. Run on whatever we
            // last had — on launch that is the defaults — and say so.
            warnings = [ConfigWarning(key: "config", detail: reason)]
        }
    }

    private func startWatchingConfig() {
        let watcher = ConfigWatcher(store: configStore) { [weak self] load in
            self?.applyReload(load)
        }
        watcher.start()
        self.watcher = watcher
    }

    /// Only redo the work that the edit actually invalidated. lookit writes this
    /// file itself when the HUD is dragged, so reacting to every difference
    /// would churn the hotkeys on every drag.
    private func applyReload(_ load: ConfigLoad) {
        let previous = config

        switch load {
        case let .loaded(reloaded, reloadWarnings):
            config = reloaded
            warnings = reloadWarnings
        case let .seeded(defaults):
            config = defaults
            warnings = []
        case let .rejected(reason):
            // Invariant 6: keep the last-good config and say what is wrong.
            warnings = [ConfigWarning(key: "config", detail: reason)]
            refresh()
            return
        }

        let delta = changes(from: previous, to: config)
        if delta.keys { installConfiguredHotkeys() }
        // Fixing a wrong password in the config is the main way out of the
        // authFailed escape, which has stopped the retry loop for good.
        if delta.obs { connection?.start(config.obs) }
        if delta.stops {
            hud?.setStops(config.stops)
            hud?.setZoom(zoom)
        }

        refresh()
    }

    private func installConfiguredHotkeys() {
        let hotkeyWarnings = installHotkeys(
            config.keys,
            registrar: .live,
            perform: { [weak self] action in self?.perform(action) }
        )
        warnings.append(contentsOf: hotkeyWarnings)
        // A hotkey the system refused was previously only visible by opening
        // the menu, which is a silent failure for a background app.
        for warning in hotkeyWarnings {
            FileHandle.standardError.write(
                Data("lookit: ⚠ \(warning.key): \(warning.detail)\n".utf8)
            )
        }
    }

    // MARK: - HUD

    private func buildHUD() {
        let saved: CGPoint? =
            if let x = config.hud.x, let y = config.hud.y { CGPoint(x: x, y: y) } else { nil }

        let hud = HUD(
            savedPosition: saved,
            perform: { [weak self] action in self?.perform(action) },
            jump: { [weak self] stop in self?.apply(zoom: stop, because: "stop") },
            onMove: { [weak self] origin in self?.saveHUDPosition(origin) },
            onQuit: { [weak self] in self?.quit() },
            onActivateOBS: { [weak self] in self?.activateOBS() }
        )
        hud.setOBSAvailable(
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: obsBundleIdentifier) != nil
        )
        hud.setStops(config.stops)
        hud.setZoom(zoom)
        hud.show()
        self.hud = hud
    }

    private func saveHUDPosition(_ origin: CGPoint) {
        config.hud = Config.HUD(x: origin.x, y: origin.y)
        if let warning = configStore.save(config) {
            warnings.append(warning)
            refresh()
        }
    }

    /// Invariant 1's precondition, and the one place both input paths meet.
    ///
    /// The HUD buttons are greyed out without a Target, but a hotkey does not
    /// go through them — so the refusal lives here, where the tick loop will
    /// share it. No Target, no reframe: not a partial one, not a crop applied
    /// with nothing to restore it from.
    /// One of the three named actions: work out which stop it means, then go.
    private func perform(_ action: HotkeyAction) {
        let resting = config.stops.first ?? 1.0
        // From where the zoom actually is — the loop owns that once it is
        // running — so a keypress mid-ease advances rather than snapping back.
        let current = loop?.zoom ?? zoom
        let next =
            switch action {
            case .zoomIn: nextStop(stops: config.stops, from: current, direction: 1)
            case .zoomOut: nextStop(stops: config.stops, from: current, direction: -1)
            case .reset: resting
            }
        apply(zoom: next, because: action.rawValue)
    }

    /// Go to a zoom level, whatever asked for it.
    ///
    /// The one path to a reframe: hotkeys arrive through `perform`, the HUD's
    /// stop buttons come straight here. Anything that needs to happen on every
    /// zoom change belongs in this function, not in its callers.
    private func apply(zoom next: Double, because reason: String) {
        guard let target = target?.target, let scope else {
            FileHandle.standardError.write(
                Data("lookit: \(reason) ignored — nothing to zoom\n".utf8)
            )
            return
        }

        let resting = config.stops.first ?? 1.0

        // Invariant 1, and the reason this runs before `zoom` is assigned: the
        // tick loop reframes from the zoom level, so a durable pristine must
        // exist before the level can say "not 1x". A journal that will not
        // write means no zoom at all — this is a precondition, not best effort.
        if next > resting {
            do {
                try scope.acquire(target)
            } catch {
                warnings.append(ConfigWarning(key: "journal", detail: error.message))
                FileHandle.standardError.write(
                    Data("lookit: refusing to zoom — \(error.message)\n".utf8)
                )
                refresh()
                return
            }
        }

        guard case let .dirty(pristine) = scope.state else {
            // Nothing is held and nothing is being taken: already at rest.
            return
        }

        FileHandle.standardError.write(
            Data("lookit: \(reason) → \(next)× on \(pristine.inputName.raw)\n".utf8)
        )
        let loop = self.loop ?? makeLoop()
        self.loop = loop
        loop.aim(at: next, pristine: pristine, window: target.window)
        zoom = next
        startTicking()
        refresh()
    }

    private func makeLoop() -> TickLoop {
        let expecting = target?.target?.bundleID
        return TickLoop(
            environment: TickLoop.Environment(
                cursor: cursorPosition,
                locate: WindowLocator.live(expecting: expecting).locate,
                now: { Date().timeIntervalSinceReferenceDate },
                send: { [weak self] request in self?.sender?.post(request) }
            ),
            deadZone: config.deadZone,
            easeMs: config.easeMs,
            resting: config.stops.first ?? 1.0
        )
    }

    // MARK: - The tick loop

    /// 30Hz, and only while something is actually zoomed. At rest there is
    /// nothing to animate and nothing to send, so the loop stops rather than
    /// spinning on an idle machine.
    private func startTicking() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                // 30Hz because the canvas is 30fps; 60 would double the traffic
                // for no visible gain.
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }

    private func tick() {
        guard let loop else { return stopTicking() }

        switch loop.step() {
        case .running:
            hud?.setZoom(loop.zoom)
        case .settled:
            hud?.setZoom(loop.zoom)
            settle()
        case .windowGone:
            target = .unresolved(.windowGone)
            settle()
        case .idle:
            stopTicking()
        }
    }

    private func settle() {
        stopTicking()
        loop?.stopHolding()
        loop = nil
        zoom = config.stops.first ?? 1.0
        hud?.setZoom(zoom)
        Task { [weak self] in
            await self?.releaseScope()
            self?.refresh()
        }
    }

    private func releaseScope() async {
        guard let scope else { return }
        do {
            try await scope.release()
        } catch {
            warnings.append(ConfigWarning(key: "restore", detail: error.message))
            FileHandle.standardError.write(Data("lookit: \(error.message)\n".utf8))
            refresh()
        }
    }

    // MARK: - Status item

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "plus.magnifyingglass", accessibilityDescription: "lookit"
        )
        item.menu = NSMenu()
        statusItem = item
        refresh()
    }

    /// Both surfaces, always together. Every state change routes here, which is
    /// why nothing has to remember to update the HUD on its own — the bug that
    /// let a config warning silently overwrite a restore failure.
    private func refresh() {
        hud?.setStatus(hudStatus(connection: connectionState, target: target, warnings: warnings))
        hud?.setZoomEnabled(target?.target != nil)

        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        let title = obsVersion.map { "Connected to OBS \($0)" } ?? connectionState.message
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        menu.item(at: 0)?.isEnabled = false

        // A scene with several captures is the user's choice to make, so make it
        // makeable rather than only reporting the deadlock.
        if case let .unresolved(.ambiguous(names)) = target {
            menu.addItem(.separator())
            for name in names {
                let item = NSMenuItem(
                    title: "Zoom \(name.raw)", action: #selector(choose(_:)), keyEquivalent: ""
                )
                item.target = self
                item.representedObject = name.raw
                menu.addItem(item)
            }
        }

        if !warnings.isEmpty {
            menu.addItem(.separator())
            for warning in warnings {
                let item = NSMenuItem(
                    title: "⚠ \(warning.key): \(warning.detail)", action: nil, keyEquivalent: ""
                )
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Edit config…", action: #selector(editConfig), keyEquivalent: ""
        ).target = self
        menu.addItem(
            withTitle: "Reload config", action: #selector(reloadConfig), keyEquivalent: ""
        ).target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit lookit", action: #selector(quit), keyEquivalent: "q").target =
            self
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        Task { [weak self] in
            guard let self, let connection else { return }
            // The scene the choice belongs to is whichever one is live now.
            let scene = try? await connection.call(
                "GetCurrentProgramScene", NoBody(), as: CurrentSceneResponse.self
            ).sceneName
            guard let scene else { return }
            preferred[scene] = InputName(raw)
            await resolve()
        }
    }

    @objc private func editConfig() {
        NSWorkspace.shared.open(configStore.path)
    }

    @objc private func reloadConfig() {
        watcher?.reloadNow()
    }

    /// Put the framing back, then go.
    ///
    /// applicationWillTerminate deliberately does not do this — it cannot await
    /// a round trip, and the journal plus restore-on-launch is the safety net.
    /// A button is not that notification: it can spend the 0.27ms and hand the
    /// layout back before the process goes down, which matters now that quit is
    /// one click on a panel floating over a live demo rather than a menu item
    /// clicked once a day.
    ///
    /// If OBS is unreachable the release fails fast and the journal still
    /// restores on next launch, so this only ever improves on terminating flat.
    @objc private func quit() {
        Task { [weak self] in
            await self?.releaseScope()
            NSApp.terminate(nil)
        }
    }

    /// Bring OBS forward, launching it if it is not running — what clicking its
    /// Dock icon would do.
    @objc private func activateOBS() {
        guard
            let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: obsBundleIdentifier
            )
        else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// .accessory: menubar only, no Dock icon and no menu bar of our own. The
// Info.plist sets LSUIElement too, so a bundled launch never flashes a Dock icon.
app.setActivationPolicy(.accessory)
app.run()
