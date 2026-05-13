import AppKit
import CoreGraphics

enum ScreenshotCapture {
    /// Capture a specific `NSScreen` to an `NSImage`.
    ///
    /// We use `CGDisplayCreateImage` rather than the `screencapture` CLI
    /// here on purpose. `screencapture -D <n>` interprets `<n>` as a
    /// 1-based display *index* counted from the system "Main" display,
    /// not as the `CGDirectDisplayID` returned by
    /// `NSScreen.deviceDescription["NSScreenNumber"]`. When the main
    /// display is the external monitor and the user takes a shot on the
    /// built-in display, the `CGDirectDisplayID` (a large opaque
    /// integer) doesn't match any index, so `screencapture` silently
    /// falls back to display 1 — which is the main display, *not* the
    /// one the user is on. That's exactly the "screenshot of the wrong
    /// monitor" symptom we saw on extended-display setups.
    ///
    /// `CGDisplayCreateImage` takes the `CGDirectDisplayID` directly and
    /// returns an image of the matching display, with no ambiguity. It's
    /// marked deprecated in macOS 14 in favour of ScreenCaptureKit, but
    /// still functional, and ScreenCaptureKit is an async API that would
    /// require a bigger refactor.
    static func captureScreen(_ screen: NSScreen) -> NSImage? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
        let displayID = CGDirectDisplayID(number.uint32Value)

        guard let cgImage = CGDisplayCreateImage(displayID) else { return nil }

        // Wrap with the screen's logical (point) size. `cgImage` itself
        // is at the display's physical pixel resolution (2x on Retina);
        // `NSImage.init(cgImage:size:)` keeps both representations and
        // scales correctly when drawn into the overlay view.
        return NSImage(cgImage: cgImage, size: screen.frame.size)
    }
}
