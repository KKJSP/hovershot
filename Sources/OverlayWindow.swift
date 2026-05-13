import AppKit

final class OverlayWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void
    let overlayView: OverlayView
    /// The screen the screenshot was taken from. We have to pin the window
    /// to this screen ourselves because AppKit's window-placement logic
    /// silently moves a borderless screen-shielding window onto the active
    /// display when it would otherwise land on a screen with a
    /// negative-origin frame (which the built-in display has in setups
    /// where the external monitor is the macOS Main display).
    private let targetScreen: NSScreen

    init(image: NSImage, screen: NSScreen, onClose: @escaping () -> Void) {
        self.onClose = onClose
        self.targetScreen = screen
        self.overlayView = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size),
                                       image: image)

        // Initial contentRect is at the screen's origin in *Cocoa global
        // coordinates*. For a non-main display with a negative-origin
        // frame, `NSWindow.setFrame` has been observed to silently clip
        // back to the main display; the `setFrameOrigin` /
        // `setContentSize` pair used in `show()` doesn't have that
        // failure mode.
        let panel = OverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // `.screenSaver` is the highest standard NSWindow level and is
        // not treated specially by AppKit's display-placement logic.
        // `CGShieldingWindowLevel()` (previously used here) lives in a
        // private band that AppKit appears to associate with the active
        // display — when the screenshot came from a non-active display,
        // the shielding-level window kept snapping back to the active
        // one regardless of the frame we set.
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        // Drop `.fullScreenAuxiliary` — it implies "auxiliary to a
        // full-screen window on the active display" and contributes to
        // the active-display snap behaviour. `.canJoinAllSpaces` plus
        // `.stationary` are enough for the overlay to live anywhere.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.acceptsMouseMovedEvents = true
        // Skip the default fade-in so the frozen screenshot doesn't visibly
        // pop on top of the live screen — we want a hard, immediate swap.
        panel.animationBehavior = .none
        // Window lifetime is owned by this controller, so don't let AppKit
        // double-release the panel when the close cascade runs.
        panel.isReleasedWhenClosed = false
        panel.contentView = overlayView

        super.init(window: panel)
        panel.delegate = self
        overlayView.onDismiss = { [weak self] in self?.close() }
        overlayView.startDetection()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        guard let window else { return }
        // Apply geometry in pieces. `setFrame` runs through AppKit's
        // "constrain to a valid screen" logic, and on some extended-
        // display layouts that logic ignores `constrainFrameRect` and
        // silently clips the frame back to the active screen.
        // `setContentSize` + `setFrameOrigin` together set the same
        // frame without that auto-clipping pass.
        window.setContentSize(targetScreen.frame.size)
        window.setFrameOrigin(targetScreen.frame.origin)

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // Re-apply once more on the next run-loop tick. By the time this
        // closure runs, `makeKeyAndOrderFront` has finished its own
        // placement logic — including any active-display snap — and the
        // window is fully on-screen. Calling `setFrameOrigin` here
        // unconditionally moves the window to the screen we actually
        // want, overriding whatever AppKit decided.
        DispatchQueue.main.async { [weak self] in
            guard let self, let w = self.window else { return }
            w.setContentSize(self.targetScreen.frame.size)
            w.setFrameOrigin(self.targetScreen.frame.origin)
        }

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

    /// Disable AppKit's auto-constrain pass — we set the frame to the
    /// exact screen we want and don't want it second-guessed.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }
}
