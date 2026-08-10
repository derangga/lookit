// Invariant 1 and invariant 2, made structural.
//
// Invariant 1 — no journal, no zoom — because `acquire` is the only way to
// become dirty and it writes the journal before it returns.
// Invariant 2 — at most one dirty scene item, ever — because this holds one
// Dirtiness, and `Dirtiness.dirty` cannot exist without its Pristine.

import Foundation
import LookitCore

@MainActor
public final class DirtyScope {
    public private(set) var state: Dirtiness = .clean

    private let journal: JournalStore
    private let apply: (Pristine) async throws(ObsError) -> Void

    public init(
        journal: JournalStore,
        apply: @escaping (Pristine) async throws(ObsError) -> Void
    ) {
        self.journal = journal
        self.apply = apply
    }

    public var isDirty: Bool { state.pristine != nil }

    /// Take the scope: record the pristine framing, durably, before anything is
    /// reframed. Throwing here means nothing was touched.
    ///
    /// **Idempotent, and that is not a nicety.** A second acquire after a zoom
    /// would journal the *cropped* transform as if it were pristine, and the
    /// user's real layout would be gone with no record of it anywhere.
    @discardableResult
    public func acquire(_ target: Target) throws(JournalError) -> Pristine {
        if case let .dirty(pristine) = state { return pristine }

        let pristine = target.pristine
        try journal.write(pristine)
        state = .dirty(pristine)
        return pristine
    }

    /// Give it back: restore the pristine framing, then forget it.
    ///
    /// Called on scene switch, reset, quit and error — the five exit paths the
    /// bead names — so it must be safe to call when already clean.
    ///
    /// Reuses the launch-time restore rather than repeating it: releasing a
    /// live scope and recovering from a crashed run are the same operation, and
    /// reading the journal back from disk restores what was *durably* recorded
    /// rather than what memory thinks it was.
    public func release() async throws(RestoreError) {
        guard isDirty else { return }
        try await restoreJournalIfPresent(journal: journal, apply: apply)
        // Only on success. A scope that failed to restore is still dirty, and
        // its journal is still on disk for the next attempt or the next launch.
        state = .clean
    }
}
