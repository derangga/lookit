// How tightly the source is framed: visible region and the crop OBS applies.
// Pure — no clock, no I/O, no OBS. This is the part ADR 0001 keeps portable.

/// The portion of the source visible at `zoom`, centred as close to `center` as
/// the source edges allow.
///
/// Zoom below 1x is meaningless (there is nothing outside the source to show),
/// so it is clamped rather than rejected.
///
/// - Precondition: the source has positive dimensions. A zero-sized source is
///   an invariant violation — the boundary parser must reject it before here.
///   This is the one `die` in the design.
public func visibleRegion(source: SourceSize, zoom: Double, center: SourcePoint) -> SourceRegion {
    precondition(
        source.width > 0 && source.height > 0,
        "visibleRegion: non-positive source \(source) — boundary parsing let a bad Transform through"
    )

    let z = max(1.0, zoom)
    let width = source.width / z
    let height = source.height / z

    // Clamping the centre is what keeps the visible region inside the source.
    // Done here rather than at call sites so no caller can forget it.
    let cx = clamp(center.x, width / 2, source.width - width / 2)
    let cy = clamp(center.y, height / 2, source.height - height / 2)

    return SourceRegion(
        origin: SourcePoint(x: cx - width / 2, y: cy - height / 2),
        size: SourceSize(width: width, height: height)
    )
}

/// Convert a visible region into the crop insets OBS applies to the scene item.
///
/// OBS crops are whole pixels, so edges are rounded. Opposite edges are derived
/// by subtraction rather than rounded independently, which keeps
/// `left + visible + right == source.width` exactly and stops the item's aspect
/// ratio wobbling by a pixel as the region pans.
public func cropInsets(source: SourceSize, region: SourceRegion) -> CropInsets {
    let left = clamp(region.origin.x.rounded(), 0, source.width)
    let top = clamp(region.origin.y.rounded(), 0, source.height)
    let width = clamp(region.size.width.rounded(), 0, source.width - left)
    let height = clamp(region.size.height.rounded(), 0, source.height - top)

    return CropInsets(
        left: left,
        top: top,
        right: source.width - left - width,
        bottom: source.height - top - height
    )
}

/// `visibleRegion` then `cropInsets` — the pair the tick loop actually wants.
public func zoomCrop(source: SourceSize, zoom: Double, center: SourcePoint)
    -> (region: SourceRegion, crop: CropInsets)
{
    let region = visibleRegion(source: source, zoom: zoom, center: center)
    return (region, cropInsets(source: source, region: region))
}

@inline(__always)
func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
    // A degenerate range (high < low) collapses to low rather than producing a
    // nonsense value — happens when the visible region equals the whole source.
    if high < low { return low }
    return min(max(value, low), high)
}
