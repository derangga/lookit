// §6 Boundary: a hotkey string from config -> a registrable key combination.
//
// Part of config parsing rather than the hotkey layer, because "cmd+opt+=" is
// untrusted text and this is where untrusted text becomes a trusted value.

import Carbon.HIToolbox

public struct Keybinding: Equatable, Sendable {
    public let keyCode: UInt32
    public let modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// Parse `"cmd+opt+="` into something `RegisterEventHotKey` accepts.
///
/// Returns nil for anything unrecognised. The caller turns that into a
/// `badKeybinding` warning and skips *that one binding* — a typo in one hotkey
/// must not take the other two down with it.
public func parseKeybinding(_ text: String) -> Keybinding? {
    let parts = text.lowercased()
        .split(separator: "+", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }

    guard var keyToken = parts.last, !parts.isEmpty else { return nil }

    // A trailing "+" means the key itself is "+", e.g. "cmd+opt++".
    if keyToken.isEmpty, parts.count > 1 {
        keyToken = "+"
    }

    var modifiers: UInt32 = 0
    for token in parts.dropLast() where !token.isEmpty {
        guard let flag = modifierFlag(token) else { return nil }
        modifiers |= flag
    }

    guard let keyCode = keyCodes[keyToken] else { return nil }
    guard modifiers != 0 else { return nil }  // a global hotkey with no modifier

    return Keybinding(keyCode: keyCode, modifiers: modifiers)
}

private func modifierFlag(_ token: String) -> UInt32? {
    switch token {
    case "cmd", "command", "⌘": UInt32(cmdKey)
    case "opt", "option", "alt", "⌥": UInt32(optionKey)
    case "ctrl", "control", "⌃": UInt32(controlKey)
    case "shift", "⇧": UInt32(shiftKey)
    default: nil
    }
}

/// The subset worth supporting for a zoom hotkey. Deliberately not exhaustive —
/// unrecognised keys produce a warning the user can see and fix.
private let keyCodes: [String: UInt32] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
    "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
    "=": 24, "+": 24, "-": 27, "_": 27, "[": 33, "]": 30, "\\": 42,
    ";": 41, "'": 39, ",": 43, ".": 47, "/": 44, "`": 50,
    "space": 49, "return": 36, "enter": 36, "tab": 48, "escape": 53, "esc": 53,
    "left": 123, "right": 124, "down": 125, "up": 126,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
    "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
]
