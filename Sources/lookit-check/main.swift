// Assert-based self-check for the pure core. No framework, no fixtures.
//
//     swift run lookit-check
//
// Depends only on LookitCore, which is also how we prove the core has no
// hidden dependencies (DESIGN.md §9).

import CoreGraphics
import Darwin
import Foundation
import Lookit
import LookitCore

var failures = 0

// @MainActor because top-level code is main-actor isolated under Swift 6, and
// these touch the `failures` counter that lives there.
@MainActor
func expect(_ condition: Bool, _ what: String) {
    if condition {
        print("  ok   \(what)")
    } else {
        print("  FAIL \(what)")
        failures += 1
    }
}

@MainActor
func expect(_ actual: Double, _ expected: Double, _ what: String, tolerance: Double = 0.0001) {
    expect(abs(actual - expected) < tolerance, "\(what)  (got \(actual), want \(expected))")
}

// Roughly a Retina browser window: 1470x956 points at 2x.
let source = SourceSize(width: 2940, height: 1912)

// MARK: - zoomCrop

print("zoomCrop")

do {
    let (region, crop) = zoomCrop(
        source: source, zoom: 1.0,
        center: SourcePoint(x: 1470, y: 956)
    )
    expect(crop == .zero, "1x crops nothing")
    expect(region.size.width, 2940, "1x shows the whole width")
}

do {
    let (_, crop) = zoomCrop(source: source, zoom: 2.0, center: SourcePoint(x: 1470, y: 956))
    expect(crop.left, 735, "2x centred trims a quarter off the left")
    expect(crop.left, crop.right, "2x centred is symmetric horizontally")
    expect(crop.top, crop.bottom, "2x centred is symmetric vertically")
}

do {
    // Centre pinned to the top-left corner: the region must clamp, not overhang.
    let (region, crop) = zoomCrop(source: source, zoom: 3.0, center: SourcePoint(x: 0, y: 0))
    expect(region.origin.x, 0, "centre past the left edge clamps to 0")
    expect(region.origin.y, 0, "centre past the top edge clamps to 0")
    expect(crop.left, 0, "no left crop at the left edge")
    expect(crop.right, 1960, "the rest is cropped off the right")
}

do {
    let (region, _) = zoomCrop(
        source: source, zoom: 3.0,
        center: SourcePoint(x: 99_999, y: 99_999)
    )
    expect(region.origin.x + region.size.width, 2940, "centre past the right edge clamps flush")
    expect(region.origin.y + region.size.height, 1912, "centre past the bottom edge clamps flush")
}

do {
    expect(
        zoomCrop(source: source, zoom: 0.25, center: SourcePoint(x: 1470, y: 956)).crop == .zero,
        "zoom below 1x clamps to 1x rather than showing nothing"
    )
}

do {
    // Odd dimensions: opposite edges are derived by subtraction, so the sum must
    // land exactly on the source size with no aspect wobble.
    let odd = SourceSize(width: 2941, height: 1913)
    let (_, crop) = zoomCrop(source: odd, zoom: 3.0, center: SourcePoint(x: 1470.5, y: 956.5))
    let spannedWidth = crop.left + crop.right + (odd.width - crop.left - crop.right)
    expect(spannedWidth, 2941, "crops sum exactly to the source width")
    expect(crop.left == crop.left.rounded(), "crop values are whole pixels")
    expect(crop.right >= 0 && crop.bottom >= 0, "crops never go negative")
}

// MARK: - Dead zone

print("nextPanCenter")

let square = SourceSize(width: 1000, height: 1000)

do {
    // At 2x the visible region is 500 wide, so a 0.6 dead zone gives 150 slack.
    let center = SourcePoint(x: 500, y: 500)
    let held = nextPanCenter(
        cursor: SourcePoint(x: 600, y: 500), current: center,
        source: square, zoom: 2.0, deadZone: 0.6
    )
    expect(held.x, 500, "cursor inside the dead zone does not pan")
}

do {
    let moved = nextPanCenter(
        cursor: SourcePoint(x: 700, y: 500), current: SourcePoint(x: 500, y: 500),
        source: square, zoom: 2.0, deadZone: 0.6
    )
    expect(moved.x, 550, "cursor past the dead zone pans by the minimum")
}

do {
    let clamped = nextPanCenter(
        cursor: SourcePoint(x: 990, y: 500), current: SourcePoint(x: 500, y: 500),
        source: square, zoom: 2.0, deadZone: 0.6
    )
    expect(clamped.x, 750, "panning stops at the source edge instead of overshooting")
}

