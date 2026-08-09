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
    private var connectionState: Connection = .disconnected(.notStarted)
    private var obsVersion: String?
    private var zoom = 1.0

    func applicationDidFinishLaunching(_: Notification) {
        loadConfig()
        installConfiguredHotkeys()
        buildHUD()
        buildStatusItem()
        startWatchingConfig()
        connect()
    }

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
            self?.refreshMenu()
            if state.isUsable { self?.onIdentified() }
        } onEvent: { [weak self] event in
            self?.handle(event)
        }
        connection.start(config.obs)
        self.connection = connection
    }

    /// Restore comes before anything else touches the scene, per §2.
    private func onIdentified() {
        Task { [weak self] in
            await self?.restoreDirtyLayout()
            await self?.readVersion()
        }
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
            hud?.setStatus(error.message)
            FileHandle.standardError.write(Data("lookit: \(error.message)\n".utf8))
            refreshMenu()
        }
    }

    /// Releasing the outgoing target and resolving the new one is its own bead,
    /// and needs a journal that does not exist yet. Until then this proves the
    /// event actually arrives — which is the part the socket is responsible for.
    private func handle(_ event: ObsEvent) {
        switch event {
        case let .sceneChanged(scene):
            FileHandle.standardError.write(Data("lookit: scene → \(scene.raw)\n".utf8))
        }
    }

    /// The first real round-trip. Target resolution is the next bead; until then
    /// this is what proves op 6 out and op 7 back actually correlate.
    private func readVersion() async {
        guard let connection else { return }
        let version = try? await connection.call("GetVersion", NoBody(), as: ObsVersion.self)
        obsVersion = version?.obsVersion
        FileHandle.standardError.write(Data("lookit: OBS \(version?.obsVersion ?? "?")\n".utf8))
        refreshMenu()
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
            refreshMenu()
            hud?.setStatus("config: \(reason)")
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

        hud?.setStatus(warnings.isEmpty ? nil : warnings[0].detail)
        refreshMenu()
    }

    private func installConfiguredHotkeys() {
        let hotkeyWarnings = installHotkeys(
            config.keys,
            registrar: .live,
            perform: { [weak self] action in self?.perform(action) }
        )
        warnings.append(contentsOf: hotkeyWarnings)
    }

    // MARK: - HUD

    private func buildHUD() {
        let saved: CGPoint? =
            if let x = config.hud.x, let y = config.hud.y { CGPoint(x: x, y: y) } else { nil }

        let hud = HUD(
            savedPosition: saved,
            perform: { [weak self] action in self?.perform(action) },
            onMove: { [weak self] origin in self?.saveHUDPosition(origin) }
        )
        hud.setStops(config.stops)
        hud.setZoom(zoom)
        // Warnings raised during launch must reach the HUD too, not just the
        // menu — the reload path is not the only way to end up with one.
        hud.setStatus(warnings.first?.detail)
        hud.show()
        self.hud = hud
    }

    private func saveHUDPosition(_ origin: CGPoint) {
        config.hud = Config.HUD(x: origin.x, y: origin.y)
        if let warning = configStore.save(config) {
            warnings.append(warning)
            refreshMenu()
        }
    }

    // OBS is not wired yet — the transport and tick loop are their own beads.
    // Until then the zoom level is local, which is enough to prove the hotkeys
    // and the HUD controls drive the same state.
    private func perform(_ action: HotkeyAction) {
        switch action {
        case .zoomIn: zoom = nextStop(stops: config.stops, from: zoom, direction: 1)
        case .zoomOut: zoom = nextStop(stops: config.stops, from: zoom, direction: -1)
        case .reset: zoom = config.stops.first ?? 1.0
        }
        hud?.setZoom(zoom)
        refreshMenu()
    }

    // MARK: - Status item

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "plus.magnifyingglass", accessibilityDescription: "lookit"
        )
        item.menu = NSMenu()
        statusItem = item
        refreshMenu()
    }

    private func refreshMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        let title = obsVersion.map { "Connected to OBS \($0)" } ?? connectionState.message
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        menu.item(at: 0)?.isEnabled = false

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

    @objc private func editConfig() {
        NSWorkspace.shared.open(configStore.path)
    }

    @objc private func reloadConfig() {
        watcher?.reloadNow()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// .accessory: menubar only, no Dock icon and no menu bar of our own. The
// Info.plist sets LSUIElement too, so a bundled launch never flashes a Dock icon.
app.setActivationPolicy(.accessory)
app.run()
