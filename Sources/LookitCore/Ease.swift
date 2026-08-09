// Movement between zoom stops. Pure — no clock; the caller owns elapsed time.

/// Smoothstep: eases in and out, zero derivative at both ends. `progress` is
/// clamped, so a caller that overruns the duration lands exactly on `to`.
public func eased(from: Double, to: Double, progress: Double) -> Double {
    let t = clamp(progress, 0, 1)
    return from + (to - from) * (t * t * (3 - 2 * t))
}

/// The next configured stop in `direction` (+1 in, -1 out).
///
/// Works off the *current value* rather than an index, so pressing the hotkey
/// mid-animation advances from where the zoom actually is instead of snapping
/// back to the stop it was heading for.
public func nextStop(stops: [Double], from current: Double, direction: Int) -> Double {
    let sorted = stops.sorted()
    guard let lowest = sorted.first, let highest = sorted.last else { return current }

    // Tolerance keeps a value sitting exactly on a stop from being considered
    // "past" it by a rounding hair.
    let epsilon = 0.001

    if direction > 0 {
        return sorted.first(where: { $0 > current + epsilon }) ?? highest
    } else if direction < 0 {
        return sorted.last(where: { $0 < current - epsilon }) ?? lowest
    }
    return current
}
