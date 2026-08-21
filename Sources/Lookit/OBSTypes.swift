// §6 Boundary: obs-websocket JSON -> trusted types.
//
// Everything OBS sends is unknown until it passes through here. Inside the app,
// these types are trusted and never re-validated.

import Foundation
import LookitCore

// MARK: - Transform

/// A scene item's framing, as OBS models it.
///
/// Mirrors obs-websocket's `sceneItemTransform` field names exactly so the
/// mapping is verifiable by eye. lookit only ever writes the crop and bounds
/// fields; the rest is carried so a Pristine transform can be restored whole.
public struct Transform: Equatable, Sendable, Codable {
    public var positionX: Double
    public var positionY: Double
    public var scaleX: Double
    public var scaleY: Double
    public var rotation: Double
    public var alignment: Int
    public var boundsType: String
    public var boundsAlignment: Int
    public var boundsWidth: Double
    public var boundsHeight: Double
    public var cropLeft: Double
    public var cropRight: Double
    public var cropTop: Double
    public var cropBottom: Double
    public var sourceWidth: Double
    public var sourceHeight: Double
    public var width: Double
    public var height: Double

    public init(
        positionX: Double, positionY: Double, scaleX: Double, scaleY: Double,
        rotation: Double, alignment: Int, boundsType: String, boundsAlignment: Int,
        boundsWidth: Double, boundsHeight: Double,
        cropLeft: Double, cropRight: Double, cropTop: Double, cropBottom: Double,
        sourceWidth: Double, sourceHeight: Double, width: Double, height: Double
    ) {
        self.positionX = positionX; self.positionY = positionY
        self.scaleX = scaleX; self.scaleY = scaleY
        self.rotation = rotation; self.alignment = alignment
        self.boundsType = boundsType; self.boundsAlignment = boundsAlignment
        self.boundsWidth = boundsWidth; self.boundsHeight = boundsHeight
        self.cropLeft = cropLeft; self.cropRight = cropRight
        self.cropTop = cropTop; self.cropBottom = cropBottom
        self.sourceWidth = sourceWidth; self.sourceHeight = sourceHeight
        self.width = width; self.height = height
    }

    /// The source's pixel dimensions, or nil when OBS reports a degenerate
    /// source — which it does for a capture whose window has gone away.
    ///
    /// Returning nil here is what lets `visibleRegion` treat a zero-sized source
    /// as a die: a degenerate Transform can never reach the framing math.
    public var sourceSize: SourceSize? {
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        return SourceSize(width: sourceWidth, height: sourceHeight)
    }

    /// The on-screen rectangle the item occupies, used as the bounds so that
    /// cropping reframes the content without moving or resizing the item.
    public var displaySize: (width: Double, height: Double) {
        // With no bounds set, the displayed size is the source scaled.
        if boundsType == "OBS_BOUNDS_NONE" || boundsWidth <= 0 || boundsHeight <= 0 {
            return (sourceWidth * scaleX, sourceHeight * scaleY)
        }
        return (boundsWidth, boundsHeight)
    }
}

// MARK: - Responses

public struct SceneItemListResponse: Decodable, Sendable {
    public let sceneItems: [Item]

    public struct Item: Decodable, Sendable {
        public let sceneItemId: Int
        public let sourceName: String
        /// Null for groups and nested scenes, which are neither captures nor
        /// cameras and must simply not be selected.
        public let inputKind: String?
    }

    /// Flatten into what target selection actually needs.
    public var summaries: [SceneItemSummary] {
        sceneItems.map {
            SceneItemSummary(
                id: SceneItemId($0.sceneItemId),
                inputName: InputName($0.sourceName),
                kind: InputKind($0.inputKind ?? "")
            )
        }
    }
}

public struct CurrentSceneResponse: Decodable, Sendable {
    public let sceneName: SceneName

    private enum CodingKeys: String, CodingKey {
        case sceneName
        case currentProgramSceneName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // obs-websocket 5.x returned currentProgramSceneName; later versions also
        // send sceneName. Accept either rather than pinning to one OBS build.
        let name =
            try c.decodeIfPresent(String.self, forKey: .sceneName)
            ?? c.decode(String.self, forKey: .currentProgramSceneName)
        sceneName = SceneName(name)
    }
}

