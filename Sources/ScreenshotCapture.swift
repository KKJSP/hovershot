import AppKit

enum ScreenshotCapture {
    /// Captures a single screen using the system `screencapture` binary, exactly
    /// like the Python version. Returns the freshly captured image.
    static func captureScreen(_ screen: NSScreen) -> NSImage? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
        let displayID = number.uint32Value

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hovershot_\(UUID().uuidString).png")

        let task = Process()
        task.launchPath = "/usr/sbin/screencapture"
        task.arguments = ["-x", "-D", String(displayID), tmp.path]

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }

        defer { try? FileManager.default.removeItem(at: tmp) }
        guard task.terminationStatus == 0 else { return nil }
        return NSImage(contentsOf: tmp)
    }
}
