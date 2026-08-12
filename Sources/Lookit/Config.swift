// §6 Boundary: config.json -> Config.
//
// JSON has no comments, so the first-run file is written COMPLETE — every key
// present with its default — and the README documents the ranges. Discovering a
// key name is 90% of what comments would have bought.

import Foundation

public struct Config: Equatable, Sendable {
    public var stops: [Double]
    public var easeMs: Int
    public var deadZone: Double
    /// How eagerly the shot closes on the cursor, per second. See `nextPanCenter`.
    public var panRate: Double
    public var keys: Keys
    public var obs: OBS
    public var hud: HUD

    public init(
        stops: [Double], easeMs: Int, deadZone: Double, panRate: Double,
        keys: Keys, obs: OBS, hud: HUD
    ) {
        self.stops = stops; self.easeMs = easeMs; self.deadZone = deadZone
        self.panRate = panRate; self.keys = keys; self.obs = obs; self.hud = hud
    }

    public struct Keys: Equatable, Sendable {
        public var zoomIn: String
        public var zoomOut: String
        public var reset: String

        public init(zoomIn: String, zoomOut: String, reset: String) {
            self.zoomIn = zoomIn; self.zoomOut = zoomOut; self.reset = reset
        }
    }

    public struct OBS: Equatable, Sendable {
        public var host: String
        public var port: Int
        public var password: String

        public init(host: String, port: Int, password: String) {
            self.host = host; self.port = port; self.password = password
        }
    }

    public struct HUD: Equatable, Sendable {
        public var x: Double?
        public var y: Double?

        public init(x: Double?, y: Double?) { self.x = x; self.y = y }
    }

    /// Defaults chosen against this machine: 30fps canvas, and cmd+opt+= / - / 0
    /// verified free because macOS accessibility zoom hotkeys are disabled here.
    /// On a stock macOS those three are the system zoom shortcuts.
    public static let fallback = Config(
        stops: [1.0, 1.5, 2.0, 3.0],
        easeMs: 350,
        deadZone: 0.6,
        // ~35% of the remaining distance per 33ms tick: enough lag to read as a
        // camera move, not so much that the cursor outruns the frame.
        panRate: 12.0,
        keys: Keys(zoomIn: "cmd+opt+=", zoomOut: "cmd+opt+-", reset: "cmd+opt+0"),
        obs: OBS(host: "127.0.0.1", port: 4455, password: ""),
        hud: HUD(x: nil, y: nil)
    )
}

// MARK: - Decoding

// Written by hand rather than synthesised so a *missing* key falls back to its
// default while a *wrongly typed* key is an error. Leniency about absence,
// strictness about nonsense.
extension Config: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.fallback
        stops = try c.decodeIfPresent([Double].self, forKey: .stops) ?? d.stops
        easeMs = try c.decodeIfPresent(Int.self, forKey: .easeMs) ?? d.easeMs
        deadZone = try c.decodeIfPresent(Double.self, forKey: .deadZone) ?? d.deadZone
        panRate = try c.decodeIfPresent(Double.self, forKey: .panRate) ?? d.panRate
        keys = try c.decodeIfPresent(Keys.self, forKey: .keys) ?? d.keys
        obs = try c.decodeIfPresent(OBS.self, forKey: .obs) ?? d.obs
        hud = try c.decodeIfPresent(HUD.self, forKey: .hud) ?? d.hud
    }
}

extension Config.Keys: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.fallback.keys
        zoomIn = try c.decodeIfPresent(String.self, forKey: .zoomIn) ?? d.zoomIn
        zoomOut = try c.decodeIfPresent(String.self, forKey: .zoomOut) ?? d.zoomOut
        reset = try c.decodeIfPresent(String.self, forKey: .reset) ?? d.reset
    }
}

extension Config.OBS: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.fallback.obs
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? d.host
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        password = try c.decodeIfPresent(String.self, forKey: .password) ?? d.password
    }
}

