import AppKit

final class OverlayWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void
    let overlayView: OverlayView

    init(image: NSImage, screen: NSScreen, onClose: @escaping () -> Void) {
        self.onClose = onClose
        self.overlayView = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size),
                                       image: image)

        let panel = OverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.acceptsMouseMovedEvents = true
        // Skip the default fade-in so the frozen screenshot doesn't visibly
        // pop on top of the live screen — we want a hard, immediate swap.
        panel.animationBehavior = .none
        // Window lifetime is owned by this controller, so don't let AppKit
        // double-release the panel when the close cascade runs.
        panel.isReleasedWhenClosed = false
        panel.contentView = overlayView

        // Force the window onto the target screen and make it cover the entire frame
        // (including the menu-bar strip). With the screen-saver level the window can
        // legitimately occupy the menu-bar area.
        panel.setFrame(screen.frame, display: false)

        super.init(window: panel)
        panel.delegate = self
        overlayView.onDismiss = { [weak self] in self?.close() }
        overlayView.startDetection()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(overlayView)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

/// Custom window so it can become key despite being borderless — required for
/// keyboard shortcuts to fire while the overlay is up.
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