do {
    let always = nextPanCenter(
        cursor: SourcePoint(x: 510, y: 500), current: SourcePoint(x: 500, y: 500),
        source: square, zoom: 2.0, deadZone: 0.0
    )
    expect(always.x, 510, "deadZone 0 tracks the cursor exactly")

    // deadZone 1 lets the cursor roam the whole visible region (250...750 here)
    // without the shot moving, but it still pans rather than letting the cursor
    // leave the frame.
    let roaming = nextPanCenter(
        cursor: SourcePoint(x: 700, y: 500), current: SourcePoint(x: 500, y: 500),
        source: square, zoom: 2.0, deadZone: 1.0
    )
    expect(roaming.x, 500, "deadZone 1 holds while the cursor is anywhere in frame")

    let escaping = nextPanCenter(
        cursor: SourcePoint(x: 900, y: 500), current: SourcePoint(x: 500, y: 500),
        source: square, zoom: 2.0, deadZone: 1.0
    )
    expect(escaping.x, 650, "deadZone 1 still pans to keep the cursor from leaving frame")
}

do {
    // Hysteresis: having panned, coming back a little must not pan back.
    let after = nextPanCenter(
        cursor: SourcePoint(x: 690, y: 500), current: SourcePoint(x: 550, y: 500),
        source: square, zoom: 2.0, deadZone: 0.6
    )
    expect(after.x, 550, "small reverse movement inside the dead zone holds")
}

// MARK: - Cursor mapping

print("mapCursorToSource")

let rect = CaptureRect(x: 100, y: 50, width: 1470, height: 956, scale: 2.0)

do {
    let inside = mapCursorToSource(cursor: ScreenPoint(x: 200, y: 150), rect: rect)
    expect(inside?.x ?? -1, 200, "points scale by the backing factor")
    expect(inside?.y ?? -1, 200, "origin is subtracted before scaling")

    expect(
        mapCursorToSource(cursor: ScreenPoint(x: 100, y: 50), rect: rect)
            == SourcePoint(x: 0, y: 0),
        "top-left corner maps to the source origin"
    )
    expect(
        mapCursorToSource(cursor: ScreenPoint(x: 1570, y: 1006), rect: rect)
            == SourcePoint(x: 2940, y: 1912),
        "bottom-right corner maps to the full source size"
    )
    expect(rect.sourceSize == SourceSize(width: 2940, height: 1912), "sourceSize applies scale")
}

do {
    expect(
        mapCursorToSource(cursor: ScreenPoint(x: 99, y: 150), rect: rect) == nil,
        "cursor left of the window is Frozen, not an error"
    )
    expect(
        mapCursorToSource(cursor: ScreenPoint(x: 2000, y: 150), rect: rect) == nil,
        "cursor right of the window is Frozen"
    )
    expect(
        mapCursorToSource(cursor: ScreenPoint(x: 200, y: 49), rect: rect) == nil,
        "cursor above the window is Frozen"
    )
}

// MARK: - Stops and easing

print("nextStop / eased")

let stops = [1.0, 1.5, 2.0, 3.0]

do {
    expect(nextStop(stops: stops, from: 1.0, direction: 1), 1.5, "in from 1x")
    expect(nextStop(stops: stops, from: 2.0, direction: 1), 3.0, "in from 2x")
    expect(nextStop(stops: stops, from: 3.0, direction: 1), 3.0, "in at max holds")
    expect(nextStop(stops: stops, from: 1.0, direction: -1), 1.0, "out at min holds")
    expect(nextStop(stops: stops, from: 3.0, direction: -1), 2.0, "out from max")
    // Mid-animation: advance from where the zoom actually is.
    expect(nextStop(stops: stops, from: 1.7, direction: 1), 2.0, "in from mid-animation")
    expect(nextStop(stops: stops, from: 1.7, direction: -1), 1.5, "out from mid-animation")
    expect(nextStop(stops: [], from: 2.0, direction: 1), 2.0, "empty stops is a no-op")
}

do {
    expect(eased(from: 1.0, to: 3.0, progress: 0), 1.0, "ease starts at from")
    expect(eased(from: 1.0, to: 3.0, progress: 1), 3.0, "ease ends at to")
    expect(eased(from: 1.0, to: 3.0, progress: 0.5), 2.0, "ease is symmetric at the midpoint")
    expect(eased(from: 1.0, to: 3.0, progress: 5), 3.0, "overrunning the duration lands on to")
    expect(eased(from: 1.0, to: 3.0, progress: -1), 1.0, "negative progress lands on from")
}

