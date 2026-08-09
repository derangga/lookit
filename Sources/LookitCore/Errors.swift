// §1 Shapes — the E channel for anything the pure core can produce.
//
// Errors are tagged values carrying context, never strings. Layers above scope
// these into their own error types before passing them outward.

/// Why a Target could not be established.
///
/// Every case here is an *escape*, not a die: the app degrades to Unresolved,
/// refuses to zoom, and says why in the HUD.
public enum TargetError: Error, Equatable, Sendable {
    /// The active scene contains no screen capture at all.
    case noCaptureInScene

    /// More than one capture is eligible, so the choice is the user's.
    case ambiguous([InputName])

    /// The captured window no longer exists on screen.
    case windowNotFound(WindowID)
}
