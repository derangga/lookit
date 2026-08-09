// §6 Boundary: CGWindowList dict -> CaptureRect.
//
// R = WindowLocator. A struct of closures rather than a protocol, so tests swap
// the implementation without a second conforming type existing (DESIGN.md §9).

import AppKit
import LookitCore

public struct WindowLocator: Sendable {
    public var locate: @Sendable (WindowID) -> CaptureRect?

    public init(locate: @escaping @Sendable (WindowID) -> CaptureRect?) {
        self.locate = locate
    }
}

extension WindowLocator {
    /// Asks the window server where a window is, every tick.
    ///
    /// Needs no TCC permission: only window *titles* are withheld without
    /// Screen Recording, and bounds are not a title.
    public static let live = WindowLocator { id in
        guard
            let infos = CGWindowListCopyWindowInfo(.optionIncludingWindow, id.raw)
                as? [[String: Any]],
            let bounds = infos.first?[kCGWindowBounds as String] as? [String: Any]
        else { return nil }

        return captureRect(fromBounds: bounds, scale: backingScale(forBounds: bounds))
    }

    /// A window that is always exactly here. For tests and for reasoning about
    /// the tick loop without a window server.
    public static func fixed(_ rect: CaptureRect) -> WindowLocator {
        WindowLocator { _ in rect }
    }

    /// A window that no longer exists — drives the Unresolved path.
    public static let missing = WindowLocator { _ in nil }
}

// MARK: - Parsing

/// `kCGWindowBounds` -> `CaptureRect`.
///
/// The dict is already in top-left global points, which is the convention
/// `CaptureRect` uses, so no flipping happens here.
///
/// Rejects non-positive dimensions. That rejection is what lets `visibleRegion`
/// treat a zero-sized source as a die rather than a domain error: a degenerate
/// window can never get past this point.
public func captureRect(fromBounds bounds: [String: Any], scale: Double) -> CaptureRect? {
    guard
        let x = bounds["X"] as? Double,
        let y = bounds["Y"] as? Double,
        let width = bounds["Width"] as? Double,
        let height = bounds["Height"] as? Double,
        width > 0, height > 0, scale > 0
    else { return nil }

    return CaptureRect(x: x, y: y, width: width, height: height, scale: scale)
}

/// The backing scale of whichever display the window is on, so a window dragged
/// between a Retina and a non-Retina display keeps mapping correctly.
///
/// Falls back to the main display's scale when the window's origin is not on any
/// screen — which happens while a window is mid-drag between displays.
func backingScale(forBounds bounds: [String: Any]) -> Double {
    let fallback = NSScreen.main?.backingScaleFactor ?? 2.0

    guard
        let x = bounds["X"] as? Double,
        let y = bounds["Y"] as? Double,
        let primary = NSScreen.screens.first
    else { return Double(fallback) }

    // NSScreen works bottom-left from the primary display; kCGWindowBounds is
    // top-left. Flip the window's origin before asking which screen holds it.
    let flippedY = primary.frame.maxY - y

    let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: x, y: flippedY)) }
    return Double(screen?.backingScaleFactor ?? fallback)
}