// MARK: - Target selection

print("pickCaptureItem")

let camera = SceneItemSummary(
    id: SceneItemId(1), inputName: InputName("camera"), kind: InputKind("macos-avcapture")
)
let browser = SceneItemSummary(
    id: SceneItemId(2), inputName: InputName("chrome"), kind: InputKind("screen_capture")
)
let terminal = SceneItemSummary(
    id: SceneItemId(3), inputName: InputName("terminal"), kind: InputKind("screen_capture")
)

do {
    let picked = try pickCaptureItem([browser, camera])
    expect(picked.inputName == InputName("chrome"), "the camera is excluded by kind")
} catch {
    expect(false, "picking from a normal scene should not throw (got \(error))")
}

do {
    _ = try pickCaptureItem([camera])
    expect(false, "a camera-only scene should throw")
} catch {
    expect(error == .noCaptureInScene, "camera-only scene is noCaptureInScene")
}

do {
    _ = try pickCaptureItem([browser, terminal, camera])
    expect(false, "two captures should throw")
} catch {
    expect(
        error == .ambiguous([InputName("chrome"), InputName("terminal")]),
        "two captures is ambiguous, listing only the captures"
    )
}

// MARK: - Window bounds boundary

print("captureRect(fromBounds:)")

do {
    let bounds: [String: Any] = ["X": 100.0, "Y": 50.0, "Width": 1470.0, "Height": 956.0]
    let parsed = captureRect(fromBounds: bounds, scale: 2.0)
    expect(parsed?.x ?? -1, 100, "X passes through as top-left global points")
    expect(parsed?.sourceSize.width ?? -1, 2940, "scale is applied to reach source pixels")
}

do {
    // Every one of these must be rejected here, because visibleRegion treats a
    // degenerate source as a die rather than a domain error.
    expect(
        captureRect(fromBounds: ["X": 0.0, "Y": 0.0, "Width": 0.0, "Height": 956.0], scale: 2)
            == nil,
        "zero width is rejected at the boundary"
    )
    expect(
        captureRect(fromBounds: ["X": 0.0, "Y": 0.0, "Width": 100.0, "Height": -5.0], scale: 2)
            == nil,
        "negative height is rejected at the boundary"
    )
    expect(
        captureRect(fromBounds: ["X": 0.0, "Y": 0.0, "Width": 100.0, "Height": 50.0], scale: 0)
            == nil,
        "a zero backing scale is rejected"
    )
    expect(
        captureRect(fromBounds: ["X": 0.0, "Width": 100.0, "Height": 50.0], scale: 2) == nil,
        "a missing key is rejected rather than defaulted"
    )
    expect(
        captureRect(fromBounds: ["X": "100", "Y": 0.0, "Width": 100.0, "Height": 50.0], scale: 2)
            == nil,
        "a wrongly typed value is rejected"
    )
}

do {
    // Window ids are recycled: id 384 was stored against com.google.Chrome and
    // resolved to a live Helium window. Ownership must be checked, or lookit
    // frames the wrong app with no error at all.
    let info: [String: Any] = [kCGWindowOwnerPID as String: pid_t(742)]
    let asHelium: (pid_t) -> String? = { _ in "net.imput.helium" }

    expect(
        ownerMatches(info, expected: "net.imput.helium", resolveBundleID: asHelium),
        "a window owned by the expected app matches"
    )
    expect(
        !ownerMatches(info, expected: "com.google.Chrome", resolveBundleID: asHelium),
        "a recycled id owned by another app is rejected"
    )
    expect(
        !ownerMatches(info, expected: "com.google.Chrome", resolveBundleID: { _ in nil }),
        "a dead pid is rejected rather than treated as a match"
    )
    expect(
        !ownerMatches([:], expected: "com.google.Chrome", resolveBundleID: asHelium),
        "a window with no owner pid is rejected"
    )
    expect(
        ownerMatches([:], expected: nil, resolveBundleID: asHelium),
        "no expectation means no check"
    )
}

do {
    expect(WindowLocator.missing.locate(WindowID(1)) == nil, "the missing locator resolves nothing")
    let fixed = WindowLocator.fixed(
        CaptureRect(x: 0, y: 0, width: 100, height: 100, scale: 2)
    )
    expect(fixed.locate(WindowID(999))?.scale ?? 0, 2, "the fixed locator ignores the id")
}

// MARK: - Keybinding boundary

print("parseKeybinding")

