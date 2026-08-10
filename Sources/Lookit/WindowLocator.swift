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
    ///
    /// - Parameter bundleID: the application the window is expected to belong
    ///   to, as reported by `windowOwner` at resolve time. **Never OBS's
    ///   `application` field**, which is vestigial and would reject the correct
    ///   window. **Not optional in spirit** — macOS recycles window ids, so an
    ///   id alone can resolve to a different app's window and lookit would
    ///   frame the wrong thing silently. Passing nil skips the check and
    ///   accepts that risk; only do so when the id was resolved moments ago.
    public static func live(expecting bundleID: String?) -> WindowLocator {
        WindowLocator { id in
            guard
                let infos = CGWindowListCopyWindowInfo(.optionIncludingWindow, id.raw)
                    as? [[String: Any]],
                let info = infos.first,
                let bounds = info[kCGWindowBounds as String] as? [String: Any],
                ownerMatches(info, expected: bundleID, resolveBundleID: bundleID(forPID:))
            else { return nil }

            return captureRect(fromBounds: bounds, scale: backingScale(forBounds: bounds))
        }
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

// MARK: - Resolving a window id

/// Whether the window at `id` is plausibly the one OBS is capturing.
///
/// OBS keeps the source's pixel size honest — a dead capture reports 0×0 — but
/// its saved window id can be stale, and a stale id names someone else's
/// window rather than failing. Comparing the window's backing-pixel size to the
/// size OBS reports is the only cross-check available: window *titles* would
/// need Screen Recording, and the whole design turns on needing no TCC.
///
/// ponytail: two same-sized windows are indistinguishable this way. The per-tick
/// owner check catches the case that actually happens — the captured app quits
/// mid-session — and a re-resolve on the next scene change corrects the rest.
public func matchesSource(_ rect: CaptureRect, _ source: SourceSize, tolerance: Double = 2) -> Bool {
    abs(rect.sourceSize.width - source.width) <= tolerance
        && abs(rect.sourceSize.height - source.height) <= tolerance
}

/// Who owns this window, according to the window server.
///
/// This — never OBS's `application` field — is the value to validate against on
/// later ticks. Measured: after re-picking a Helium window, OBS still reported
/// `com.google.Chrome` while the window server correctly said `net.imput.helium`.
public func windowOwner(_ id: WindowID) -> String? {
    guard
        let infos = CGWindowListCopyWindowInfo(.optionIncludingWindow, id.raw) as? [[String: Any]],
        let pid = infos.first?[kCGWindowOwnerPID as String] as? pid_t
    else { return nil }
    return bundleID(forPID: pid)
}

/// Whether a window still belongs to the application lookit thinks it does.
///
/// Window ids are recycled by the window server: an id captured from OBS's
/// settings can, after an app relaunch, name a live window owned by something
/// else entirely. Verified in the wild — id 384 was stored against
/// `com.google.Chrome` and resolved to a Helium window.
///
/// `resolveBundleID` is injected so this is testable without spawning processes.
public func ownerMatches(
    _ info: [String: Any],
    expected bundleID: String?,
    resolveBundleID: (pid_t) -> String?
) -> Bool {
    guard let expected = bundleID else { return true }

    guard let pid = info[kCGWindowOwnerPID as String] as? pid_t else { return false }

    return resolveBundleID(pid) == expected
}

func bundleID(forPID pid: pid_t) -> String? {
    NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
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
