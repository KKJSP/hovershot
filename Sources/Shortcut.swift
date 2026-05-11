import AppKit

enum ShortcutAction: String, CaseIterable, Codable {
    case takeShot
    case save
    case copy
    case preview
    case toggleFlow
    case toggleAutocluster
    case dismiss

    var displayName: String {
        switch self {
        case .takeShot:          return "Take screenshot"
        case .save:              return "Save selection"
        case .copy:              return "Copy to clipboard"
        case .preview:           return "Open in Preview"
        case .toggleFlow:        return "Toggle flow mode"
        case .toggleAutocluster: return "Toggle auto-cluster"
        case .dismiss:           return "Dismiss overlay"
        }
    }

    /// Whether this action is bound to the system-wide hotkey (true for the
    /// trigger), as opposed to the overlay's local key handling.
    var isGlobal: Bool { self == .takeShot }

    static let `default`: [ShortcutAction: Shortcut] = [
        .takeShot:          Shortcut(keyCode: 18, modifierFlags: [.command, .shift], character: "1"),
        .save:              Shortcut(keyCode: 1,  modifierFlags: [], character: "s"),
        .copy:              Shortcut(keyCode: 8,  modifierFlags: [], character: "c"),
        .preview:           Shortcut(keyCode: 9,  modifierFlags: [], character: "v"),
        .toggleFlow:        Shortcut(keyCode: 3,  modifierFlags: [], character: "f"),
        .toggleAutocluster: Shortcut(keyCode: 0,  modifierFlags: [], character: "a"),
        .dismiss:           Shortcut(keyCode: 12, modifierFlags: [], character: "q"),
    ]
}

/// Persistable key-binding. `keyCode` is the source of truth for matching;
/// `character` is captured at recording time so we can render the binding back
/// to the user (and supply NSMenuItem.keyEquivalent) without re-translating
/// keyCodes on every read.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifierFlagsRaw: UInt
    var character: String

    init(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags, character: String) {
        self.keyCode = keyCode
        self.modifierFlagsRaw = modifierFlags.rawValue
        self.character = character
    }

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierFlagsRaw) }

    static let relevantModifierMask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    func matches(_ event: NSEvent) -> Bool {
        let active = event.modifierFlags.intersection(Shortcut.relevantModifierMask)
        return event.keyCode == keyCode && active == modifierFlags
    }

    /// Format suitable for a label, e.g. "⌘⇧1" or "⎋".
    var displayString: String {
        var parts = ""
        if modifierFlags.contains(.control) { parts += "⌃" }
        if modifierFlags.contains(.option)  { parts += "⌥" }
        if modifierFlags.contains(.shift)   { parts += "⇧" }
        if modifierFlags.contains(.command) { parts += "⌘" }
        parts += KeyCodeNames.label(for: keyCode, fallback: character)
        return parts
    }

    /// String suitable for `NSMenuItem.keyEquivalent`. Uses the lowercase
    /// character because AppKit applies the modifier mask separately.
    var menuKeyEquivalent: String {
        if let special = KeyCodeNames.menuEquivalent(for: keyCode) { return special }
        return character.lowercased()
    }

    var menuModifierMask: NSEvent.ModifierFlags { modifierFlags }
}

/// Static lookups for keycodes that don't have a printable character (escape,
/// arrows, function keys) and for those whose printed form is best replaced
/// with a glyph (return, tab, space).
enum KeyCodeNames {
    /// User-facing label. Falls back to the recorded character (uppercased)
    /// if the keyCode isn't recognised, then to a "Key #N" sentinel.
    static func label(for keyCode: UInt16, fallback: String) -> String {
        if let glyph = displayGlyphs[keyCode] { return glyph }
        let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed.uppercased() }
        return "Key #\(keyCode)"
    }

    /// String for `NSMenuItem.keyEquivalent` for keys that AppKit recognises
    /// via NSConstants (return, tab, space, escape, arrows, etc.). Returns nil
    /// for ordinary printable keys — the caller should use `character` then.
    static func menuEquivalent(for keyCode: UInt16) -> String? {
        menuGlyphs[keyCode]
    }

    private static let displayGlyphs: [UInt16: String] = [
        36:  "↩",       // Return
        48:  "⇥",       // Tab
        49:  "Space",
        51:  "⌫",       // Delete
        53:  "⎋",       // Escape
        76:  "⌅",       // Numpad Enter
        117: "⌦",       // Forward Delete
        115: "↖",       // Home
        119: "↘",       // End
        116: "⇞",       // Page Up
        121: "⇟",       // Page Down
        123: "←", 124: "→", 125: "↓", 126: "↑",
        96: "F5",  97: "F6",  98: "F7",  99: "F3", 100: "F8", 101: "F9",
        103: "F11", 105: "F13", 106: "F16", 107: "F14", 109: "F10",
        111: "F12", 113: "F15", 118: "F4", 120: "F2", 122: "F1",
    ]

    private static let menuGlyphs: [UInt16: String] = [
        36:  "\r",                              // Return
        48:  "\t",                              // Tab
        49:  " ",                               // Space
        51:  String(Character(Unicode.Scalar(NSDeleteCharacter)!)),
        53:  String(Character(Unicode.Scalar(0x1B)!)),  // Escape
        76:  "\u{0003}",                        // Enter
        117: String(Character(Unicode.Scalar(NSDeleteFunctionKey)!)),
        123: String(Character(Unicode.Scalar(NSLeftArrowFunctionKey)!)),
        124: String(Character(Unicode.Scalar(NSRightArrowFunctionKey)!)),
        125: String(Character(Unicode.Scalar(NSDownArrowFunctionKey)!)),
        126: String(Character(Unicode.Scalar(NSUpArrowFunctionKey)!)),
    ]
}
