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

    // JSON has no comments, so a complete file IS the documentation. A key that
    // vanishes when unset is undiscoverable.
    let seeded = (try? String(contentsOf: tmp, encoding: .utf8)) ?? ""
    for key in ["deadZone", "easeMs", "stops", "zoomIn", "zoomOut", "reset", "host", "port", "password", "\"x\"", "\"y\""] {
        expect(seeded.contains(key), "the seeded file shows \(key)")
    }

    try? Data("{ not json".utf8).write(to: tmp)
    if case .rejected = store.load() {
        expect(true, "malformed JSON is rejected so the caller keeps last-good")
    } else {
        expect(false, "malformed JSON must be rejected")
    }
}

// MARK: - obs-websocket boundary

print("obs-websocket responses")

func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T? {
    try? JSONDecoder().decode(T.self, from: Data(json.utf8))
}

do {
    // Field names and shape taken from the real scene collection on this machine.
    let list = decode(
        SceneItemListResponse.self,
        """
        {"sceneItems":[
          {"sceneItemId":1,"sourceName":"camera","inputKind":"macos-avcapture"},
          {"sceneItemId":2,"sourceName":"chrome","inputKind":"screen_capture"},
          {"sceneItemId":3,"sourceName":"a group","inputKind":null}
        ]}
        """
    )
    expect(list?.sceneItems.count == 3, "all items decode")

    let summaries = list?.summaries ?? []
    expect(summaries.count == 3, "summaries preserve every item")

    if let picked = try? pickCaptureItem(summaries) {
        expect(picked.inputName == InputName("chrome"), "the real scene picks chrome")
        expect(picked.id == SceneItemId(2), "and carries its scene item id")
    } else {
        expect(false, "picking from the real scene shape should succeed")
    }
}

