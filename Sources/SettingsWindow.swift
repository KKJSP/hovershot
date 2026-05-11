import AppKit

private let aboutText: String =
    "HoverShot is a screenshot tool that detects on-screen elements and lets you "
    + "select them by hovering. The shortcuts below apply while the capture overlay "
    + "is active."

private let boxSizeHint =
    "Lower values produce smaller individual boxes; higher values merge adjacent "
    + "elements."

/// Display order for the shortcut list — separate from the enum's case order so
/// it can group "global" before "overlay".
private let shortcutOrder: [ShortcutAction] = [
    .takeShot, .save, .copy, .preview, .toggleFlow, .toggleAutocluster, .dismiss,
]

/// `NSTextFieldCell` draws and edits text from the cell frame's top edge. With
/// the bezel turned off and a manually enlarged height we end up with the
/// integer hugging the top of the box; this cell vertically centres both the
/// drawn text and the live field-editor frame.
private final class VerticallyCenteredTextFieldCell: NSTextFieldCell {
    private func centered(_ rect: NSRect) -> NSRect {
        let textHeight = cellSize(forBounds: rect).height
        let extraY = max(0, (rect.height - textHeight) / 2)
        var r = rect
        r.origin.y += extraY
        r.size.height = textHeight
        return r
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        super.drawingRect(forBounds: centered(rect))
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView,
                       editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: centered(rect), in: controlView,
                   editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView,
                         editor textObj: NSText, delegate: Any?,
                         start selStart: Int, length selLength: Int) {
        super.select(withFrame: centered(rect), in: controlView,
                     editor: textObj, delegate: delegate,
                     start: selStart, length: selLength)
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private var folderField: NSTextField!
    private var debugCheckbox: NSButton!
    private var sizeSlider: NSSlider!
    private var sizeValueLabel: NSTextField!
    private var recorders: [ShortcutAction: ShortcutRecorderView] = [:]
    private var paddingField: NSTextField!
    private var paddingHint: NSTextField!
    private var paddingValueOnFocus: Int = 0
    private var clickMonitor: Any?
    /// Fired after the window closes so the owner (`AppController`) can drop
    /// its strong reference and let the controller deallocate, releasing the
    /// NSEvent monitor + retained UI tree.
    var onClose: (() -> Void)?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 800),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "HoverShot Settings"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        window.delegate = self
        buildContent()
        installClickOutsideMonitor()
    }

    deinit {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    }

    /// Resign active status when the user closes the settings window.
    /// `NSEvent.addGlobalMonitorForEvents` (used by the global hotkey) only
    /// fires for events bound for *other* apps, so if HoverShot stays the
    /// frontmost app after closing settings the take-screenshot shortcut
    /// silently no-ops until the user clicks somewhere else. Hiding here
    /// hands focus back immediately.
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        let onClose = self.onClose
        DispatchQueue.main.async {
            NSApp.hide(nil)
            // Drop the cached controller so deinit fires, removing the
            // NSEvent monitor and freeing the UI tree. The dialog gets
            // rebuilt cheaply on the next Settings… invocation.
            onClose?()
        }
    }

    /// Commit the padding-field edit when the user clicks anywhere in the
    /// settings window that isn't the field itself. Without this, the value
    /// only commits on Tab/Return or when another control takes first responder.
    private func installClickOutsideMonitor() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
            [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            guard let field = self.paddingField,
                  window.firstResponder !== field,
                  // The field editor is the actual first responder while editing —
                  // detect "currently editing the padding field" by checking that.
                  let editor = window.fieldEditor(false, for: field) as? NSTextView,
                  window.firstResponder === editor
            else { return event }

            let pointInField = field.convert(event.locationInWindow, from: nil)
            if !field.bounds.contains(pointInField) {
                window.makeFirstResponder(nil)
            }
            return event
        }
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }

        let hPad: CGFloat = 24
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: hPad),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -hPad),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])

        func addFullWidth(_ view: NSView) {
            stack.addArrangedSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        // About.
        addFullWidth(makeLabel("About", bold: true))
        let about = makeLabel(aboutText, bold: false)
        about.maximumNumberOfLines = 0
        about.lineBreakMode = .byWordWrapping
        about.preferredMaxLayoutWidth = 540 - 2 * hPad
        addFullWidth(about)

        addFullWidth(separator())

        // Shortcuts.
        addFullWidth(makeLabel("Keyboard shortcuts", bold: true))
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 6
        grid.columnSpacing = 24
        for action in shortcutOrder {
            let nameLabel = makeLabel(action.displayName, bold: false)
            let recorder = ShortcutRecorderView(shortcut: Config.shortcut(for: action))
            recorder.onChange = { [weak self] proposed in
                self?.applyShortcutChange(action, proposed: proposed) ?? false
            }
            recorders[action] = recorder
            grid.addRow(with: [nameLabel, recorder])
        }
        if let column = grid.column(at: 1) as NSGridColumn? {
            column.xPlacement = .trailing
        }
        addFullWidth(grid)

        addFullWidth(separator())

        // Save folder.
        addFullWidth(makeLabel("Save folder", bold: true))
        let folderRow = NSStackView()
        folderRow.orientation = .horizontal
        folderRow.spacing = 8
        folderRow.alignment = .centerY
        folderField = NSTextField(string: Config.saveFolder.path)
        folderField.isEditable = false
        folderField.isSelectable = true
        folderField.lineBreakMode = .byTruncatingMiddle
        folderField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let browse = NSButton(title: "Browse…", target: self, action: #selector(pickFolder))
        browse.bezelStyle = .rounded
        browse.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        folderRow.addArrangedSubview(folderField)
        folderRow.addArrangedSubview(browse)
        addFullWidth(folderRow)

        addFullWidth(separator())

        // Box size.
        let sizeHeader = NSStackView()
        sizeHeader.orientation = .horizontal
        sizeHeader.alignment = .centerY
        sizeHeader.spacing = 8
        let sizeTitle = makeLabel("Box size", bold: true)
        sizeValueLabel = NSTextField(labelWithString: percentString(Config.boxSize))
        sizeValueLabel.alignment = .right
        sizeValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize,
                                                                weight: .regular)
        sizeValueLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        sizeHeader.addArrangedSubview(sizeTitle)
        sizeHeader.addArrangedSubview(NSView())
        sizeHeader.addArrangedSubview(sizeValueLabel)
        addFullWidth(sizeHeader)

        // Slider range is internally 0…2 so the old "100% = 1.0" setting now
        // sits at the slider's halfway mark and there's twice as much headroom
        // above it. The percent display below renormalises the value back to
        // 0…100% for the label so the UI still reads as a single percentage.
        sizeSlider = NSSlider(value: Config.boxSize, minValue: 0.0, maxValue: 2.0,
                              target: self, action: #selector(boxSizeChanged(_:)))
        sizeSlider.numberOfTickMarks = 11
        sizeSlider.allowsTickMarkValuesOnly = false
        sizeSlider.isContinuous = true
        addFullWidth(sizeSlider)

        let sizeHint = makeLabel(boxSizeHint, bold: false)
        sizeHint.maximumNumberOfLines = 0
        sizeHint.lineBreakMode = .byWordWrapping
        sizeHint.preferredMaxLayoutWidth = 540 - 2 * hPad
        sizeHint.textColor = .secondaryLabelColor
        sizeHint.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        addFullWidth(sizeHint)

        addFullWidth(separator())

        // Padding (integer, in pixels). No NumberFormatter — we validate manually
        // so non-numeric input can be flagged with a red border + inline hint.
        let paddingRow = NSStackView()
        paddingRow.orientation = .horizontal
        paddingRow.spacing = 8
        paddingRow.alignment = .centerY
        let paddingTitle = makeLabel("Selection padding (pixels)", bold: true)
        paddingTitle.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        paddingField = NSTextField()
        let centeredCell = VerticallyCenteredTextFieldCell(textCell: "")
        centeredCell.isEditable = true
        centeredCell.isSelectable = true
        centeredCell.isScrollable = true
        centeredCell.usesSingleLineMode = true
        paddingField.cell = centeredCell
        paddingField.alignment = .center
        paddingField.placeholderString = "\(Config.defaultPadding)"
        paddingField.stringValue = "\(Config.padding)"
        paddingField.delegate = self
        paddingField.isBezeled = false
        paddingField.isBordered = false
        paddingField.drawsBackground = false
        paddingField.translatesAutoresizingMaskIntoConstraints = false
        paddingField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        // Taller hit-target so the field doesn't feel cramped next to the bold
        // title and the rest of the controls.
        paddingField.heightAnchor.constraint(equalToConstant: 28).isActive = true
        paddingField.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize,
                                                              weight: .regular)
        paddingField.wantsLayer = true
        paddingField.layer?.cornerRadius = 4
        paddingField.layer?.borderWidth = 1
        paddingField.layer?.borderColor = NSColor.separatorColor.cgColor
        paddingField.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        paddingHint = makeLabel("", bold: false)
        paddingHint.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        paddingHint.textColor = .systemRed
        paddingHint.translatesAutoresizingMaskIntoConstraints = false
        // Reserve a fixed slot to the *left* of the field for the hint so the
        // field stays at the row's trailing edge regardless of error state.
        paddingHint.widthAnchor.constraint(equalToConstant: 160).isActive = true
        paddingHint.alignment = .right

        // Flex spacer pushes the hint + field to the trailing edge while the
        // title hugs the leading edge.
        let paddingSpacer = NSView()
        paddingSpacer.translatesAutoresizingMaskIntoConstraints = false

        paddingRow.addArrangedSubview(paddingTitle)
        paddingRow.addArrangedSubview(paddingSpacer)
        paddingRow.addArrangedSubview(paddingHint)
        paddingRow.addArrangedSubview(paddingField)
        addFullWidth(paddingRow)

        addFullWidth(separator())

        // Debug.
        debugCheckbox = NSButton(checkboxWithTitle: "Debug mode",
                                 target: self,
                                 action: #selector(toggleDebug(_:)))
        debugCheckbox.state = Config.debug ? .on : .off
        addFullWidth(debugCheckbox)

        // Flexible spacer so the credits link gets pushed to the very bottom of
        // the window content, regardless of how the rows above sized themselves.
        let flexSpacer = NSView()
        flexSpacer.translatesAutoresizingMaskIntoConstraints = false
        flexSpacer.setContentHuggingPriority(.defaultLow - 1, for: .vertical)
        flexSpacer.heightAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
        stack.addArrangedSubview(flexSpacer)
        flexSpacer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Credits link — anchored to the bottom of the dialog.
        let creditsRow = NSStackView()
        creditsRow.orientation = .horizontal
        creditsRow.alignment = .centerY
        let creditsSpacerL = NSView()
        let credits = NSButton(title: "By Saurabh Parikh",
                               target: self, action: #selector(openCredits))
        credits.bezelStyle = .inline
        credits.isBordered = false
        credits.contentTintColor = .linkColor
        credits.attributedTitle = NSAttributedString(
            string: "By Saurabh Parikh",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
        )
        let creditsSpacerR = NSView()
        creditsRow.addArrangedSubview(creditsSpacerL)
        creditsRow.addArrangedSubview(credits)
        creditsRow.addArrangedSubview(creditsSpacerR)
        creditsSpacerL.widthAnchor.constraint(equalTo: creditsSpacerR.widthAnchor).isActive = true
        addFullWidth(creditsRow)
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    private func makeLabel(_ text: String, bold: Bool) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        if bold { label.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize) }
        return label
    }

    // MARK: - Shortcut changes

    /// Returns `true` to accept the proposed shortcut. Rejects if it duplicates
    /// an existing binding for a different action (alerts the user) or matches
    /// the binding being edited (no-op accept).
    private func applyShortcutChange(_ action: ShortcutAction, proposed: Shortcut) -> Bool {
        for other in ShortcutAction.allCases where other != action {
            if Config.shortcut(for: other) == proposed {
                let alert = NSAlert()
                alert.messageText = "Shortcut already in use"
                alert.informativeText = "‘\(proposed.displayString)’ is bound to "
                    + "‘\(other.displayName)’. Pick a different combination."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return false
            }
        }
        Config.setShortcut(proposed, for: action)
        return true
    }

    // MARK: - Other settings

    @objc private func pickFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose save folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = Config.saveFolder
        if panel.runModal() == .OK, let url = panel.url {
            Config.saveFolder = url
            folderField.stringValue = Config.saveFolder.path
        }
    }

    @objc private func toggleDebug(_ sender: NSButton) {
        Config.debug = (sender.state == .on)
    }

    @objc private func boxSizeChanged(_ sender: NSSlider) {
        let v = sender.doubleValue
        Config.boxSize = v
        sizeValueLabel.stringValue = percentString(v)
    }

    private func percentString(_ value: Double) -> String {
        // Slider value lives in 0…2 (see `sizeSlider` setup) so the displayed
        // percent is half the raw value — keeps the label as a familiar
        // 0–100% number while the underlying multiplier keeps its full range.
        String(format: "%.0f%%", value * 50)
    }

    @objc private func openCredits() {
        if let url = URL(string: "https://github.com/KKJSP/hovershot") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - NSTextFieldDelegate

    /// Snapshot the value when editing starts so we can revert to it if the user
    /// commits an invalid value (or dismisses the field by clicking elsewhere).
    func controlTextDidBeginEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === paddingField else { return }
        paddingValueOnFocus = Config.padding
        clearPaddingError()
    }

    /// Live validation while the user types: red border + hint when the input
    /// can't be parsed as a non-negative number.
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === paddingField else { return }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            clearPaddingError()
        } else if let v = Double(trimmed.replacingOccurrences(of: ",", with: ".")), v >= 0 {
            clearPaddingError()
        } else {
            showPaddingError("enter a number")
        }
    }

    /// Final validation when the field loses focus (Tab, Return, or a click
    /// elsewhere in the dialog). Floats are rounded to the nearest integer; any
    /// truly invalid input reverts to the value that was active when editing
    /// began, matching the user's expectation of "old value if not a number".
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === paddingField else { return }
        let trimmed = field.stringValue
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")

        if let v = Double(trimmed), v >= 0 {
            let rounded = max(0, Int(v.rounded()))
            Config.padding = rounded
            field.stringValue = "\(rounded)"
        } else {
            // Empty or non-numeric → revert to the value the field had on focus.
            field.stringValue = "\(paddingValueOnFocus)"
        }
        clearPaddingError()
    }

    private func showPaddingError(_ message: String) {
        paddingHint?.stringValue = message
        paddingField.layer?.borderColor = NSColor.systemRed.cgColor
        paddingField.layer?.borderWidth = 2
    }

    private func clearPaddingError() {
        paddingHint?.stringValue = ""
        paddingField.layer?.borderColor = NSColor.separatorColor.cgColor
        paddingField.layer?.borderWidth = 1
    }
}
