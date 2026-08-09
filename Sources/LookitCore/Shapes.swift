// §1 Shapes — the nouns. See CONTEXT.md for what these words mean.
//
// Nothing in this file imports anything. Coordinates are plain Doubles rather
// than CGPoint/CGSize so the core stays portable (invariant 5).

// MARK: - IDs

public struct SceneName: Hashable, Sendable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}

public struct SceneItemId: Hashable, Sendable {
    public let raw: Int
    public init(_ raw: Int) { self.raw = raw }
}

public struct InputName: Hashable, Sendable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}

public struct InputKind: Hashable, Sendable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}

public struct WindowID: Hashable, Sendable {
    public let raw: UInt32
    public init(_ raw: UInt32) { self.raw = raw }
}

// MARK: - Source pixel space

/// A point in the captured source's own pixel space, origin top-left.
public struct SourcePoint: Hashable, Sendable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct SourceSize: Hashable, Sendable {
    public let width: Double
    public let height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
}

/// The portion of the source currently on screen. At 1x this is the whole source.
public struct SourceRegion: Hashable, Sendable {
    public let origin: SourcePoint
    public let size: SourceSize
    public init(origin: SourcePoint, size: SourceSize) { self.origin = origin; self.size = size }

    public var center: SourcePoint {
        SourcePoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
    }
}

/// What OBS actually consumes: how much to trim off each edge of the source.
public struct CropInsets: Hashable, Sendable {
    public let left: Double
    public let top: Double
    public let right: Double
    public let bottom: Double
    public init(left: Double, top: Double, right: Double, bottom: Double) {
        self.left = left; self.top = top; self.right = right; self.bottom = bottom
    }

    public static let zero = CropInsets(left: 0, top: 0, right: 0, bottom: 0)
}

// MARK: - Screen space

/// A point in global screen coordinates, origin top-left of the primary display.
/// Converted from AppKit's bottom-left convention at the boundary, not here.
public struct ScreenPoint: Hashable, Sendable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// The region of physical screen a captured window occupies, in top-left global
/// points, plus the backing scale that relates those points to source pixels.
public struct CaptureRect: Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let scale: Double

    public init(x: Double, y: Double, width: Double, height: Double, scale: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height; self.scale = scale
    }

    /// The source pixel dimensions this rect implies.
    public var sourceSize: SourceSize {
        SourceSize(width: width * scale, height: height * scale)
    }
}

// MARK: - Scene items

/// The minimum lookit needs to know about one scene item in order to pick a Target.
public struct SceneItemSummary: Hashable, Sendable {
    public let id: SceneItemId
    public let inputName: InputName
    public let kind: InputKind

    public init(id: SceneItemId, inputName: InputName, kind: InputKind) {
        self.id = id; self.inputName = inputName; self.kind = kind
    }
}

/// Input kinds that represent a screen capture and are therefore eligible Targets.
///
/// Cameras are excluded by *not being in this set* — never by name (invariant 3).
/// On macOS every capture flavour is `screen_capture`; the others are listed so
/// the rule reads as a rule rather than a magic string.
public let captureKinds: Set<String> = [
    "screen_capture",
    "display_capture",
    "window_capture",
]

extension InputKind {
    public var isCapture: Bool { captureKinds.contains(raw) }
}