do {
    expect(
        decode(CurrentSceneResponse.self, #"{"currentProgramSceneName":"Scene Browser"}"#)?
            .sceneName == SceneName("Scene Browser"),
        "the obs-websocket 5.x scene name field is accepted"
    )
    expect(
        decode(CurrentSceneResponse.self, #"{"sceneName":"Scene Terminal"}"#)?
            .sceneName == SceneName("Scene Terminal"),
        "so is the newer field, rather than pinning to one OBS build"
    )
    expect(
        decode(CurrentSceneResponse.self, #"{"somethingElse":"x"}"#) == nil,
        "neither field present is an error"
    )
}

do {
    // Exactly the settings stored in this machine's scene collection.
    let chrome = decode(
        CaptureSettings.self,
        #"{"application":"com.google.Chrome","display_uuid":"37D8","type":1,"window":384}"#
    )
    expect(
        chrome.map(captureBinding) == .window(WindowID(384)),
        "a window capture yields its id, and OBS's application field is ignored"
    )

    let terminal = decode(CaptureSettings.self, #"{"type":1,"window":37}"#)
    expect(
        terminal.map(captureBinding) == .window(WindowID(37)),
        "a window capture with no recorded application still binds"
    )

    let display = decode(CaptureSettings.self, #"{"type":0,"display_uuid":"37D8"}"#)
    expect(
        display.map(captureBinding) == .display(uuid: "37D8"),
        "display capture is reported explicitly, not as a bare failure"
    )

    let app = decode(CaptureSettings.self, #"{"type":2,"application":"com.apple.Safari"}"#)
    expect(
        app.map(captureBinding) == .unsupported(type: 2),
        "application capture is unsupported and says which type it was"
    )

    let broken = decode(CaptureSettings.self, #"{"type":1}"#)
    expect(
        broken.map(captureBinding) == .unsupported(type: 1),
        "a window capture with no window id is unsupported, not a crash"
    )
}

do {
    let json = """
        {"sceneItemTransform":{
          "positionX":0,"positionY":0,"scaleX":1,"scaleY":1,"rotation":0,
          "alignment":5,"boundsType":"OBS_BOUNDS_SCALE_INNER","boundsAlignment":0,
          "boundsWidth":2992,"boundsHeight":1858,
          "cropLeft":0,"cropRight":0,"cropTop":0,"cropBottom":0,
          "sourceWidth":2940,"sourceHeight":1912,"width":2992,"height":1858}}
        """
    let transform = decode(SceneItemTransformResponse.self, json)?.sceneItemTransform
    expect(transform?.sourceSize == SourceSize(width: 2940, height: 1912), "source size parses")
    expect(transform?.displaySize.width ?? 0, 2992, "bounds win over scale for display size")

    var degenerate = transform!
    degenerate.sourceWidth = 0
    expect(
        degenerate.sourceSize == nil,
        "a degenerate source is nil, so it can never reach the framing math"
    )

    var unbounded = transform!
    unbounded.boundsType = "OBS_BOUNDS_NONE"
    unbounded.scaleX = 0.5
    expect(unbounded.displaySize.width, 1470, "with no bounds the display size is source x scale")
}

// MARK: - Journal boundary

print("JournalStore")

let sampleTransform = Transform(
    positionX: 0, positionY: 0, scaleX: 1, scaleY: 1, rotation: 0, alignment: 5,
    boundsType: "OBS_BOUNDS_SCALE_INNER", boundsAlignment: 0,
    boundsWidth: 2992, boundsHeight: 1858,
    cropLeft: 0, cropRight: 0, cropTop: 0, cropBottom: 0,
    sourceWidth: 2940, sourceHeight: 1912, width: 2992, height: 1858
)
let samplePristine = Pristine(
    scene: SceneName("Scene Browser"), itemId: SceneItemId(2),
    inputName: InputName("chrome"), transform: sampleTransform
)

do {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "lookit-journal-\(UUID().uuidString)")
    let path = dir.appending(path: "restore.json")
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = JournalStore.live(path: path)

    expect((try? store.read()) == .some(nil), "no journal reads as nothing to restore")

    do {
        try store.write(samplePristine)
        expect(try store.read() == samplePristine, "a journal round-trips exactly")
    } catch {
        expect(false, "writing a journal should succeed (got \(error))")
    }

    // A human has to be able to read this file to fix things by hand.
    let raw = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
    expect(raw.contains("\"scene\" : \"Scene Browser\""), "ids encode as bare values, not {raw:}")
    expect(raw.contains("\"inputName\" : \"chrome\""), "the input name is readable in the file")

    try? store.delete()
    expect((try? store.read()) == .some(nil), "deleting leaves nothing to restore")
    expect((try? store.delete()) != nil, "deleting a missing journal is not an error")
}

do {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "lookit-journal-\(UUID().uuidString)")
    let path = dir.appending(path: "restore.json")
    defer { try? FileManager.default.removeItem(at: dir) }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? Data("{ half written".utf8).write(to: path)

    let store = JournalStore.live(path: path)
    do {
        _ = try store.read()
        expect(false, "a corrupt journal must not read as 'nothing to restore'")
    } catch {
        if case .corrupt = error {
            expect(true, "a corrupt journal is reported as corrupt")
        } else {
            expect(false, "expected .corrupt, got \(error)")
        }
    }
    expect(
        FileManager.default.fileExists(atPath: path.path(percentEncoded: false)),
        "and is kept on disk — it is the only evidence of the layout"
    )
}

do {
    // Invariant 1 rehearsed at the store level: this is the failure the zoom
    // path must refuse to proceed through.
    do {
        try JournalStore.unwritable.write(samplePristine)
        expect(false, "the unwritable journal must throw")
    } catch {
        expect(error == .writeFailed("unwritable"), "and it throws writeFailed")
    }
}

// MARK: - State variants

print("state")

do {
    expect(!DisconnectReason.authFailed.isRetryable, "a wrong password is never retried")
    expect(DisconnectReason.refused.isRetryable, "a refused connection is retried")
    expect(DisconnectReason.serverDisabled.isRetryable, "a disabled server is retried")
    expect(Connection.identified.isUsable, "only identified is usable")
    expect(!Connection.connecting.isUsable, "connecting is not yet usable")
}

do {
    // Each layer scopes the layer below's errors into its own type.
    expect(UnresolvedReason(TargetError.noCaptureInScene) == .noCaptureInScene, "scoped: no capture")
    expect(UnresolvedReason(TargetError.windowNotFound(WindowID(384))) == .windowGone, "scoped: window gone")
    expect(
        UnresolvedReason(TargetError.ambiguous([InputName("chrome")])) == .ambiguous([InputName("chrome")]),
        "scoped: ambiguity keeps the candidate names"
    )

    expect(
        UnresolvedReason(unsupported: .window(WindowID(1))) == nil,
        "a window binding is not an unsupported reason"
    )
    expect(
        UnresolvedReason(unsupported: .display(uuid: "x")) == .displayCaptureUnsupported,
        "display capture says so specifically"
    )
    expect(
        UnresolvedReason(unsupported: .unsupported(type: 2)) == .applicationCaptureUnsupported,
        "application capture says so specifically"
    )

    // Every reason must be sayable to a human — a bare "unresolved" is useless.
    let reasons: [UnresolvedReason] = [
        .notConnected, .noCaptureInScene, .ambiguous([InputName("a")]), .windowGone,
        .displayCaptureUnsupported, .applicationCaptureUnsupported, .degenerateSource,
    ]
    expect(reasons.allSatisfy { !$0.message.isEmpty }, "every unresolved reason has a message")
}

do {
    let target = Target(
        scene: SceneName("Scene Browser"), itemId: SceneItemId(2),
        inputName: InputName("chrome"), window: WindowID(384),
        bundleID: "net.imput.helium", transform: sampleTransform
    )
    expect(TargetState.resolved(target).target == target, "a resolved state yields its target")
    expect(TargetState.unresolved(.windowGone).target == nil, "an unresolved state yields none")
    expect(target.pristine == Pristine(
        scene: SceneName("Scene Browser"), itemId: SceneItemId(2),
        inputName: InputName("chrome"), transform: sampleTransform
    ), "a target knows the Pristine it would journal")

    expect(Dirtiness.clean.pristine == nil, "clean carries no pristine")
    expect(
        Dirtiness.dirty(target.pristine).pristine == target.pristine,
        "dirty always carries the way back — invariant 1 in the type system"
    )
}

// MARK: - Hotkey installation

print("installHotkeys")

do {
    let fake = RecordedHotkeys()
    let warnings = installHotkeys(
        Config.fallback.keys, registrar: fake.registrar, perform: { fake.record($0) }
    )
    expect(warnings.isEmpty, "the default bindings install cleanly")
    expect(fake.registered.count == 3, "all three hotkeys register")
    expect(fake.unregisterCount == 1, "installing first clears whatever was there")

    fake.fire(0)
    fake.fire(2)
    expect(fake.fired == [.zoomIn, .reset], "each hotkey invokes its own action")
}

do {
    // One typo must not disable the other two.
    let keys = Config.Keys(zoomIn: "cmd+opt+=", zoomOut: "gibberish", reset: "cmd+opt+0")
    let fake = RecordedHotkeys()
    let warnings = installHotkeys(keys, registrar: fake.registrar, perform: { fake.record($0) })

    expect(fake.registered.count == 2, "the two valid bindings still register")
    expect(warnings.count == 1, "and exactly one warning explains the third")
    expect(warnings.first?.key == "keys.zoomOut", "naming the binding that failed")

    fake.fire(1)
    expect(fake.fired == [.reset], "the surviving bindings keep their own actions")
}

do {
    // The system refusing a combination is a different failure from a typo, and
    // needs a different message — "another app owns it" is actionable.
    let occupied = parseKeybinding("cmd+opt+=")!.keyCode
    let fake = RecordedHotkeys(refusing: [occupied])
    let warnings = installHotkeys(
        Config.fallback.keys, registrar: fake.registrar, perform: { fake.record($0) }
    )
    expect(fake.registered.count == 2, "the refused binding is not registered")
    expect(warnings.count == 1, "the refusal is reported")
    expect(
        warnings.first?.detail.contains("another app") == true,
        "and says the likely cause rather than just failing"
    )
}

do {
    // Hot-reload: installing again must replace, not accumulate.
    let fake = RecordedHotkeys()
    _ = installHotkeys(Config.fallback.keys, registrar: fake.registrar, perform: { _ in })
    _ = installHotkeys(Config.fallback.keys, registrar: fake.registrar, perform: { _ in })
    expect(fake.registered.count == 3, "re-installing replaces rather than accumulating")
    expect(fake.unregisterCount == 2, "each install clears first")
}

// MARK: - HUD placement and display

print("HUD")

do {
    let visible = (x: 0.0, y: 0.0, width: 1440.0, height: 900.0)
    let size = (width: 168.0, height: 56.0)

    let corner = hudOrigin(saved: nil, visible: visible, size: size)
    expect(corner.x, 1248, "with no saved position the HUD sits bottom-right")
    expect(corner.y, 24, "clear of the screen edge")

    expect(
        hudOrigin(saved: CGPoint(x: 300, y: 400), visible: visible, size: size)
            == CGPoint(x: 300, y: 400),
        "a saved position on screen is honoured"
    )

    // Unplugging the display the HUD was dragged onto must not leave it
    // permanently invisible with no way to get it back.
    let offscreen = hudOrigin(saved: CGPoint(x: 5000, y: 3000), visible: visible, size: size)
    expect(offscreen == corner, "a saved position off screen falls back to the corner")
    expect(
        hudOrigin(saved: CGPoint(x: -500, y: 400), visible: visible, size: size) == corner,
        "so does one off the left edge"
    )
    expect(
        hudOrigin(saved: CGPoint(x: -140, y: 400), visible: visible, size: size)
            == CGPoint(x: -140, y: 400),
        "but a mostly-onscreen position is kept"
    )

    // A second display sits at a non-zero origin.
    let second = (x: 1440.0, y: 0.0, width: 1920.0, height: 1080.0)
    expect(
        hudOrigin(saved: nil, visible: second, size: size).x, 3168,
        "the corner is relative to the screen, not the origin"
    )
}

do {
    expect(stopsRuler(stops: [1, 1.5, 2, 3], current: 1) == "●1 · 1.5 · 2 · 3", "the ruler marks 1x")
    expect(
        stopsRuler(stops: [1, 1.5, 2, 3], current: 2) == "1 · 1.5 · ●2 · 3",
        "and marks the current stop"
    )
    expect(
        stopsRuler(stops: [1, 1.5, 2, 3], current: 1.9) == "1 · 1.5 · ●2 · 3",
        "mid-animation it marks the nearest stop rather than going blank"
    )
    expect(stopsRuler(stops: [], current: 1) == "", "no stops renders nothing")
}

// MARK: - Hot-reload change detection

print("changes(from:to:)")

do {
    expect(changes(from: .fallback, to: .fallback).isEmpty, "an identical config changes nothing")

    // The case that matters: lookit writes this file itself on every HUD drag.
    // If a moved panel counted as a change, the hotkeys would churn constantly.
    var dragged = Config.fallback
    dragged.hud = Config.HUD(x: 100, y: 200)
    let afterDrag = changes(from: .fallback, to: dragged)
    expect(afterDrag.isEmpty, "moving the HUD triggers no reload work")
    expect(!afterDrag.keys, "and specifically does not re-register hotkeys")

    var rebound = Config.fallback
    rebound.keys.zoomIn = "ctrl+shift+z"
    expect(changes(from: .fallback, to: rebound).keys, "a rebound key needs re-registering")

    var retuned = Config.fallback
    retuned.easeMs = 200
    let tuning = changes(from: .fallback, to: retuned)
    expect(tuning.tuning, "easeMs is a tuning change")
    expect(!tuning.keys, "but does not touch the hotkeys")

    var restopped = Config.fallback
    restopped.stops = [1, 2, 4]
    expect(changes(from: .fallback, to: restopped).stops, "new stops need the HUD updating")

    var repointed = Config.fallback
    repointed.obs.password = "hunter2"
    let obs = changes(from: .fallback, to: repointed)
    expect(obs.obs, "obs settings changing needs a reconnect")
    expect(!obs.keys && !obs.stops, "and nothing else")
}

// MARK: - Transport: auth and the retry decision

print("identifyAuthentication")

do {
    // obs-websocket's own documented example. The expected value was computed
    // with openssl, not with this function — a vector generated by the code
    // under test would only prove it agrees with itself.
    //
    //   printf '%s' "$password$salt" | openssl dgst -sha256 -binary | openssl base64 -A
    //   printf '%s' "$secret$challenge" | openssl dgst -sha256 -binary | openssl base64 -A
    expect(
        identifyAuthentication(
            password: "supersecretpassword",
            salt: "82hi1UI+Lc1M3EOMxpYtdQ==",
            challenge: "+IxH4CnCiqpX1rM9scsNynZzbOe4KhDeYcTNS3PDaeY="
        ) == "y5kAHpcLaRJ0v+lmTBcIwW9D6k7Z0ixW2R1WBZ2nkXg=",
        "the challenge response matches the documented vector"
    )

    expect(
        identifyAuthentication(password: "a", salt: "s", challenge: "c")
            != identifyAuthentication(password: "b", salt: "s", challenge: "c"),
        "a different password gives a different answer"
    )
    expect(
        identifyAuthentication(password: "a", salt: "s", challenge: "c")
            != identifyAuthentication(password: "a", salt: "s", challenge: "d"),
        "and so does a different challenge, so the response is not replayable"
    )
}

print("transportFailure")

do {
    // Verified against a live OBS: a wrong password closes with 4009 while the
    // thrown error is a generic POSIX 57, so only the close code identifies it.
    expect(
        transportFailure(closeCode: 4009, urlErrorCode: nil, obsRunning: true, detail: "")
            == .authFailed,
        "close code 4009 is authentication failure whatever the error says"
    )

    // Both of these are NSURLErrorCannotConnectToHost; only the process check
    // separates "start OBS" from "enable the server".
    expect(
        transportFailure(closeCode: 0, urlErrorCode: -1004, obsRunning: false, detail: "")
            == .refused,
        "nothing listening and no OBS means OBS is not running"
    )
    expect(
        transportFailure(closeCode: 0, urlErrorCode: -1004, obsRunning: true, detail: "")
            == .serverDisabled,
        "nothing listening while OBS runs means the server is switched off"
    )

    expect(
        transportFailure(closeCode: 1000, urlErrorCode: nil, obsRunning: true, detail: "bye")
            == .dropped("bye"),
        "anything else keeps what the OS said"
    )
}

print("retryDelay")

do {
    expect(retryDelay(.authFailed, attempt: 0) == nil, "a wrong password is never retried")

    expect(
        retryDelay(.serverDisabled, attempt: 0) == retryDelay(.serverDisabled, attempt: 9),
        "a disabled server polls at a flat slow rate, since the user must act"
    )

    let first = retryDelay(.refused, attempt: 0)!
    let second = retryDelay(.refused, attempt: 1)!
    expect(first < second, "refused backs off")
    expect(first <= .seconds(1), "but the first retry is quick, so starting OBS feels instant")

    let far = retryDelay(.refused, attempt: 30)!
    expect(far == .seconds(10), "and it is capped rather than growing without bound")
    expect(retryDelay(.dropped("x"), attempt: 30) == far, "a dropped socket backs off the same way")
}

// MARK: - Transport: request/response correlation

print("responseId / requestFailure")

do {
    func json(_ text: String) -> Data { Data(text.utf8) }

    // Shape captured from OBS 32.1.1 / obs-websocket 5.7.3, not invented.
    let ok = json(
        """
        {"op":7,"d":{"requestType":"GetVersion","requestId":"3",
        "requestStatus":{"result":true,"code":100},
        "responseData":{"obsVersion":"32.1.1"}}}
        """
    )
    expect(responseId(in: ok) == "3", "a response is matched to the request that asked for it")
    expect(requestFailure(in: ok) == nil, "result true is success")

    // An event arrives down the same socket and must not be mistaken for a
    // response to anything, or it would resume the wrong caller.
    let event = json(
        """
        {"op":5,"d":{"eventType":"CurrentProgramSceneChanged","eventIntent":4,
        "eventData":{"sceneName":"Scene Browser"}}}
        """
    )
    expect(responseId(in: event) == nil, "an op 5 event is not a response")
    expect(
        obsEvent(in: event) == .sceneChanged(SceneName("Scene Browser")),
        "and it is read as the event it is"
    )
    expect(obsEvent(in: ok) == nil, "a response is not an event")

    // Carries a sceneName of its own. Decoding alone would accept it, so the
    // eventType is what keeps it from being read as a scene switch.
    let itemCreated = json(
        """
        {"op":5,"d":{"eventType":"SceneItemCreated","eventIntent":8,
        "eventData":{"sceneName":"Scene Browser","sourceName":"chrome","sceneItemId":3}}}
        """
    )
    expect(obsEvent(in: itemCreated) == nil, "another event that names a scene is still not a switch")

    // 600 = ResourceNotFound, what asking for a missing scene item returns.
    let failed = json(
        """
        {"op":7,"d":{"requestType":"GetSceneItemTransform","requestId":"7",
        "requestStatus":{"result":false,"code":600,"comment":"No scene items were found."}}}
        """
    )
    expect(responseId(in: failed) == "7", "a failed response is still correlated")
    expect(
        requestFailure(in: failed) == .requestFailed(code: 600, comment: "No scene items were found."),
        "a refused request becomes a typed value carrying OBS's own code and comment"
    )

    // Some failures carry no comment at all; the code must still survive.
    let terse = json(
        """
        {"op":7,"d":{"requestType":"SetSceneItemTransform","requestId":"8",
        "requestStatus":{"result":false,"code":608}}}
        """
    )
    expect(
        requestFailure(in: terse) == .requestFailed(code: 608, comment: nil),
        "a failure with no comment keeps its code"
    )

    expect(
        requestFailure(in: json("{\"op\":7,\"d\":{}}")) == .dropped("unreadable response from OBS"),
        "a malformed response is a dropped connection, not a crash"
    )
}

// MARK: - Restore on launch

print("restoreJournalIfPresent")

/// A journal in memory, so the order of read/apply/delete is observable.
final class FakeJournal: @unchecked Sendable {
    var stored: Pristine?
    var readThrows: JournalError?
    var deleteThrows: JournalError?
    var log: [String] = []

    var store: JournalStore {
        JournalStore(
            read: { [self] () throws(JournalError) -> Pristine? in
                log.append("read")
                if let readThrows { throw readThrows }
                return stored
            },
            write: { [self] pristine throws(JournalError) in
                log.append("write")
                stored = pristine
            },
            delete: { [self] () throws(JournalError) in
                log.append("delete")
                if let deleteThrows { throw deleteThrows }
                stored = nil
            }
        )
    }
}

/// Run a restore and hand back only its E. Keeping the typed call alone in the
/// `do` is what lets `catch` see a RestoreError rather than `any Error`.
@MainActor
func restoreOutcome(
    _ journal: JournalStore,
    _ apply: (Pristine) async throws(ObsError) -> Void
) async -> RestoreError? {
    do {
        try await restoreJournalIfPresent(journal: journal, apply: apply)
        return nil
    } catch {
        return error
    }
}

// Nothing on disk: the previous run exited clean, so OBS is never touched.
do {
    let journal = FakeJournal()
    var applied = 0
    let outcome = await restoreOutcome(journal.store) { _ in applied += 1 }
    expect(outcome == nil, "a clean launch is not an error")
    expect(applied == 0, "no journal means nothing to restore")
    expect(journal.log == ["read"], "and OBS is never written to")
}

// The happy path, and the ordering invariant 1 rests on.
do {
    let journal = FakeJournal()
    journal.stored = samplePristine
    var applied: [Pristine] = []
    let outcome = await restoreOutcome(journal.store) { applied.append($0) }
    expect(outcome == nil, "a restorable journal restores")
    expect(applied == [samplePristine], "replayed to OBS exactly as recorded")
    expect(journal.log == ["read", "delete"], "and deleted only after OBS confirmed")
    expect(journal.stored == nil, "the journal is gone once its work is done")
}

// The case that would lose the user's layout for good.
do {
    let journal = FakeJournal()
    journal.stored = samplePristine
    let refusal = ObsError.requestFailed(code: 600, comment: "No scene items were found.")
    let outcome = await restoreOutcome(journal.store) { _ throws(ObsError) in throw refusal }
    expect(
        outcome == .refused(DisconnectReason(refusal).message),
        "OBS refusing the write is reported as a refusal"
    )
    expect(journal.log == ["read"], "a journal OBS refused is NEVER deleted")
    expect(journal.stored == samplePristine, "so the next launch can try again")
}

// Unreadable: the file stays, because it is the only record of the layout.
do {
    let journal = FakeJournal()
    journal.readThrows = .corrupt("not JSON")
    let outcome = await restoreOutcome(journal.store) { _ in
        expect(false, "a journal that cannot be read must never reach OBS")
    }
    expect(outcome == .unreadable("not JSON"), "a corrupt journal is reported as unreadable")
    expect(journal.log == ["read"], "and is left on disk untouched")
}

// Applied but not cleared. Its own case on purpose: the layout IS back, so the
// user must not be told the restore failed.
do {
    let journal = FakeJournal()
    journal.stored = samplePristine
    journal.deleteThrows = .deleteFailed("permission denied")
    let outcome = await restoreOutcome(journal.store) { _ in }
    expect(outcome == .notCleared("permission denied"), "failing to clear is its own case")
    expect(
        outcome?.message.contains("restored") == true,
        "and it says the layout is back, because it is"
    )
}

// MARK: - Coalescing transform sends

print("TransformSender")

/// An OBS that answers only when told to, so the coalescing is observable
/// rather than a race.
@MainActor
final class SlowOBS {
    /// cropLeft of each frame that actually reached OBS — the frame's identity.
    var sent: [Double] = []
    private var release: CheckedContinuation<Void, Never>?

    func send(_ request: SetSceneItemTransformRequest) async {
        sent.append(request.sceneItemTransform.cropLeft)
        await withCheckedContinuation { release = $0 }
    }

    func answer() { release?.resume(); release = nil }
}

func frame(_ cropLeft: Double) -> SetSceneItemTransformRequest {
    var transform = sampleTransform
    transform.cropLeft = cropLeft
    return SetSceneItemTransformRequest(
        scene: SceneName("Scene Browser"), itemId: SceneItemId(3), transform: transform
    )
}

/// Let the sender's Task run until it gets where it is going.
func settle(_ done: () -> Bool) async {
    for _ in 0..<100 where !done() { await Task.yield() }
}

do {
    let obs = SlowOBS()
    let sender = TransformSender(send: obs.send)

    sender.post(frame(1))
    await settle { obs.sent.count == 1 }
    expect(obs.sent == [1], "the first frame goes straight out")

    // Three more arrive while OBS is still chewing on the first.
    sender.post(frame(2))
    sender.post(frame(3))
    sender.post(frame(4))
    await settle { false }
    expect(obs.sent == [1], "nothing else is sent while one is in flight")

    obs.answer()
    await settle { obs.sent.count == 2 }
    expect(obs.sent == [1, 4], "only the newest waiting frame follows; 2 and 3 were stale")

    // The frame that settles an ease is the one that must not be dropped.
    obs.answer()
    await settle { sender.isIdle }
    expect(sender.isIdle, "with nothing pending the sender goes idle")
    expect(obs.sent == [1, 4], "and idling sends nothing extra")

    sender.post(frame(5))
    await settle { obs.sent.count == 3 }
    expect(obs.sent == [1, 4, 5], "a frame posted after settling still reaches OBS")
    obs.answer()
    await settle { sender.isIdle }
}

do {
    var failNext = true
    let sender = TransformSender { _ throws(ObsError) in
        if failNext { throw .requestFailed(code: 600, comment: "gone") }
    }

    sender.post(frame(1))
    await settle { sender.isIdle }
    expect(
        sender.lastFailure == .requestFailed(code: 600, comment: "gone"),
        "a refused frame is recorded rather than thrown at the tick loop"
    )

    failNext = false
    sender.post(frame(2))
    await settle { sender.isIdle }
    expect(sender.lastFailure == nil, "and cleared by the next frame that lands")
}

// MARK: - What the HUD says

print("hudStatus")

do {
    let ok = Connection.identified
    let resolved = TargetState.resolved(
        Target(
            scene: SceneName("Scene Browser"), itemId: SceneItemId(3),
            inputName: InputName("chrome"), window: WindowID(384),
            bundleID: "net.imput.helium", transform: sampleTransform
        )
    )
    let badKey = ConfigWarning(key: "keys.zoomIn", detail: "unknown modifier")

    expect(
        hudStatus(connection: ok, target: resolved, warnings: []) == nil,
        "connected and resolved says nothing at all"
    )

    // Every escape in the E channel has to land somewhere.
    expect(
        hudStatus(connection: .disconnected(.serverDisabled), target: nil, warnings: [])
            == "Enable OBS → Tools → WebSocket Server Settings",
        "a disabled server says which box to tick"
    )
    expect(
        hudStatus(connection: .disconnected(.authFailed), target: nil, warnings: [])
            == "Wrong password — fix obs.password in the config",
        "a wrong password says so, since nothing will retry it"
    )
    expect(
        hudStatus(connection: ok, target: .unresolved(.windowGone), warnings: [])
            == "The captured window is gone — re-pick it in OBS",
        "an unresolved target says why"
    )
    expect(
        hudStatus(connection: ok, target: resolved, warnings: [badKey])
            == "keys.zoomIn: unknown modifier",
        "a config warning surfaces when nothing worse is wrong"
    )

    // The ranking. Several of these are true at once on a bad launch, and the
    // HUD has one line: show what is stopping the user first.
    expect(
        hudStatus(connection: .connecting, target: .unresolved(.notConnected), warnings: [badKey])
            == "Connecting to OBS…",
        "the connection outranks everything — nothing else can work without it"
    )
    expect(
        hudStatus(connection: ok, target: .unresolved(.noCaptureInScene), warnings: [badKey])
            == "No screen capture in this scene",
        "and an unresolved target outranks a warning that only degrades things"
    )

    // Regression: a restore failure arrives as a warning, and used to be
    // overwritten by whichever setStatus call ran last.
    expect(
        hudStatus(
            connection: ok, target: resolved,
            warnings: [ConfigWarning(key: "restore", detail: RestoreError.notCleared("denied").message)]
        )?.contains("Layout restored") == true,
        "a restore failure is not lost behind a later status update"
    )
}

// MARK: - Is this really OBS's window?

print("matchesSource")

do {
    // Measured live: Helium window 46 is 1496x929 points on a 2x display, and
    // OBS reports the source as 2992 x 1858 backing pixels.
    let helium = CaptureRect(x: 100, y: 60, width: 1496, height: 929, scale: 2)
    expect(
        matchesSource(helium, SourceSize(width: 2992, height: 1858)),
        "the window OBS is really capturing matches its reported source size"
    )

    // A stale id resolving to some other window is the failure this catches.
    expect(
        !matchesSource(helium, SourceSize(width: 1280, height: 800)),
        "a differently sized window is not the one OBS is capturing"
    )

    // OBS reports 0x0 for a capture whose window has gone. It must never look
    // like a match, whatever the window server says.
    expect(
        !matchesSource(helium, SourceSize(width: 0, height: 0)),
        "a dead capture matches nothing"
    )

    // Sub-pixel rounding must not read as a different window.
    expect(
        matchesSource(
            CaptureRect(x: 0, y: 0, width: 1496.5, height: 929, scale: 2),
            SourceSize(width: 2992, height: 1858)
        ),
        "a pixel of rounding is still the same window"
    )

    // Non-Retina: the scale is what makes points and source pixels agree.
    expect(
        matchesSource(
            CaptureRect(x: 0, y: 0, width: 1496, height: 929, scale: 1),
            SourceSize(width: 1496, height: 929)
        ),
        "a 1x display maps points to pixels one for one"
    )
    expect(
        !matchesSource(
            CaptureRect(x: 0, y: 0, width: 1496, height: 929, scale: 1),
            SourceSize(width: 2992, height: 1858)
        ),
        "and the same window at 1x is not a 2x capture"
    )
}

// MARK: - The dirty scope

print("DirtyScope")

do {
    let target = Target(
        scene: SceneName("Scene Browser"), itemId: SceneItemId(3),
        inputName: InputName("chrome"), window: WindowID(46),
        bundleID: "net.imput.helium", transform: sampleTransform
    )
    /// What the item looks like after lookit has cropped it. Journalling THIS
    /// would be the unrecoverable bug.
    var cropped = sampleTransform
    cropped.cropLeft = 400
    let zoomed = Target(
        scene: target.scene, itemId: target.itemId, inputName: target.inputName,
        window: target.window, bundleID: target.bundleID, transform: cropped
    )

    // Acquire journals first, then goes dirty.
    do {
        let journal = FakeJournal()
        let scope = DirtyScope(journal: journal.store) { _ in }
        let pristine = try scope.acquire(target)
        expect(pristine.transform == sampleTransform, "the pristine is the framing as found")
        expect(journal.stored == pristine, "and it is on disk before anything is reframed")
        expect(scope.isDirty, "the scope is held")
    } catch {
        expect(false, "acquiring a writable journal must work: \(error)")
    }

    // The trap: acquiring again after a zoom must not overwrite the pristine.
    do {
        let journal = FakeJournal()
        let scope = DirtyScope(journal: journal.store) { _ in }
        _ = try scope.acquire(target)
        let second = try scope.acquire(zoomed)
        expect(second.transform == sampleTransform, "a second acquire returns the ORIGINAL pristine")
        expect(journal.stored?.transform == sampleTransform, "and never journals the cropped framing")
        expect(journal.log == ["write"], "the journal is written exactly once")
    } catch {
        expect(false, "a repeated acquire must not fail: \(error)")
    }

    // Invariant 1: no journal, no zoom.
    do {
        let scope = DirtyScope(journal: .unwritable) { _ in }
        _ = try scope.acquire(target)
        expect(false, "an unwritable journal must refuse the scope")
    } catch {
        expect(error == .writeFailed("unwritable"), "and says why")
    }
    do {
        let scope = DirtyScope(journal: .unwritable) { _ in }
        _ = try? scope.acquire(target)
        expect(!scope.isDirty, "a refused journal leaves the scope CLEAN — nothing was reframed")
    }

    // Invariant 2: a second, DIFFERENT target must be refused, not silently
    // handed the outgoing item's pristine.
    do {
        let journal = FakeJournal()
        let scope = DirtyScope(journal: journal.store) { _ in }
        _ = try scope.acquire(target)
        let other = Target(
            scene: SceneName("Scene Terminal"), itemId: SceneItemId(1),
            inputName: InputName("terminal"), window: WindowID(49),
            bundleID: "com.mitchellh.ghostty", transform: sampleTransform
        )
        do {
            _ = try scope.acquire(other)
            expect(false, "a second scene item must not be taken while one is held")
        } catch {
            expect(error == .stillHeld(InputName("chrome")), "and it names what is still held")
        }
        expect(journal.log == ["write"], "the held journal is untouched by the refusal")
        expect(journal.stored?.itemId == SceneItemId(3), "and still describes the outgoing item")
    } catch {
        expect(false, "setup must not fail: \(error)")
    }

    // Release restores, then forgets.
    do {
        let journal = FakeJournal()
        var restored: [Pristine] = []
        let scope = DirtyScope(journal: journal.store) { restored.append($0) }
        _ = try scope.acquire(target)
        try await scope.release()
        expect(restored.map(\.transform) == [sampleTransform], "release puts the pristine back")
        expect(journal.log == ["write", "read", "delete"], "and deletes the journal only after")
        expect(!scope.isDirty, "the scope is given back")
    } catch {
        expect(false, "releasing a held scope must work: \(error)")
    }

    // OBS refusing the restore must not lose the scope.
    do {
        let journal = FakeJournal()
        let scope = DirtyScope(journal: journal.store) { _ throws(ObsError) in
            throw .requestFailed(code: 600, comment: "gone")
        }
        _ = try scope.acquire(target)
        do {
            try await scope.release()
            expect(false, "a refused release must be reported")
        } catch {
            expect(scope.isDirty, "a scope that could not be restored is STILL DIRTY")
            expect(journal.stored != nil, "and its journal stays on disk")
        }
    } catch {
        expect(false, "setup must not fail: \(error)")
    }

    // Release is called on five exit paths; most of the time nothing is held.
    do {
        let journal = FakeJournal()
        let scope = DirtyScope(journal: journal.store) { _ in
            expect(false, "releasing a clean scope must not touch OBS")
        }
        try await scope.release()
        expect(journal.log == [], "releasing a clean scope does nothing at all")
    } catch {
        expect(false, "releasing clean must not fail: \(error)")
    }
}

// MARK: - One tick

print("framing / reframed")

do {
    // The real geometry: Helium at 1496x929 on a 2x display, captured at
    // 2992x1858 source pixels.
    let rect = CaptureRect(x: 100, y: 60, width: 1496, height: 929, scale: 2)
    let source = SourceSize(width: 2992, height: 1858)
    let middle = SourcePoint(x: 1496, y: 929)

    // At 1x the whole source is visible, so nothing is cropped however the
    // cursor moves. This is what makes "at rest" cost nothing.
    let atRest = framing(
        cursor: ScreenPoint(x: 150, y: 100), rect: rect, source: source,
        zoom: 1, center: middle, deadZone: 0.6
    )
    expect(atRest.crop == .zero, "1x crops nothing")

    // Cursor outside the captured window: hold, do not snap.
    let outside = framing(
        cursor: ScreenPoint(x: 5, y: 5), rect: rect, source: source,
        zoom: 2, center: middle, deadZone: 0.6
    )
    expect(outside.pan == .frozen, "a cursor off the window freezes the shot")
    expect(outside.center == middle, "and the centre does not move")

    // Inside, but within the dead zone: also holds, for a different reason.
    let inDeadZone = framing(
        cursor: ScreenPoint(x: 100 + 748, y: 60 + 464), rect: rect, source: source,
        zoom: 2, center: middle, deadZone: 0.6
    )
    expect(inDeadZone.pan == .following, "a cursor on the window is followed")
    expect(inDeadZone.center == middle, "but the dead zone means it does not drift")

    // Cursor pushed to the far corner: the shot moves, and stays inside.
    let corner = framing(
        cursor: ScreenPoint(x: 100 + 1490, y: 60 + 925), rect: rect, source: source,
        zoom: 2, center: middle, deadZone: 0.6
    )
    expect(corner.center.x > middle.x && corner.center.y > middle.y, "the shot follows")
    let region = visibleRegion(source: source, zoom: 2, center: corner.center)
    expect(
        region.origin.x >= 0 && region.origin.y >= 0
            && region.origin.x + region.size.width <= source.width
            && region.origin.y + region.size.height <= source.height,
        "and never leaves the source"
    )
    expect(corner.crop.right >= 0 && corner.crop.bottom >= 0, "so the crop is never negative")

    // reframed: bounds are what stop a crop from shrinking the item on canvas.
    let unbounded = Transform(
        positionX: 0, positionY: 0, scaleX: 1, scaleY: 1, rotation: 0, alignment: 5,
        boundsType: "OBS_BOUNDS_NONE", boundsAlignment: 0, boundsWidth: 0, boundsHeight: 0,
        cropLeft: 0, cropRight: 0, cropTop: 0, cropBottom: 0,
        sourceWidth: 2992, sourceHeight: 1858, width: 2992, height: 1858
    )
    let crop = CropInsets(left: 100, top: 50, right: 100, bottom: 50)
    let fixed = reframed(unbounded, crop: crop)
    expect(fixed.boundsType == "OBS_BOUNDS_SCALE_INNER", "an unbounded item gains bounds")
    expect(
        fixed.boundsWidth == 2992 && fixed.boundsHeight == 1858,
        "sized to the rectangle it already occupied, so the layout does not jump"
    )

    let bounded = reframed(sampleTransform, crop: crop)
    expect(
        bounded.boundsType == sampleTransform.boundsType
            && bounded.boundsWidth == sampleTransform.boundsWidth,
        "an item the user already bounded is left alone"
    )
    expect(
        bounded.cropLeft == 100 && bounded.cropTop == 50
            && bounded.cropRight == 100 && bounded.cropBottom == 50,
        "and only the crop changes"
    )
    expect(
        bounded.positionX == sampleTransform.positionX
            && bounded.scaleX == sampleTransform.scaleX
            && bounded.rotation == sampleTransform.rotation,
        "position, scale and rotation are the user's, never lookit's"
    )
}

// MARK: - §9: the same graph under a test R

print("TickLoop under scripted R")

/// Clock, cursor and OBS, all under the check's control.
@MainActor
final class Rig {
    var clock = 0.0
    var cursor = ScreenPoint(x: 0, y: 0)
    var window: CaptureRect? = CaptureRect(x: 100, y: 60, width: 1496, height: 929, scale: 2)
    var sent: [SetSceneItemTransformRequest] = []

    var environment: TickLoop.Environment {
        TickLoop.Environment(
            cursor: { [self] in cursor },
            locate: { [self] _ in window },
            now: { [self] in clock },
            send: { [self] in sent.append($0) }
        )
    }

    /// Advance one 30Hz frame and run it.
    @discardableResult
    func frame(_ loop: TickLoop) -> TickLoop.Outcome {
        clock += 1.0 / 30
        return loop.step()
    }
}

do {
    let rig = Rig()
    let pristine = Pristine(
        scene: SceneName("Scene Browser"), itemId: SceneItemId(3),
        inputName: InputName("chrome"), transform: sampleTransform
    )
    let loop = TickLoop(
        environment: rig.environment, deadZone: 0.6, easeMs: 300, resting: 1
    )

    // Zoom in to 2x. The ease is 300ms, so ~9 frames at 30Hz.
    rig.cursor = ScreenPoint(x: 100 + 748, y: 60 + 464)   // dead centre
    loop.aim(at: 2, pristine: pristine, window: WindowID(46))

    var outcomes: [TickLoop.Outcome] = []
    var zooms: [Double] = []
    for _ in 0..<9 {
        outcomes.append(rig.frame(loop))
        zooms.append(loop.zoom)
    }

    expect(outcomes.allSatisfy { $0 == .running }, "the ease runs, frame by frame")
    expect(rig.sent.count == 9, "one transform per frame")
    expect(abs(loop.zoom - 2) < 0.01, "and it arrives at the stop it was aimed at")

    // Smoothstep on the zoom: slow at both ends, fastest in the middle.
    let zoomSteps = zip(zooms, zooms.dropFirst()).map { $1 - $0 }
    expect(zoomSteps[zoomSteps.count / 2] > zoomSteps[0], "the zoom accelerates out of the start")
    expect(zoomSteps[zoomSteps.count / 2] > zoomSteps.last!, "and decelerates into the end")

    // The eased pan end to end: the crop must grow monotonically, never jump.
    let crops = rig.sent.map(\.sceneItemTransform.cropLeft)
    expect(crops.first! < 60, "the first frame is barely cropped — the ease starts at 1x")
    expect(crops.last! > 700, "the last is cropped to half the width, which is 2x")
    expect(zip(crops, crops.dropFirst()).allSatisfy { $0 <= $1 }, "and it only ever grows")

    // Worth knowing, and not obvious: crop is 1 - 1/zoom, so its velocity peaks
    // EARLY even though the zoom's peaks in the middle. Smoothstep in zoom is
    // not smoothstep in what the viewer sees.
    let cropSteps = zip(crops, crops.dropFirst()).map { $1 - $0 }
    expect(
        cropSteps[0] > cropSteps.last!,
        "the visible motion is front-loaded relative to the zoom curve"
    )

    // Now move the cursor to a corner and watch the shot follow.
    rig.sent.removeAll()
    rig.cursor = ScreenPoint(x: 100 + 1480, y: 60 + 920)
    for _ in 0..<3 { rig.frame(loop) }
    let panned = rig.sent.map(\.sceneItemTransform.cropLeft)
    expect(panned.last! > crops.last!, "the shot pans toward the cursor")
    expect(
        rig.sent.allSatisfy { $0.sceneItemTransform.cropRight >= 0 },
        "and never crops past the edge of the source"
    )

    // Cursor off the window: frozen, and the frame stops moving.
    rig.sent.removeAll()
    rig.cursor = ScreenPoint(x: 5, y: 5)
    for _ in 0..<3 { rig.frame(loop) }
    let frozen = Set(rig.sent.map(\.sceneItemTransform.cropLeft))
    expect(frozen.count == 1, "a cursor off the window holds the shot exactly still")

    // The window goes away mid-session.
    rig.window = nil
    expect(rig.frame(loop) == .windowGone, "a vanished window stops the loop")

    // Zoom back out. The last frame must land at rest before settling, or the
    // shot would be left a fraction short of where it belongs.
    rig.window = CaptureRect(x: 100, y: 60, width: 1496, height: 929, scale: 2)
    rig.sent.removeAll()
    loop.aim(at: 1, pristine: pristine, window: WindowID(46))
    var settled = false
    for _ in 0..<12 where !settled {
        settled = rig.frame(loop) == .settled
    }
    expect(settled, "the zoom-out settles")
    expect(abs(loop.zoom - 1) < 0.001, "exactly at rest")
    expect(
        rig.sent.last?.sceneItemTransform.cropLeft == 0,
        "and the final frame — sent before settling — is the uncropped one"
    )
}

print("")
if failures == 0 {
    print("all checks passed")
} else {
    print("\(failures) check(s) FAILED")
    exit(1)
}
