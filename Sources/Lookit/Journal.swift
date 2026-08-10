// §6 Boundary: the journal file <-> Pristine.
//
// ADR 0002. This is the file that makes "always restorable" true across a crash,
// a force-quit, or OBS exiting first.

import Foundation
import LookitCore

// Branded ids encode as bare values rather than {"raw": ...}. Serialization is a
// boundary concern, so the conformances live here rather than in the core.
extension SceneName: Codable {
    public init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }
}

extension InputName: Codable {
    public init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }
}

extension SceneItemId: Codable {
    public init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(Int.self))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }
}

// MARK: - Pristine

/// A Target's framing as the user arranged it, before lookit touched anything.
///
/// The input name is carried purely so a human reading the file can tell what it
/// refers to; restoration keys off the scene and item id.
public struct Pristine: Equatable, Sendable, Codable {
    public let scene: SceneName
    public let itemId: SceneItemId
    public let inputName: InputName
    public let transform: Transform

    public init(scene: SceneName, itemId: SceneItemId, inputName: InputName, transform: Transform) {
        self.scene = scene
        self.itemId = itemId
        self.inputName = inputName
        self.transform = transform
    }
}

public enum JournalError: Error, Equatable, Sendable {
    /// Could not record the pristine transform. The caller must refuse to zoom:
    /// no journal, no zoom (invariant 1).
    case writeFailed(String)
    /// A journal exists but cannot be read as one. Kept on disk rather than
    /// deleted — it is the only evidence of what the layout was.
    case corrupt(String)
    /// Could not remove a journal whose work is done.
    case deleteFailed(String)
}

extension JournalError {
    /// What to tell the user. A zoom that refuses itself silently looks broken,
    /// so the reason has to be sayable.
    public var message: String {
        switch self {
        case let .writeFailed(detail): "Cannot save your layout, so not zooming — \(detail)"
        case let .corrupt(detail): "The saved layout is unreadable — \(detail)"
        case let .deleteFailed(detail): "Could not clear the saved layout — \(detail)"
        }
    }
}

// MARK: - Store

public struct JournalStore: Sendable {
    public var read: @Sendable () throws(JournalError) -> Pristine?
    public var write: @Sendable (Pristine) throws(JournalError) -> Void
    public var delete: @Sendable () throws(JournalError) -> Void

    public init(
        read: @escaping @Sendable () throws(JournalError) -> Pristine?,
        write: @escaping @Sendable (Pristine) throws(JournalError) -> Void,
        delete: @escaping @Sendable () throws(JournalError) -> Void
    ) {
        self.read = read
        self.write = write
        self.delete = delete
    }
}

extension JournalStore {
    public static let defaultPath = FileManager.default
        .homeDirectoryForCurrentUser
        .appending(path: ".config/lookit/restore.json")

    public static func live(path: URL = defaultPath) -> JournalStore {
        JournalStore(
            read: { () throws(JournalError) -> Pristine? in
                guard FileManager.default.fileExists(atPath: path.path(percentEncoded: false))
                else { return nil }
                do {
                    return try JSONDecoder().decode(Pristine.self, from: Data(contentsOf: path))
                } catch {
                    throw JournalError.corrupt(describe(error))
                }
            },
            write: { pristine throws(JournalError) in
                do {
                    try FileManager.default.createDirectory(
                        at: path.deletingLastPathComponent(), withIntermediateDirectories: true
                    )
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    // Atomic: a half-written journal is worse than none, because
                    // it reads as corrupt and blocks the restore it exists for.
                    try encoder.encode(pristine).write(to: path, options: .atomic)
                } catch {
                    throw JournalError.writeFailed(error.localizedDescription)
                }
            },
            delete: { () throws(JournalError) in
                do {
                    if FileManager.default.fileExists(atPath: path.path(percentEncoded: false)) {
                        try FileManager.default.removeItem(at: path)
                    }
                } catch {
                    throw JournalError.deleteFailed(error.localizedDescription)
                }
            }
        )
    }

    /// A journal that refuses to write. Exists to exercise invariant 1: with
    /// this store, zooming must be refused rather than attempted.
    public static let unwritable = JournalStore(
        read: { nil },
        write: { _ throws(JournalError) in throw JournalError.writeFailed("unwritable") },
        delete: {}
    )
}
