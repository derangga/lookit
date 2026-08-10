// Choosing which scene item is the Target. Pure — asking OBS happens above.

/// Choose the Target from a scene's items.
///
/// Cameras fall out because their input kind is not a capture kind — they are
/// never matched by name (invariant 3).
/// - Parameter preferring: a choice the user already made for this scene. Only
///   consulted when there is a genuine ambiguity, and ignored when it names
///   something no longer in the scene — a stale preference must not resolve to
///   nothing, it must ask again.
public func pickCaptureItem(
    _ items: [SceneItemSummary], preferring: InputName? = nil
) throws(TargetError) -> SceneItemSummary {
    let captures = items.filter { $0.kind.isCapture }

    switch captures.count {
    case 0: throw .noCaptureInScene
    case 1: return captures[0]
    default:
        if let chosen = captures.first(where: { $0.inputName == preferring }) { return chosen }
        throw .ambiguous(captures.map(\.inputName))
    }
}
