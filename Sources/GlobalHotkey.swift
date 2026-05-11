import AppKit

/// System-wide key-chord listener using `NSEvent`'s global monitor — same
/// strategy as the Python version. Requires Accessibility permission for the
/// host app; without it the handler simply never fires.
///
/// `update(to:)` lets the binding change at runtime without recreating the
/// owning controller, which we use to keep the hotkey in sync with the
/// user's settings.
final class GlobalHotkey {
    private var monitor: Any?
    private var shortcut: Shortcut
    private let handler: () -> Void

    init(shortcut: Shortcut, handler: @escaping () -> Void) {
        self.shortcut = shortcut
        self.handler = handler
        register()
    }

    deinit { unregister() }

    func update(to shortcut: Shortcut) {
        self.shortcut = shortcut
        unregister()
        register()
    }

    private func register() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            if self.shortcut.matches(event) {
                DispatchQueue.main.async { self.handler() }
            }
        }
    }

    func unregister() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
