// §7 behavior: coalesce ⟳ setSceneItemTransform.
//
// Wraps the send without changing the graph — the tick loop still just says
// "put the item here" 30 times a second and never waits for OBS.

import Foundation
import LookitCore

/// Keeps at most one transform in flight and at most one waiting behind it,
/// and drops a frame identical to the one OBS already has.
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
    /// What OBS was last told, so a repeat can be dropped. Only ever set from
    /// `post`, so `reset` is what keeps it honest when someone else writes.
    private var lastPosted: SetSceneItemTransformRequest?

    /// The last thing OBS refused, for whoever wants to show it. Not thrown:
    /// the tick loop has nothing useful to do with a failed frame, and the next
    /// tick resends the current position anyway.
    public private(set) var lastFailure: ObsError?

    public init(send: @escaping (SetSceneItemTransformRequest) async throws(ObsError) -> Void) {
        self.send = send
    }

    /// Post a frame. Returns immediately — the 30Hz loop must never wait on OBS.
    ///
    /// Crops are whole pixels, so a still cursor, a cursor inside the dead zone
    /// and a frozen shot all produce the identical request 30 times a second.
    /// OBS already has that frame. A frame that *failed* is not identical in
    /// the sense that matters — OBS never got it — so it is always resent.
    public func post(_ request: SetSceneItemTransformRequest) {
        guard request != lastPosted || lastFailure != nil else { return }
        lastPosted = request
        pending = request
        guard !inFlight else { return }
        inFlight = true
        Task { [weak self] in await self?.drain() }
    }

    /// Whether a frame is on the wire or waiting to be. Exists so the check can
    /// see the coalescing happen.
    public var isIdle: Bool { !inFlight && pending == nil }

    /// Forget what OBS was last told.
    ///
    /// **Required, not housekeeping.** Dropping repeats assumes this sender is
    /// the only writer of the item's transform, and it is not: `DirtyScope`
    /// restores the pristine on release, straight past here. Without this, a
    /// zoom to 2×, a release, and a second zoom to 2× would post the same crop
    /// twice with a restore in between — and the second one would be dropped as
    /// a duplicate of a frame OBS no longer has.
    public func reset() {
        lastPosted = nil
    }

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