extension Config.HUD: Codable {
    private enum CodingKeys: String, CodingKey { case x, y }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decodeIfPresent(Double.self, forKey: .x)
        y = try c.decodeIfPresent(Double.self, forKey: .y)
    }

    /// Encodes nil explicitly as null rather than omitting the key.
    ///
    /// JSON was chosen over TOML on the grounds that a complete default file
    /// makes every key discoverable without comments. A key that disappears
    /// when unset breaks exactly that promise.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(x, forKey: .x)
        try c.encode(y, forKey: .y)
    }
}

// MARK: - Validation

/// A tuning knob that was out of range and got clamped, or a hotkey that could
/// not be parsed. Surfaced in the HUD — a silently ignored setting is worse than
/// a rejected one.
public struct ConfigWarning: Equatable, Sendable {
    public let key: String
    public let detail: String

    public init(key: String, detail: String) { self.key = key; self.detail = detail }
}

/// Clamp the tuning knobs into ranges that can actually work, reporting what
/// was changed.
///
/// Clamping rather than rejecting, because these are values the user tunes by
/// hand during a live session — a typo in `deadZone` must not take the app down
/// or revert every other setting they just changed.
public func validated(_ config: Config) -> (Config, [ConfigWarning]) {
    var out = config
    var warnings: [ConfigWarning] = []

    let usable = config.stops.filter { $0.isFinite && $0 >= 1.0 }.sorted()
    if usable.isEmpty {
        out.stops = Config.fallback.stops
        warnings.append(
            ConfigWarning(key: "stops", detail: "no usable stops (each must be >= 1.0); using defaults")
        )
    } else if usable != config.stops {
        out.stops = usable
        warnings.append(ConfigWarning(key: "stops", detail: "sorted and dropped stops below 1.0"))
    }

    if !(1...5000).contains(config.easeMs) {
        out.easeMs = min(max(config.easeMs, 1), 5000)
        warnings.append(ConfigWarning(key: "easeMs", detail: "clamped to 1...5000"))
    }

    if !(0...1).contains(config.deadZone) || !config.deadZone.isFinite {
        out.deadZone = config.deadZone.isFinite ? min(max(config.deadZone, 0), 1) : Config.fallback.deadZone
        warnings.append(ConfigWarning(key: "deadZone", detail: "clamped to 0...1"))
    }

    // 0 is meaningful — it turns the chase off and pans in lock-step, which is
    // what every version before this one did — so the floor is 0, not a minimum.
    if !(0...60).contains(config.panRate) || !config.panRate.isFinite {
        out.panRate = config.panRate.isFinite ? min(max(config.panRate, 0), 60) : Config.fallback.panRate
        warnings.append(ConfigWarning(key: "panRate", detail: "clamped to 0...60"))
    }

    if !(1...65535).contains(config.obs.port) {
        out.obs.port = Config.fallback.obs.port
        warnings.append(ConfigWarning(key: "obs.port", detail: "not a valid port; using 4455"))
    }

    return (out, warnings)
}

/// Parse the three hotkeys, skipping any that are malformed.
///
/// A bad binding is dropped individually so one typo cannot disable the others.
public func keybindings(from keys: Config.Keys) -> (
    zoomIn: Keybinding?, zoomOut: Keybinding?, reset: Keybinding?, warnings: [ConfigWarning]
) {
    var warnings: [ConfigWarning] = []

    func parse(_ text: String, _ name: String) -> Keybinding? {
        guard let binding = parseKeybinding(text) else {
            warnings.append(
                ConfigWarning(key: "keys.\(name)", detail: "unrecognised combination \"\(text)\"")
            )
            return nil
        }
        return binding
    }

    return (
        parse(keys.zoomIn, "zoomIn"),
        parse(keys.zoomOut, "zoomOut"),
        parse(keys.reset, "reset"),
        warnings
    )
}

