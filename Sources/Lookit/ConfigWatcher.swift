// Hot-reload. Editing easeMs ten times in a row is the whole tuning loop, and
// restarting the app between each one makes it unbearable.

import Foundation

/// What actually differs between two configs, so a reload only redoes the work
/// it has to.
///
/// This matters because lookit writes the config itself when the HUD is dragged.
/// Reacting to every difference would make our own writes churn the hotkeys;
/// reacting to what changed means a drag touches nothing but the position.
public struct ConfigChange: Equatable, Sendable {
    public var keys: Bool
    public var stops: Bool
    public var tuning: Bool
    public var obs: Bool

    public var isEmpty: Bool { !keys && !stops && !tuning && !obs }
}

public func changes(from old: Config, to new: Config) -> ConfigChange {
    ConfigChange(
        keys: old.keys != new.keys,
        stops: old.stops != new.stops,
        tuning: old.easeMs != new.easeMs || old.deadZone != new.deadZone,
        obs: old.obs != new.obs
    )
}

// MARK: - Watcher

@MainActor
public final class ConfigWatcher {
    private let store: ConfigStore
    private let interval: TimeInterval
    private let onReload: (ConfigLoad) -> Void
    private var timer: Timer?
    private var lastStamp: Stamp?

    private struct Stamp: Equatable {
        let modified: Date
        let size: Int
    }

    public init(
        store: ConfigStore,
        interval: TimeInterval = 1.0,
        onReload: @escaping (ConfigLoad) -> Void
    ) {
        self.store = store
        self.interval = interval
        self.onReload = onReload
    }

    public func start() {
        lastStamp = stamp()

        // ponytail: polls mtime+size once a second rather than using a vnode
        // source. Editors save by atomic replace, which swaps the inode out from
        // under a file descriptor — a vnode watcher then has to watch the parent
        // directory and re-arm, for no gain at this cadence. Switch if the
        // config ever needs sub-second reaction.
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Re-read immediately, whatever the file's timestamp says. Used by the
    /// menubar's "Reload config", where the user has asked explicitly.
    public func reloadNow() {
        lastStamp = stamp()
        onReload(store.load())
    }

    private func poll() {
        let current = stamp()
        guard current != lastStamp else { return }
        lastStamp = current
        onReload(store.load())
    }

    private func stamp() -> Stamp? {
        guard
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: store.path.path(percentEncoded: false)
            ),
            let modified = attributes[.modificationDate] as? Date
        else { return nil }

        // Size as well as mtime: some editors write twice within the same
        // second, and a one-second timestamp alone would miss the second write.
        return Stamp(modified: modified, size: (attributes[.size] as? Int) ?? 0)
    }
}
