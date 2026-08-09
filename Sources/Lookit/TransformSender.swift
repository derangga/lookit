// §7 behavior: coalesce ⟳ setSceneItemTransform.
//
// Wraps the send without changing the graph — the tick loop still just says
// "put the item here" 30 times a second and never waits for OBS.

import Foundation
import LookitCore

/// Keeps at most one transform in flight and at most one waiting behind it.
///
/// A round-trip to OBS can outlast a 33ms tick. Queueing every frame would let
/// the backlog grow without bound and leave the shot chasing a position the
/// cursor left long ago; the fix is to keep only the newest.
@MainActor
public final class TransformSender {
    private let send: (SetSceneItemTransformRequest) async throws(ObsError) -> Void
    private var inFlight = false
    /// The newest frame not yet sent. Overwritten rather than appended: an
    /// older frame waiting behind an in-flight one is already wrong.
    private var pending: SetSceneItemTransformRequest?

    /// The last thing OBS refused, for whoever wants to show it. Not thrown:
    /// the tick loop has nothing useful to do with a failed frame, and the next
    /// tick resends the current position anyway.
    public private(set) var lastFailure: ObsError?

    public init(send: @escaping (SetSceneItemTransformRequest) async throws(ObsError) -> Void) {
        self.send = send
    }

    /// Post a frame. Returns immediately — the 30Hz loop must never wait on OBS.
    public func post(_ request: SetSceneItemTransformRequest) {
        pending = request
        guard !inFlight else { return }
        inFlight = true
        Task { [weak self] in await self?.drain() }
    }

    /// Whether a frame is on the wire or waiting to be. Exists so the check can
    /// see the coalescing happen.
    public var isIdle: Bool { !inFlight && pending == nil }

    private func drain() async {
        // Loops rather than sending once: a frame posted while this one was on
        // the wire must still reach OBS, or the last frame of an ease — the one
        // that settles the shot on target — would be the one dropped.
        while let next = pending {
            pending = nil
            do {
                try await send(next)
                lastFailure = nil
            } catch {
                lastFailure = error
            }
        }
        inFlight = false
    }
}
