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

// MARK: - What is being captured

public enum CaptureBinding: Equatable, Sendable {
    /// A specific window. The bundle id is carried because window ids are
    /// recycled and must be validated against their owner.
    case window(WindowID, bundleID: String?)
    /// A whole display. Not zoomable yet — reported explicitly so the HUD can
    /// say why rather than showing a bare "unresolved".
    case display(uuid: String)
    /// Something lookit does not understand, carrying the raw value so a bug
    /// report can say what it actually was.
    case unsupported(type: Int?)
}

/// OBS's macOS screen capture uses `type` 0 = display, 1 = window, 2 = application.
public func captureBinding(from settings: CaptureSettings) -> CaptureBinding {
    switch settings.type {
    case 1:
        guard let window = settings.window else { return .unsupported(type: settings.type) }
        return .window(WindowID(window), bundleID: settings.application)
    case 0:
        guard let uuid = settings.display_uuid else { return .unsupported(type: settings.type) }
        return .display(uuid: uuid)
    default:
        return .unsupported(type: settings.type)
    }
}