public struct ObsVersion: Decodable, Sendable {
    public let obsVersion: String
}

/// Every scene OBS knows about, for the HUD's scene picker.
public struct SceneListResponse: Decodable, Sendable {
    public let currentProgramSceneName: String?
    public let scenes: [Scene]

    public struct Scene: Decodable, Sendable {
        public let sceneName: String
        public let sceneIndex: Int
    }

    /// In the order OBS shows them, top first.
    ///
    /// Sorted rather than taken as sent: `sceneIndex` counts up from the bottom
    /// of OBS's list, so index order is the picker upside down and the array's
    /// own order is not something obs-websocket promises.
    public var names: [SceneName] {
        scenes.sorted { $0.sceneIndex > $1.sceneIndex }.map { SceneName($0.sceneName) }
    }

    public var current: SceneName? { currentProgramSceneName.map(SceneName.init) }
}

public struct SetProgramSceneRequest: Encodable, Sendable {
    public let sceneName: String

    public init(_ scene: SceneName) { sceneName = scene.raw }
}

/// The canvas, used to shape the HUD's preview so what is framed there is what
/// goes out. `base`, not `output`: the canvas is what scene items are laid out
/// on, and a downscaled output does not change their proportions.
public struct VideoSettingsResponse: Decodable, Sendable {
    public let baseWidth: Int
    public let baseHeight: Int
}

/// A frame of the program scene for the HUD's preview.
///
/// Naming a **scene** rather than an input is the whole point: OBS renders it
/// composited, so the scene item transform — lookit's crop — is in the picture.
/// Screenshotting the input instead would return the source untransformed and
/// the preview would never show the zoom.
///
/// Twice `HUD.previewWidth`, because the panel draws on a Retina display and a
/// point-for-pixel image reads soft. Measured against a 2992×1858 canvas:
/// 240 wide was 4.0ms and 7.6 KB, 480 wide 6.8ms and 18.7 KB — so this sits
/// near the upper figure, still an order of magnitude under the 500ms interval.
public struct ScreenshotRequest: Encodable, Sendable {
    public let sourceName: String
    public let imageFormat = "jpg"
    public let imageWidth = 560
    public let imageCompressionQuality = 60

    public init(scene: SceneName) {
        sourceName = scene.raw
    }
}

public struct ScreenshotResponse: Decodable, Sendable {
    /// A `data:image/jpg;base64,…` URI, not raw bytes.
    public let imageData: String
}

public struct SceneItemTransformResponse: Decodable, Sendable {
    public let sceneItemTransform: Transform
}

public struct InputSettingsResponse: Decodable, Sendable {
    public let inputKind: String
    public let inputSettings: CaptureSettings
}

/// The settings of a macOS `screen_capture` input.
///
/// Every field is optional because OBS omits whichever ones do not apply to the
/// selected capture type.
public struct CaptureSettings: Decodable, Sendable {
    public let type: Int?
    public let window: UInt32?
    public let application: String?
    public let display_uuid: String?
}

// MARK: - Requests

/// The scene a request is about.
public struct SceneRequest: Encodable, Sendable {
    public let sceneName: String
    public init(_ scene: SceneName) { sceneName = scene.raw }
}

/// The input a request is about.
public struct InputRequest: Encodable, Sendable {
    public let inputName: String
    public init(_ name: InputName) { inputName = name.raw }
}

/// One scene item, addressed the way OBS addresses it.
public struct SceneItemRequest: Encodable, Sendable {
    public let sceneName: String
    public let sceneItemId: Int
    public init(scene: SceneName, itemId: SceneItemId) {
        sceneName = scene.raw
        sceneItemId = itemId.raw
    }
}

/// The only write lookit ever makes to a scene.
///
/// OBS accepts a whole transform back verbatim, read-only fields and all —
/// verified against 32.1.1 — with one exception, the bounds, handled below.
/// Fields lookit does not carry, such as `cropToBounds`, are left untouched
/// because OBS merges rather than replaces.
public struct SetSceneItemTransformRequest: Encodable, Equatable, Sendable {
    public let sceneName: String
    public let sceneItemId: Int
    public let sceneItemTransform: Transform

