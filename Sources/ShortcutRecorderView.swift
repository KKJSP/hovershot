import AppKit

/// Compact pill-shaped control that displays the current shortcut and accepts
/// a new key chord when clicked. Reports proposed bindings via `onChange`,
/// which returns `true` to accept or `false` to reject (used for conflict
/// detection by the settings window).
final class ShortcutRecorderView: NSView {
    var shortcut: Shortcut {
        didSet { needsDisplay = true }
    }

    /// Called when the user presses a new chord. Return `true` to accept and
    /// commit the change, `false` to reject (and keep the previous binding).
    var onChange: ((Shortcut) -> Bool)?

    private(set) var isRecording = false {
        didSet { needsDisplay = true }
    }

    init(shortcut: Shortcut) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 130, height: 26) }

    // MARK: - Focus / mouse

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        needsDisplay = true
        return ok
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        if isRecording {
            isRecording = false
            window?.makeFirstResponder(nil)
        } else {
            window?.makeFirstResponder(self)
            isRecording = true
        }
    }

    // MARK: - Key capture

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }

        let mods = event.modifierFlags.intersection(Shortcut.relevantModifierMask)

        // Every keystroke records — including Esc, since that's a perfectly valid
        // shortcut (e.g., the dismiss action). To cancel without recording, click
        // outside the recorder and `resignFirstResponder` clears the recording state.
        let baseChar = event.characters(byApplyingModifiers: [])
            ?? event.charactersIgnoringModifiers
            ?? ""
        let proposed = Shortcut(
            keyCode: event.keyCode,
            modifierFlags: mods,
            character: baseChar
        )

        if onChange?(proposed) == true {
            shortcut = proposed
        }
        isRecording = false
        window?.makeFirstResponder(nil)
    }

    /// Modifier-only presses arrive as `flagsChanged`; we ignore them. The
    /// recorder commits only on a real `keyDown`.
    override func flagsChanged(with event: NSEvent) {
        if isRecording { needsDisplay = true }
        super.flagsChanged(with: event)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                xRadius: 6, yRadius: 6)

        let fill: NSColor
        let stroke: NSColor
        let lineWidth: CGFloat

        if isRecording {
            fill = NSColor.controlAccentColor.withAlphaComponent(0.18)
            stroke = NSColor.controlAccentColor
            lineWidth = 2
        } else {
            fill = NSColor.controlBackgroundColor
            stroke = NSColor.separatorColor
            lineWidth = 1
        }

        fill.setFill(); path.fill()
        stroke.setStroke(); path.lineWidth = lineWidth; path.stroke()

        let text = isRecording ? "Press a key…" : shortcut.displayString
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: isRecording ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        let attr = NSAttributedString(string: text, attributes: attrs)
        let size = attr.size()
        let textRect = NSRect(x: (bounds.width - size.width) / 2,
                              y: (bounds.height - size.height) / 2,
                              width: size.width, height: size.height)
        attr.draw(in: textRect)
    }
}