do {
    expect(
        parseKeybinding("cmd+opt+=") == Keybinding(keyCode: 24, modifiers: 2304),
        "cmd+opt+= parses to the = keycode with both modifiers"
    )
    expect(parseKeybinding("CMD+OPT+0") == parseKeybinding("cmd+opt+0"), "case does not matter")
    expect(parseKeybinding("⌘+⌥+0") == parseKeybinding("cmd+opt+0"), "symbols work too")
    expect(parseKeybinding(" cmd + opt + 0 ") == parseKeybinding("cmd+opt+0"), "spaces are trimmed")
    expect(parseKeybinding("cmd+opt++")?.keyCode == 24, "a trailing + is the plus key")
    expect(parseKeybinding("ctrl+shift+up") != nil, "named keys and arrows work")

    expect(parseKeybinding("cmd+opt+£") == nil, "an unknown key is rejected")
    expect(parseKeybinding("hyper+z") == nil, "an unknown modifier is rejected")
    expect(parseKeybinding("z") == nil, "a global hotkey with no modifier is rejected")
    expect(parseKeybinding("") == nil, "empty is rejected")
}

// MARK: - Config boundary

print("Config")

do {
    let json = Data(#"{"easeMs": 200}"#.utf8)
    let parsed = try? JSONDecoder().decode(Config.self, from: json)
    expect(parsed?.easeMs == 200, "a present key is used")
    expect(parsed?.deadZone == 0.6, "a missing key falls back to its default")
    expect(parsed?.keys.zoomIn == "cmd+opt+=", "a missing nested object falls back whole")
}

do {
    let json = Data(#"{"easeMs": "fast"}"#.utf8)
    expect(
        (try? JSONDecoder().decode(Config.self, from: json)) == nil,
        "a wrongly typed key is an error, not a silent default"
    )
}

do {
    var config = Config.fallback
    config.stops = [3.0, 1.0, 0.2, 2.0]
    config.easeMs = 99_999
    config.deadZone = 4.2
    config.obs.port = 0
    let (fixed, warnings) = validated(config)

    expect(fixed.stops == [1.0, 2.0, 3.0], "stops are sorted and sub-1x entries dropped")
    expect(fixed.easeMs == 5000, "easeMs is clamped, not rejected")
    expect(fixed.deadZone == 1.0, "deadZone is clamped to 0...1")
    expect(fixed.obs.port == 4455, "an invalid port falls back to the default")
    expect(warnings.count == 4, "every clamp produces a warning the HUD can show")
}

do {
    var config = Config.fallback
    config.stops = [0.5, 0.9]
    let (fixed, warnings) = validated(config)
    expect(fixed.stops == Config.fallback.stops, "an entirely unusable stops list falls back")
    expect(warnings.first?.key == "stops", "and says so")
}

do {
    let (config, warnings) = validated(Config.fallback)
    expect(config == Config.fallback, "the defaults survive validation unchanged")
    expect(warnings.isEmpty, "the defaults produce no warnings")
}

do {
    var keys = Config.Keys(zoomIn: "cmd+opt+=", zoomOut: "nonsense", reset: "cmd+opt+0")
    var parsed = keybindings(from: keys)
    expect(parsed.zoomIn != nil, "a good binding survives a bad sibling")
    expect(parsed.zoomOut == nil, "the bad binding is dropped")
    expect(parsed.reset != nil, "one typo does not disable the others")
    expect(parsed.warnings.count == 1, "and produces exactly one warning")

    keys = Config.fallback.keys
    parsed = keybindings(from: keys)
    expect(parsed.warnings.isEmpty, "the default bindings all parse")
}

do {
    // Round-trip the file that first run actually writes.
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "lookit-check-\(UUID().uuidString)/config.json")
    defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }

    let store = ConfigStore.live(path: tmp)
    expect(store.load() == .seeded(.fallback), "a missing file seeds defaults rather than failing")
    expect(
        FileManager.default.fileExists(atPath: tmp.path(percentEncoded: false)),
        "and the complete default file is written"
    )
    expect(store.load() == .loaded(.fallback, []), "the written file reads back identically")

    try? Data("{ not json".utf8).write(to: tmp)
    if case .rejected = store.load() {
        expect(true, "malformed JSON is rejected so the caller keeps last-good")
    } else {
        expect(false, "malformed JSON must be rejected")
    }
}

// MARK: -

print("")
if failures == 0 {
    print("all checks passed")
} else {
    print("\(failures) check(s) FAILED")
    exit(1)
}
