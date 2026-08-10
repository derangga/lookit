// Invariant 1's other half.
//
// Writing the journal makes the layout recoverable; this is what recovers it.
// A journal on disk at launch means the previous run died dirty and the user's
// scene item is still wrong.

import Foundation
import LookitCore

public enum RestoreError: Error, Equatable, Sendable {
    /// A journal exists but cannot be read. Still on disk — it is the only
    /// record of the layout, unreadable by us or not.
    case unreadable(String)
    /// OBS would not apply it. Still on disk, so the next launch tries again.
    case refused(String)
    /// Applied, but the file could not be removed. The layout is already back;
    /// the only cost is that the next launch applies the same transform again.
    case notCleared(String)

    public var message: String {
        switch self {
        case let .unreadable(detail): "Cannot read the saved layout — \(detail)"
        case let .refused(detail): "Could not restore your layout — \(detail)"
        case let .notCleared(detail): "Layout restored, but the journal remains — \(detail)"
        }
    }

    /// Scope the layers below into this one's vocabulary. Which journal step
    /// failed is recoverable from the case, so the caller never sees a
    /// JournalError or an ObsError.
    init(_ error: any Error) {
        switch error {
        case let journal as JournalError:
            switch journal {
            case let .corrupt(detail): self = .unreadable(detail)
            case let .deleteFailed(detail): self = .notCleared(detail)
            // Restore neither writes a journal nor holds a scope, so neither of
            // these can arrive here.
            case let .writeFailed(detail): self = .refused(detail)
            case let .stillHeld(name): self = .refused("still holding \(name.raw)")
            }
        case let obs as ObsError:
            self = .refused(DisconnectReason(obs).message)
        default:
            self = .refused(String(describing: error))
        }
    }
}

/// Put the user's framing back, then forget it.
///
/// `apply` is R: the one thing this needs from the outside world. A parameter
/// rather than the connection itself, so the order below — delete strictly
/// after OBS confirms — is checkable without a socket.
@MainActor
public func restoreJournalIfPresent(
    journal: JournalStore,
    apply: (Pristine) async throws(ObsError) -> Void
) async throws(RestoreError) {
    do {
        guard let pristine = try journal.read() else { return }
        try await apply(pristine)
        // Only now. A journal deleted before OBS confirmed would leave the
        // layout wrong with nothing left to fix it from.
        try journal.delete()
    } catch {
        throw RestoreError(error)
    }
}
