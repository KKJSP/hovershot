import AppKit
import Foundation

extension Notification.Name {
    static let shortcutsDidChange = Notification.Name("HoverShot.shortcutsDidChange")
}

enum Config {
    private static let prefix = "hovershot"
    private static let keyDebug = "\(prefix).debug"
    private static let keySaveFolder = "\(prefix).saveFolder"
    private static let keyBoxSize = "\(prefix).boxSize"
    private static let keyPadding = "\(prefix).padding"

    /// Multiplier applied to the Python-tuned `(8, 5)` ksize. Slider runs 0…2
    /// and displays as "0%…100%" via `value × 50`, so this `1.0` default sits
    /// at the 50% mark — equivalent to the old 100% setting that users now
    /// need as the practical floor after the NMS-aware edge detector landed.
    static let defaultBoxSize: Double = 1.0

    /// Default padding (in view-space pixels) applied around the selection rect
    /// when saving or copying a screenshot.
    static let defaultPadding: Int = 12

    static var debug: Bool {
        get { UserDefaults.standard.bool(forKey: keyDebug) }
        set { UserDefaults.standard.set(newValue, forKey: keyDebug) }
    }

    static var saveFolder: URL {
        get {
            if let path = UserDefaults.standard.string(forKey: keySaveFolder), !path.isEmpty {
                return URL(fileURLWithPath: path)
            }
            return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
        }
        set {
            try? FileManager.default.createDirectory(at: newValue, withIntermediateDirectories: true)
            UserDefaults.standard.set(newValue.path, forKey: keySaveFolder)
        }
    }

    /// Multiplier applied to the BoxFinder's morphological-closing kernel.
    /// Smaller produces smaller individual boxes; larger merges adjacent ones.
    /// Reads with a presence check so the typed `double(forKey:)` zero-default
    /// does not shadow a legitimately stored value.
    static var boxSize: Double {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: keyBoxSize) != nil else { return defaultBoxSize }
            return defaults.double(forKey: keyBoxSize)
        }
        set { UserDefaults.standard.set(newValue, forKey: keyBoxSize) }
    }

    /// Pixels of padding added around the selection when cropping the saved /
    /// copied image. Stored as a non-negative integer.
    static var padding: Int {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: keyPadding) != nil else { return defaultPadding }
            return max(0, defaults.integer(forKey: keyPadding))
        }
        set { UserDefaults.standard.set(max(0, newValue), forKey: keyPadding) }
    }

    // MARK: - Shortcuts

    static func shortcut(for action: ShortcutAction) -> Shortcut {
        let key = "\(prefix).shortcut.\(action.rawValue)"
        if let data = UserDefaults.standard.data(forKey: key),
           let stored = try? JSONDecoder().decode(Shortcut.self, from: data) {
            return stored
        }
        // Force-unwrap is safe — every action has a default.
        return ShortcutAction.default[action]!
    }

    static func setShortcut(_ shortcut: Shortcut, for action: ShortcutAction) {
        let key = "\(prefix).shortcut.\(action.rawValue)"
        if let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: key)
        }
        NotificationCenter.default.post(name: .shortcutsDidChange, object: action)
    }

    static func subFolder(_ name: String) -> URL {
        let url = saveFolder.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    enum Palette {
        static let primary    = NSColor(srgbRed: 252/255, green: 129/255, blue:   2/255, alpha: 1)
        static let secondary  = NSColor(srgbRed:  78/255, green: 145/255, blue: 166/255, alpha: 1)
        static let background = NSColor(srgbRed:  60/255, green:  56/255, blue:  53/255, alpha: 1)
        static let darkAccent = NSColor(srgbRed:  73/255, green:  95/255, blue: 102/255, alpha: 1)
        static let accent     = NSColor(srgbRed: 255/255, green: 191/255, blue:   0/255, alpha: 1)
    }
}