    public init(scene: SceneName, itemId: SceneItemId, transform: Transform) {
        sceneName = scene.raw
        sceneItemId = itemId.raw
        var transform = transform
        // OBS *reads back* 0 for the bounds of an unbounded item but *refuses*
        // to be written anything below 1 — a pristine with OBS_BOUNDS_NONE is
        // therefore not replayable verbatim, which is what broke restore. The
        // type makes the sizes inert, so the item's own display size satisfies
        // the validator without changing anything the user sees.
        if transform.boundsWidth < 1 || transform.boundsHeight < 1 {
            let display = transform.displaySize
            transform.boundsWidth = max(1, display.width)
            transform.boundsHeight = max(1, display.height)
        }
        sceneItemTransform = transform
    }

    public init(_ pristine: Pristine) {
        self.init(scene: pristine.scene, itemId: pristine.itemId, transform: pristine.transform)
    }
}

// MARK: - Events

/// The op 5 events lookit acts on.
///
/// Two cases, because two events are consumed. OBS sends dozens by default and
/// the rest are dropped at the boundary rather than modelled here.
public enum ObsEvent: Equatable, Sendable {
    /// The program scene changed. Invariant 2: the outgoing target must be
    /// released before the new one is acquired.
    case sceneChanged(SceneName)
    /// A scene was created, removed or reordered, so the HUD's cached list is
    /// stale. Carries nothing: the list is re-read rather than patched.
    case sceneListChanged
}

private struct EventFrame: Decodable {
    let eventType: String
    /// Absent on SceneListChanged, which is why this is optional rather than
    /// two separate decodes of the same frame.
    let eventData: EventData?

    struct EventData: Decodable {
        let sceneName: String?
    }
}

/// The event in an op 5 frame, or nil if this is not an event lookit acts on.
///
/// Pure, and tolerant in the same way `responseId` is: anything unrecognised is
/// "not for us". An unknown event must never disturb the socket.
public func obsEvent(in data: Data) -> ObsEvent? {
    guard
        (try? JSONDecoder().decode(OpCode.self, from: data))?.op == 5,
        let event = try? JSONDecoder().decode(Payload<EventFrame>.self, from: data).d
    else { return nil }

    // Switched on eventType, never on shape: other events carry a sceneName too
    // — SceneItemCreated among them — so a successful decode identifies nothing.
    switch event.eventType {
    case "CurrentProgramSceneChanged":
        guard let name = event.eventData?.sceneName else { return nil }
        return .sceneChanged(SceneName(name))
    case "SceneListChanged":
        return .sceneListChanged
    default:
        return nil
    }
}

// MARK: - What is being captured

/// What a capture lookit *can* zoom is bound to — `CaptureBinding` minus the
/// flavours it cannot, so a `Target` is unable to hold one of those.
public enum CaptureSource: Equatable, Sendable {
    case window(WindowID)
    case display(uuid: String)
}

public enum CaptureBinding: Equatable, Sendable {
    /// A specific window, and the id is all OBS reliably knows about it.
    ///
    /// The `application` field is deliberately not carried. It is vestigial:
    /// it survives re-picking the source onto a different browser, so it
    /// describes application-capture mode rather than this source. Validating
    /// the owner against it would reject the correct window forever. The owner
    /// to check comes from the window server instead — see `windowOwner`.
    case window(WindowID)
    /// A whole display, named by the UUID OBS saved. Unlike a window id this
    /// is never recycled, so it needs no owner check.
    case display(uuid: String)
    /// Something lookit does not understand, carrying the raw value so a bug
    /// report can say what it actually was.
    case unsupported(type: Int?)
}

/// OBS's macOS screen capture uses `type` 0 = display, 1 = window, 2 = application.
///
/// The field is **absent** for a display capture: OBS omits any setting still at
/// its default, and 0 is the default. Measured against 32.1.1 — a display
/// capture of the builtin panel sends `{"display_uuid": "37D8…"}` and nothing
/// else. So a missing type is a display, not a mystery.
public func captureBinding(from settings: CaptureSettings) -> CaptureBinding {
    switch settings.type ?? 0 {
    case 1:
        guard let window = settings.window else { return .unsupported(type: settings.type) }
        return .window(WindowID(window))
    case 0:
        guard let uuid = settings.display_uuid else { return .unsupported(type: settings.type) }
        return .display(uuid: uuid)
    default:
        return .unsupported(type: settings.type)
    }
}
