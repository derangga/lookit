// §1 Shapes — the state variants.
//
// These are written so illegal combinations cannot be expressed. Most of the
// invariants in CLAUDE.md are enforced here by shape rather than by checks at
// use sites: Dirtiness cannot be dirty without a Pristine, and a Target cannot
// exist without a resolved capture binding.

import LookitCore

// MARK: - Connection

public enum Connection: Equatable, Sendable {
    case disconnected(DisconnectReason)
    case connecting
    case identified

    public var isUsable: Bool { self == .identified }

    /// What to show the user. Lives here beside the state rather than in the
    /// menu so the HUD and the menu cannot drift apart.
    public var message: String {
        switch self {
        case .identified: "Connected to OBS"
        case .connecting: "Connecting to OBS…"
        case let .disconnected(reason): reason.message
        }
    }
}

public enum DisconnectReason: Equatable, Sendable {
    /// Never connected yet this run.
    case notStarted
    /// Nothing is listening. Retryable — OBS may simply not be up yet.
    case refused
    /// OBS is up but the WebSocket server is switched off. Retryable, but the
    /// user has to act, so it gets its own case and its own HUD message.
    case serverDisabled
    /// The password is wrong. NOT retryable: retrying a wrong password will
    /// never succeed, so the connect loop must stop rather than spin.
    case authFailed
    /// The socket died mid-session.
    case dropped(String)

    public var isRetryable: Bool {
        switch self {
        case .authFailed: false
        case .notStarted, .refused, .serverDisabled, .dropped: true
        }
    }

    /// Each case says what to do about it. "Disconnected" on its own leaves the
    /// user with no idea whether to start OBS, tick a box, or fix a password.
    public var message: String {
        switch self {
        case .notStarted: "Not connected to OBS"
        case .refused: "Waiting for OBS to start"
        case .serverDisabled: "Enable OBS → Tools → WebSocket Server Settings"
        case .authFailed: "Wrong password — fix obs.password in the config"
        case let .dropped(detail): "Reconnecting to OBS — \(detail)"
        }
    }
}

// MARK: - Target

/// A resolved Target: everything the tick loop needs except the window's current
/// position, which is deliberately absent because it is re-read every tick.
public struct Target: Equatable, Sendable {
    public let scene: SceneName
    public let itemId: SceneItemId
    public let inputName: InputName
    public let window: WindowID
    /// The owner to validate the window id against, since ids are recycled.
    public let bundleID: String?
    /// The framing as found at resolve time — the candidate Pristine.
    public let transform: Transform

    public init(
        scene: SceneName, itemId: SceneItemId, inputName: InputName,
        window: WindowID, bundleID: String?, transform: Transform
    ) {
        self.scene = scene
        self.itemId = itemId
        self.inputName = inputName
        self.window = window
        self.bundleID = bundleID
        self.transform = transform
    }

    public var pristine: Pristine {
        Pristine(scene: scene, itemId: itemId, inputName: inputName, transform: transform)
    }
}

public enum TargetState: Equatable, Sendable {
    case unresolved(UnresolvedReason)
    case resolved(Target)

    public var target: Target? {
        if case let .resolved(target) = self { return target }
        return nil
    }
}

/// Why there is nothing to zoom. Every case is something the HUD can state
/// plainly — "unresolved" on its own is useless to the user.
public enum UnresolvedReason: Equatable, Sendable {
    case notConnected
    case noCaptureInScene
    case ambiguous([InputName])
    /// The captured window is gone, or the id was recycled to another app.
    case windowGone
    case displayCaptureUnsupported
    case applicationCaptureUnsupported
    /// OBS reported a source with no usable dimensions.
    case degenerateSource

    public var message: String {
        switch self {
        case .notConnected: "Not connected to OBS"
        case .noCaptureInScene: "No screen capture in this scene"
        case let .ambiguous(names):
            "Several captures in this scene: \(names.map(\.raw).joined(separator: ", "))"
        case .windowGone: "The captured window is gone — re-pick it in OBS"
        case .displayCaptureUnsupported: "Display capture is not supported yet"
        case .applicationCaptureUnsupported: "Application capture is not supported yet"
        case .degenerateSource: "OBS reports no size for this source"
        }
    }
}

extension UnresolvedReason {
    /// Scope a core TargetError into the app's own reason type. Each layer
    /// converts rather than passing implementation errors upward.
    public init(_ error: TargetError) {
        switch error {
        case .noCaptureInScene: self = .noCaptureInScene
        case let .ambiguous(names): self = .ambiguous(names)
        case .windowNotFound: self = .windowGone
        }
    }

    /// Bindings lookit cannot zoom map to a reason that says which, so the HUD
    /// never has to show a bare failure.
    public init?(unsupported binding: CaptureBinding) {
        switch binding {
        case .window: return nil
        case .display: self = .displayCaptureUnsupported
        case .unsupported(2): self = .applicationCaptureUnsupported
        case .unsupported: self = .displayCaptureUnsupported
        }
    }
}

// MARK: - Pan

public enum PanState: Equatable, Sendable {
    /// The cursor is inside the Capture rectangle and the shot tracks it.
    case following
    /// The cursor has left the captured window; the shot holds its position.
    case frozen
}

// MARK: - Dirtiness

/// Whether lookit has altered the user's scene item.
///
/// `dirty` carries the Pristine rather than referring to one stored elsewhere,
/// so "dirty with no way back" is not a state this type can hold. That is
/// invariant 1 expressed in the type system instead of in a runtime check.
public enum Dirtiness: Equatable, Sendable {
    case clean
    case dirty(Pristine)

    public var pristine: Pristine? {
        if case let .dirty(pristine) = self { return pristine }
        return nil
    }
}
