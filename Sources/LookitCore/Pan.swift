// Where the frame sits as the cursor moves. Pure — no clock, no I/O, no OBS.
//
// `dt` is a parameter, not a reading: this file still cannot tell the time.

// libm, not a framework. `exp` lifts to <cmath> unchanged, which is the whole
// point of invariant 5 — the core stays free of AppKit, Foundation and
// networking, and this is neither.
#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Where the visible region should be centred, given where the cursor is.
///
/// Two separable decisions, in order:
///
/// 1. **Whether** to move — the `deadZone` gives the cursor room to roam, and
///    the shot only wants to move once the cursor leaves it, then only by the
///    minimum that brings it back inside. Without this the shot drifts
///    continuously under small hand movements.
/// 2. **How fast** to get there — `rate` chases that target exponentially
///    instead of snapping to it. Without this the visible region is welded to
///    the cursor once it is outside the dead zone, and a fast flick whips the
///    shot across the source at exactly cursor speed. The lag is what makes the
///    motion read as camera work rather than as a bound viewport.
///
/// - Parameter deadZone: how much of the visible region the cursor may roam
///   before the shot follows. 0 tracks the cursor exactly; 1 pans only once the
///   cursor would otherwise leave the frame entirely. It is never "no panning" —
///   at any setting the cursor is kept on screen, which is the point.
/// - Parameter rate: how eagerly the shot closes the remaining distance, per
///   second. 0 (or non-finite) means no smoothing: land on the target this tick.
/// - Parameter dt: seconds since the last call. The caller clamps it; a stalled
///   frame must not teleport the shot.
public func nextPanCenter(
    cursor: SourcePoint,
    current: SourcePoint,
    source: SourceSize,
    zoom: Double,
    deadZone: Double,
    rate: Double,
    dt: Double
) -> SourcePoint {
    let region = visibleRegion(source: source, zoom: zoom, center: current)
    let slack = clamp(deadZone, 0, 1)
    let halfX = region.size.width / 2 * slack
    let halfY = region.size.height / 2 * slack

    let targetX = nudge(current.x, toward: cursor.x, slack: halfX)
    let targetY = nudge(current.y, toward: cursor.y, slack: halfY)

    let step = chaseFraction(rate: rate, dt: dt)
    let cx = current.x + (targetX - current.x) * step
    let cy = current.y + (targetY - current.y) * step

    // Re-clamp through visibleRegion so the returned centre is always one the
    // region can actually adopt, even when the nudge pushed it past an edge.
    return visibleRegion(
        source: source,
        zoom: zoom,
        center: SourcePoint(x: cx, y: cy)
    ).center
}

/// The fraction of the remaining distance to cover in `dt` seconds.
///
/// `1 - e^(-rate·dt)` rather than a fixed per-tick fraction, because it is the
/// one form that is **frame-rate independent**: two 16ms steps land in the same
/// place as one 33ms step. `current += remaining * 0.2` per tick does not — it
/// would make the pan twice as fast at 60Hz as at 30Hz, so the feel would drift
/// with the canvas fps.
public func chaseFraction(rate: Double, dt: Double) -> Double {
    guard rate > 0, dt > 0, rate.isFinite, dt.isFinite else { return 1 }
    return clamp(1 - exp(-rate * dt), 0, 1)
}

private func nudge(_ current: Double, toward target: Double, slack: Double) -> Double {
    if target > current + slack { return target - slack }
    if target < current - slack { return target + slack }
    return current
}