// MARK: - Loading

public enum ConfigLoad: Equatable, Sendable {
    /// Parsed successfully. Warnings may still describe clamped values.
    case loaded(Config, [ConfigWarning])
    /// No file existed, so defaults were written. Not a failure.
    case seeded(Config)
    /// The file is unreadable or malformed. The caller keeps its last-good
    /// config — this is an escape, never a crash (invariant 6).
    case rejected(reason: String)
}

public struct ConfigStore: Sendable {
    public var load: @Sendable () -> ConfigLoad
    /// Returns nil on success, or a warning to show. Saving is only used for
    /// the HUD position, so a failure degrades to "the panel forgets where it
    /// was" rather than anything that should interrupt the user.
    public var save: @Sendable (Config) -> ConfigWarning?
    public var path: URL

    public init(
        path: URL,
        load: @escaping @Sendable () -> ConfigLoad,
        save: @escaping @Sendable (Config) -> ConfigWarning? = { _ in nil }
    ) {
        self.path = path
        self.load = load
        self.save = save
    }
}

extension ConfigStore {
    public static let defaultPath = FileManager.default
        .homeDirectoryForCurrentUser
        .appending(path: ".config/lookit/config.json")

    public static func live(path: URL = defaultPath) -> ConfigStore {
        ConfigStore(
            path: path,
            load: {
            guard FileManager.default.fileExists(atPath: path.path(percentEncoded: false)) else {
                // Write the complete default file so every key is discoverable.
                // A failure to write is not fatal: run on defaults and say so.
                do {
                    try writeDefaultConfig(to: path)
                    return .seeded(.fallback)
                } catch {
                    return .rejected(reason: "could not write defaults: \(error.localizedDescription)")
                }
            }

            do {
                let data = try Data(contentsOf: path)
                let parsed = try JSONDecoder().decode(Config.self, from: data)
                let (config, warnings) = validated(parsed)
                return .loaded(config, warnings)
            } catch {
                return .rejected(reason: describe(error))
            }
            },
            save: { config in
                // ponytail: rewrites the whole file, so any key lookit does not
                // know about is dropped. Fine while lookit owns the schema; if
                // the file ever grows foreign keys, merge instead of replace.
                do {
                    try FileManager.default.createDirectory(
                        at: path.deletingLastPathComponent(), withIntermediateDirectories: true
                    )
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try encoder.encode(config).write(to: path, options: .atomic)
                    return nil
                } catch {
                    return ConfigWarning(
                        key: "config", detail: "could not save: \(error.localizedDescription)"
                    )
                }
            }
        )
    }

    /// Always yields the same config. For tests and for reasoning about the app
    /// without touching the filesystem.
    public static func fixed(_ config: Config) -> ConfigStore {
        ConfigStore(path: defaultPath, load: { .loaded(config, []) })
    }
}

public func writeDefaultConfig(to path: URL) throws {
    try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(Config.fallback).write(to: path, options: .atomic)
}

/// Decoding errors are verbose and nested; the HUD has one line. Pull out the
/// key that actually broke.
func describe(_ error: Error) -> String {
    guard let decoding = error as? DecodingError else { return error.localizedDescription }

    switch decoding {
    case let .typeMismatch(type, context):
        return "\(pathOf(context)) should be \(type)"
    case let .valueNotFound(type, context):
        return "\(pathOf(context)) is null, expected \(type)"
    case let .dataCorrupted(context):
        return context.codingPath.isEmpty ? "not valid JSON" : "\(pathOf(context)) is malformed"
    case let .keyNotFound(key, _):
        return "missing key \(key.stringValue)"
    @unknown default:
        return "\(decoding)"
    }
}

private func pathOf(_ context: DecodingError.Context) -> String {
    let path = context.codingPath.map(\.stringValue).joined(separator: ".")
    return path.isEmpty ? "config" : path
}
