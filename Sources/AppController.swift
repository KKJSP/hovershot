import AppKit

final class AppController: NSObject {
    private var statusItem: NSStatusItem?
    private var hotkey: GlobalHotkey?
    private var settings: SettingsWindowController?
    private var overlay: OverlayWindowController?
    private var shotMenuItem: NSMenuItem?
    private var changeObserver: NSObjectProtocol?

    func start() {
        installStatusItem()
        installHotkey()
        promptForAccessibilityIfNeeded()

        changeObserver = NotificationCenter.default.addObserver(
            forName: .shortcutsDidChange, object: nil, queue: .main
        ) { [weak self] note in
            self?.handleShortcutChange(action: note.object as? ShortcutAction)
        }
    }

    func stop() {
        hotkey?.unregister()
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
    }

    // MARK: - Menu bar

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let img: NSImage?
            if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
               let bundled = NSImage(contentsOf: url) {
                bundled.size = NSSize(width: 18, height: 18)
                bundled.isTemplate = true
                img = bundled
            } else {
                img = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "HoverShot")
                img?.isTemplate = true
            }
            button.image = img
            button.toolTip = "HoverShot"
        }

        let menu = NSMenu()

        let label = NSMenuItem(title: "HoverShot", action: nil, keyEquivalent: "")
        label.isEnabled = false
        menu.addItem(label)
        menu.addItem(.separator())

        let shot = NSMenuItem(title: "Take screenshot",
                              action: #selector(triggerShot),
                              keyEquivalent: "")
        shot.target = self
        menu.addItem(shot)
        shotMenuItem = shot
        applyShotShortcut()

        // No `keyEquivalent` — the app is normally not focused, so cmd+, /
        // cmd+Q wouldn't actually fire and the displayed shortcut would mislead.
        let settings = NSMenuItem(title: "Settings…",
                                  action: #selector(showSettings),
                                  keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit HoverShot",
                              action: #selector(NSApp.terminate(_:)),
                              keyEquivalent: "")
        menu.addItem(quit)

        item.menu = menu
        self.statusItem = item
    }

    private func applyShotShortcut() {
        let s = Config.shortcut(for: .takeShot)
        shotMenuItem?.keyEquivalent = s.menuKeyEquivalent
        shotMenuItem?.keyEquivalentModifierMask = s.menuModifierMask
    }

    // MARK: - Global hotkey

    private func installHotkey() {
        hotkey = GlobalHotkey(shortcut: Config.shortcut(for: .takeShot)) { [weak self] in
            self?.triggerShot()
        }
    }

    private func handleShortcutChange(action: ShortcutAction?) {
        guard action == nil || action == .takeShot else { return }
        hotkey?.update(to: Config.shortcut(for: .takeShot))
        applyShotShortcut()
    }

    private func promptForAccessibilityIfNeeded() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let opts = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: - Actions

    @objc private func triggerShot() {
        DispatchQueue.main.async { [weak self] in self?.showOverlay() }
    }

    @objc private func showSettings() {
        if settings == nil {
            let controller = SettingsWindowController()
            controller.onClose = { [weak self] in self?.settings = nil }
            settings = controller
        }
        NSApp.activate(ignoringOtherApps: true)
        settings?.showWindow(nil)
        settings?.window?.orderFrontRegardless()
    }

    private func showOverlay() {
        overlay?.close()
        overlay = nil

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        guard let screen else { return }

        guard let captured = ScreenshotCapture.captureScreen(screen) else {
            NSSound.beep()
            return
        }

        let controller = OverlayWindowController(image: captured, screen: screen) { [weak self] in
            self?.overlay = nil
        }
        overlay = controller
        controller.show()
    }
}
