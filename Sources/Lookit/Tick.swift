// §2 Tick — one frame of the core loop.
//
// The geometry here is pure and the clock is not: the caller owns elapsed time
// and calls `framing` once per tick with whatever the cursor and window server
// said. That split is what makes the loop checkable without a screen.

import AppKit
import LookitCore

/// One tick's answer: where the shot sits and how the item must be cropped.
public struct Framing: Equatable, Sendable {
    public let center: SourcePoint
    public let crop: CropInsets
    public let pan: PanState
}

/// `mapCursorToSource` → `nextPanCenter` → `zoomCrop`, in one place.
///
/// A cursor outside the captured window is **not** an error — it is the Frozen
/// state. The shot holds its last position rather than snapping to an edge,
/// which is what makes reaching for the HUD or another display bearable.
public func framing(
    cursor: ScreenPoint,
    rect: CaptureRect,
    source: SourceSize,
    zoom: Double,
    center: SourcePoint,
    deadZone: Double
) -> Framing {
    guard let inSource = mapCursorToSource(cursor: cursor, rect: rect) else {
        return Framing(
            center: center,
            crop: zoomCrop(source: source, zoom: zoom, center: center).crop,
            pan: .frozen
        )
    }

    let next = nextPanCenter(
        cursor: inSource, current: center, source: source, zoom: zoom, deadZone: deadZone
    )
    return Framing(
        center: next,
        crop: zoomCrop(source: source, zoom: zoom, center: next).crop,
        pan: .following
    )
}

/// The pristine transform with lookit's crop applied.
///
/// Bounds are forced on when the item has none, because cropping an unbounded
/// item *shrinks* it on canvas — the user's layout would visibly jump. With
/// bounds, the cropped content is scaled back into the rectangle they arranged,
/// which is the whole illusion: the frame stays put and the content zooms.
public func reframed(_ transform: Transform, crop: CropInsets) -> Transform {
    var reframed = transform
    reframed.cropLeft = crop.left
    reframed.cropTop = crop.top
    reframed.cropRight = crop.right
    reframed.cropBottom = crop.bottom

    if transform.boundsType == "OBS_BOUNDS_NONE"
        || transform.boundsWidth <= 0 || transform.boundsHeight <= 0
    {
        let display = transform.displaySize
        reframed.boundsType = "OBS_BOUNDS_SCALE_INNER"
        reframed.boundsWidth = display.width
        reframed.boundsHeight = display.height
    }
    return reframed
}

/// Where the cursor is, in the top-left screen space the core works in.
///
/// AppKit reports bottom-left from the primary display; everything below this
/// line assumes top-left, so the flip happens exactly once, here.
public func cursorPosition() -> ScreenPoint {
    let point = NSEvent.mouseLocation
    let primary = NSScreen.screens.first?.frame.maxY ?? 0
    return ScreenPoint(x: point.x, y: primary - point.y)
}
