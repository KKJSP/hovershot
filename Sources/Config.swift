import AppKit
import Foundation

extension Notification.Name {
    static let shortcutsDidChange = Notification.Name("HoverShot.shortcutsDidChange")
}

enum Config {
    private static let prefix = "hovershot"
    private static let keyDebug = "\(prefix).debug"
    private static let keySaveFolder = "\(prefix).saveFolder"
    private static let keyClusterSensitivity = "\(prefix).clusterSensitivity"
    private static let keyPadding = "\(prefix).padding"

    /// Multiplier applied to all distance-based clustering budgets in the
    /// network construction passes — `mergeDistance`, `connectAlignedSeries`
    /// gap factors, and the `connectCaptions` proximity budget. `1.0` is the
    /// neutral baseline (matches the values the pipeline was tuned at); lower
    /// values tighten clustering, higher values let elements glue across
    /// wider gaps.
    static let defaultClusterSensitivity: Double = 1.0

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

    /// Multiplier applied to distance-based clustering budgets. Lower values
    /// tighten clustering (less merging), higher values relax it (wider gaps
    /// connect). Reads with a presence check so the typed `double(forKey:)`
    /// zero-default does not shadow a legitimately stored value.
    static var clusterSensitivity: Double {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: keyClusterSensitivity) != nil else {
                return defaultClusterSensitivity
            }
            return defaults.double(forKey: keyClusterSensitivity)
        }
        set { UserDefaults.standard.set(newValue, forKey: keyClusterSensitivity) }
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

    enum Palette {
        static let primary    = NSColor(srgbRed: 252/255, green: 129/255, blue:   2/255, alpha: 1)
        static let secondary  = NSColor(srgbRed:  78/255, green: 145/255, blue: 166/255, alpha: 1)
        static let background = NSColor(srgbRed:  60/255, green:  56/255, blue:  53/255, alpha: 1)
        static let darkAccent = NSColor(srgbRed:  73/255, green:  95/255, blue: 102/255, alpha: 1)
        static let accent     = NSColor(srgbRed: 255/255, green: 191/255, blue:   0/255, alpha: 1)
    }
}
