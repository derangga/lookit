// Where the frame sits as the cursor moves. Pure — no clock, no I/O, no OBS.

/// Where the visible region should be centred, given where the cursor is.
///
/// The centre only moves once the cursor leaves the inner `deadZone` fraction of
/// the visible region, and then only by the minimum that brings it back inside.
/// Without this the shot drifts continuously under small hand movements.
///
/// - Parameter deadZone: how much of the visible region the cursor may roam
///   before the shot follows. 0 tracks the cursor exactly; 1 pans only once the
///   cursor would otherwise leave the frame entirely. It is never "no panning" —
///   at any setting the cursor is kept on screen, which is the point.
public func nextPanCenter(
    cursor: SourcePoint,
    current: SourcePoint,
    source: SourceSize,
    zoom: Double,
    deadZone: Double
) -> SourcePoint {
    let region = visibleRegion(source: source, zoom: zoom, center: current)
    let slack = clamp(deadZone, 0, 1)
    let halfX = region.size.width / 2 * slack
    let halfY = region.size.height / 2 * slack

    let cx = nudge(current.x, toward: cursor.x, slack: halfX)
    let cy = nudge(current.y, toward: cursor.y, slack: halfY)

    // Re-clamp through visibleRegion so the returned centre is always one the
    // region can actually adopt, even when the nudge pushed it past an edge.
    return visibleRegion(
        source: source,
        zoom: zoom,
        center: SourcePoint(x: cx, y: cy)
    ).center
}

private func nudge(_ current: Double, toward target: Double, slack: Double) -> Double {
    if target > current + slack { return target - slack }
    if target < current - slack { return target + slack }
    return current
}
