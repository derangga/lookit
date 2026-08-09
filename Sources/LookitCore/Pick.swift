// Choosing which scene item is the Target. Pure — asking OBS happens above.

/// Choose the Target from a scene's items.
///
/// Cameras fall out because their input kind is not a capture kind — they are
/// never matched by name (invariant 3).
public func pickCaptureItem(_ items: [SceneItemSummary]) throws(TargetError) -> SceneItemSummary {
    let captures = items.filter { $0.kind.isCapture }

    switch captures.count {
    case 0: throw .noCaptureInScene
    case 1: return captures[0]
    default: throw .ambiguous(captures.map(\.inputName))
    }
}
