import AppKit

// MARK: - Lightweight rect animator (replacement for Qt's QVariantAnimation).

private final class RectAnimator {
    enum Easing { case outCubic, inOutQuad, linear }

    typealias Tick = (CGRect) -> Void
    typealias Done = () -> Void

    private var startTime: CFTimeInterval = 0
    private var duration: CFTimeInterval = 0
    private var easing: Easing = .outCubic
    private var keyframes: [(t: Double, rect: CGRect)] = []
    private var timer: Timer?
    /// Where the animator is heading. Writable so that callers performing a
    /// no-animation snap (e.g. during a live drag) can keep the bookkeeping
    /// in sync — otherwise a subsequent `start()` whose target equals a
    /// *previous* animation's end rect short-circuits and no animation runs.
    var endRect: CGRect = .zero
    var onTick: Tick?
    var onFinished: Done?

    func start(duration: CFTimeInterval, easing: Easing,
               keyframes: [(t: Double, rect: CGRect)]) {
        stop()
        guard let last = keyframes.last else { return }
        self.duration = duration
        self.easing = easing
        self.keyframes = keyframes
        self.endRect = last.rect
        self.startTime = CACurrentMediaTime()

        // The closure captures `self` weakly so the animator can be
        // deallocated even while the timer is "live"; on the first tick
        // after dealloc the timer invalidates itself instead of leaking
        // into the run loop forever.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.tick(t: t)
        }
        // Run on common modes so it doesn't pause while menus are open.
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit { stop() }

    private func tick(t: Timer) {
        let elapsed = CACurrentMediaTime() - startTime
        var p = duration > 0 ? min(1.0, elapsed / duration) : 1.0
        switch easing {
        case .outCubic:
            let inv = 1 - p
            p = 1 - inv * inv * inv
        case .inOutQuad:
            p = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
        case .linear:
            break
        }
        onTick?(interpolate(p))
        if elapsed >= duration {
            stop()
            onFinished?()
        }
    }

    private func interpolate(_ p: Double) -> CGRect {
        guard let first = keyframes.first else { return .zero }
        if keyframes.count == 1 { return first.rect }
        // Find segment.
        for i in 1..<keyframes.count {
            if p <= keyframes[i].t {
                let a = keyframes[i - 1]
                let b = keyframes[i]
                let span = b.t - a.t
                let local = span > 0 ? (p - a.t) / span : 1
                return lerp(a.rect, b.rect, local)
            }
        }
        return keyframes.last!.rect
    }

    private func lerp(_ a: CGRect, _ b: CGRect, _ t: Double) -> CGRect {
        CGRect(
            x: a.minX + (b.minX - a.minX) * t,
            y: a.minY + (b.minY - a.minY) * t,
            width:  a.width  + (b.width  - a.width)  * t,
            height: a.height + (b.height - a.height) * t
        )
    }
}

// MARK: - Overlay view

final class OverlayView: NSView {
    var onDismiss: (() -> Void)?

    // Inputs.
    private let capturedImage: NSImage
    private let capturedCG: CGImage?
    private let imagePixelSize: CGSize
    private let previousApp: NSRunningApplication?

    // Detection results, scaled to the view's coordinate system (top-left origin).
    private var boxes: [Box] = []
    private var network: [Box: [Box]] = [:]
    private var detecting: Bool = true

    // Selection state.
    private var selectedBoxes: [Box] = []
    private var hoveredBox: Box?
    private var autocluster: Bool = true
    private var flowmode: Bool = false

    // Strict and padded encompassing rectangles in view space.
    private var encRect: CGRect?
    private var paddedRect: CGRect?
    private var animRect: CGRect?
    private let boxAnimator = RectAnimator()

    // Drag-to-create-box. When `customBox` is non-nil it overrides the detected
    // selection — drawing, save and copy all use it. After the mouse is released
    // it stays put; once the cursor moves *inside* a detected box the selection
    // morphs to that box (animated by the regular box-animator).
    private var customBox: CGRect?
    private var dragStartPoint: CGPoint?
    private var isDragging: Bool = false
    private let dragThreshold: CGFloat = 6

    // Scan-line reveal — one direction only, left→right, kicks off after detection.
    private var scanX: CGFloat = 0
    private var scanTimer: Timer?

    // Notification overlay.
    private var notificationText: String?
    private var notificationAlpha: CGFloat = 0
    private var notificationTimer: Timer?
    private var notificationStart: CFTimeInterval = 0

    private var trackingArea: NSTrackingArea?

    // MARK: - Init

    init(frame frameRect: NSRect, image: NSImage) {
        self.capturedImage = image
        self.previousApp = NSWorkspace.shared.frontmostApplication

        var rect = NSRect(origin: .zero, size: image.size)
        let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        self.capturedCG = cg
        self.imagePixelSize = cg.map { CGSize(width: $0.width, height: $0.height) } ?? image.size

        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        scanX = 0

        boxAnimator.onTick = { [weak self] r in
            self?.animRect = r
            self?.needsDisplay = true
        }
        boxAnimator.onFinished = { [weak self] in
            // Mirrors `_on_anim_finished` — clear the box once the shrink finishes.
            guard let self else { return }
            if self.encRect == nil {
                self.animRect = nil
                self.needsDisplay = true
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        // Belt-and-braces cleanup so any in-flight timer is removed from the
        // run loop the instant the view goes away. The closures already use
        // `[weak self]` and self-invalidate, but invalidating here releases
        // the timer immediately rather than waiting for its next fire.
        scanTimer?.invalidate()
        notificationTimer?.invalidate()
        boxAnimator.stop()
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .mouseMoved,
                                            .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Detection

    func startDetection() {
        guard let cg = capturedCG else { detecting = false; startReveal(); return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // The pipeline allocates several full-frame UInt8 planes plus a
            // `CGContext`. Without an explicit pool the autoreleased buffers
            // sit on the GCD worker thread until it's recycled, which tends
            // to look like a steady leak. The pool drains the moment the
            // closure returns.
            autoreleasepool {
                var finder = BoxFinder()
                let result = finder.detect(in: cg)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.adoptDetection(result)
                    self.startReveal()
                }
            }
        }
    }

    private func adoptDetection(_ result: DetectionResult) {
        let sx = bounds.width  / imagePixelSize.width
        let sy = bounds.height / imagePixelSize.height
        let scale = (Double(sx), Double(sy))

        // Scale every Box once into view space (Python does the same in `process_atomic_scan`).
        let scaledBoxes = result.boxes.map { $0.scaled(scale) }
        var scaledNetwork: [Box: [Box]] = [:]
        for (key, neighbours) in result.network {
            let nk = key.scaled(scale)
            scaledNetwork[nk] = neighbours.map { $0.scaled(scale) }
        }

        self.boxes = scaledBoxes
        self.network = scaledNetwork
        self.detecting = false
        self.needsDisplay = true
    }

    // MARK: - Scan reveal

    /// Starts after the detection finishes — sweeps a single line left→right,
    /// progressively unveiling the detected boxes on the revealed side.
    private func startReveal() {
        scanX = 0
        scanTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.tickScan()
        }
        if let scanTimer { RunLoop.main.add(scanTimer, forMode: .common) }
        needsDisplay = true
    }

    private func tickScan() {
        // Slow, deliberate reveal — the native pipeline finishes in a fraction
        // of the time so this animation no longer needs to mask latency.
        scanX = min(bounds.width, scanX + 50)
        if scanX >= bounds.width {
            scanTimer?.invalidate()
            scanTimer = nil
        }
        needsDisplay = true
    }

    private var scanActive: Bool { scanTimer != nil }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 1. Frozen screenshot. The `respectFlipped:` form is required because the
        //    short `draw(in:from:operation:fraction:)` ignores `isFlipped` and
        //    would render the image upside-down in this view.
        capturedImage.draw(in: bounds, from: .zero, operation: .copy, fraction: 1.0,
                           respectFlipped: true, hints: nil)

        // While detection is still running, leave the screen pristine — the
        // sweep that follows is what introduces the dim.
        if detecting { return }

        // 2. Reveal phase: dim only the area the scan line has passed over,
        //    leaving the un-revealed (right) side untouched. After the line
        //    reaches the right edge we fall through to the final state.
        let dimColor = NSColor.black.withAlphaComponent(128.0/255.0).cgColor
        if scanActive {
            ctx.setFillColor(dimColor)
            ctx.fill(CGRect(x: 0, y: 0, width: scanX, height: bounds.height))

            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(7)
            ctx.move(to: CGPoint(x: scanX, y: 0))
            ctx.addLine(to: CGPoint(x: scanX, y: bounds.height))
            ctx.strokePath()

            drawDetectedBoxes(ctx: ctx, clipRight: scanX)
            return
        }

        // 3. Final state: full dim with a rounded cut-out for the selection.
        // Drag mode is always square; cluster selections shrink the corner
        // radius alongside the padding so a tight crop doesn't get a corner
        // that overshoots the visible area.
        let radius: CGFloat = customBox != nil ? 0 : min(CGFloat(Config.padding), 12)
        let outer = CGPath(rect: bounds, transform: nil)
        let path = CGMutablePath()
        path.addPath(outer)
        if let anim = animRect {
            if radius > 0 {
                path.addRoundedRect(in: anim, cornerWidth: radius, cornerHeight: radius)
            } else {
                path.addRect(anim)
            }
        }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setFillColor(dimColor)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()

        if let anim = animRect {
            // Flow-mode orange is reserved for detection-driven selections.
            // A manual drag-out rectangle stays neutral white even when
            // flow mode is on: the orange is a signal that the underlying
            // selection is following the detected box graph, and a custom
            // box is precisely the user opting out of that.
            let isManual = customBox != nil
            let usingFlowStyle = flowmode && !isManual
            let lineWidth: CGFloat = usingFlowStyle ? 3 : 2
            if usingFlowStyle {
                ctx.setStrokeColor(Config.Palette.primary.cgColor)
            } else {
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(200.0/255.0).cgColor)
            }
            ctx.setLineWidth(lineWidth)
            // Outset the stroke path by half its line width so the border sits
            // entirely outside the cut-out — the screenshot inside the box stays
            // fully visible, with no stroke chewing into the content.
            let outset = lineWidth / 2
            let strokeRect = anim.insetBy(dx: -outset, dy: -outset)
            let strokePath: CGPath
            if radius > 0 {
                strokePath = CGPath(roundedRect: strokeRect,
                                    cornerWidth: radius + outset,
                                    cornerHeight: radius + outset,
                                    transform: nil)
            } else {
                strokePath = CGPath(rect: strokeRect, transform: nil)
            }
            ctx.addPath(strokePath)
            ctx.strokePath()
        }

        drawDetectedBoxes(ctx: ctx, clipRight: bounds.width)

        if let hovered = hoveredBox, selectedBoxes.contains(hovered),
           autocluster, !flowmode, Config.debug {
            drawConnectionLines(ctx: ctx, from: hovered)
        }

        if let text = notificationText, notificationAlpha > 0 {
            drawNotice(text, alpha: notificationAlpha)
        }
    }

    /// Renders the faint outlines for all detected boxes plus the brighter
    /// strokes for the current selection / hovered root, clipped horizontally
    /// at `clipRight` (so the reveal sweep can show them progressively).
    private func drawDetectedBoxes(ctx: CGContext, clipRight: CGFloat) {
        @inline(__always) func clip(_ r: CGRect) -> CGRect? {
            guard r.minX < clipRight else { return nil }
            return CGRect(x: r.minX, y: r.minY,
                          width: min(r.width, clipRight - r.minX), height: r.height)
        }

        ctx.setStrokeColor(NSColor.white.withAlphaComponent(80.0/255.0).cgColor)
        ctx.setLineWidth(1)
        for box in boxes {
            if let c = clip(box.rect) { ctx.stroke(c) }
        }

        let selStroke = autocluster ? Config.Palette.secondary : Config.Palette.accent
        ctx.setStrokeColor(selStroke.cgColor)
        ctx.setLineWidth(2)
        for box in selectedBoxes {
            if let c = clip(box.rect) { ctx.stroke(c) }
        }

        if let hovered = hoveredBox, selectedBoxes.contains(hovered),
           let c = clip(hovered.rect) {
            ctx.setStrokeColor(NSColor.green.cgColor)
            ctx.setLineWidth(2)
            ctx.stroke(c)
        }
    }

    private func drawConnectionLines(ctx: CGContext, from start: Box) {
        var seen: Set<Box> = [start]
        var children = network[start] ?? []
        var parents: [Box] = Array(repeating: start, count: children.count)
        var depth = 0

        while !children.isEmpty {
            for (child, parent) in zip(children, parents) {
                let tint = NSColor(srgbRed: 1, green: min(CGFloat(depth) * 40 / 255, 1),
                                   blue: 0, alpha: 150.0 / 255.0)
                ctx.setStrokeColor(tint.cgColor)
                ctx.setLineWidth(2)
                ctx.move(to: CGPoint(x: CGFloat(parent.left + parent.right) / 2,
                                     y: CGFloat(parent.top  + parent.bottom) / 2))
                ctx.addLine(to: CGPoint(x: CGFloat(child.left  + child.right)  / 2,
                                        y: CGFloat(child.top   + child.bottom) / 2))
                ctx.strokePath()
                seen.insert(child)
            }
            var newChildren: [Box] = []
            var newParents: [Box] = []
            for child in children {
                for box in network[child] ?? [] where !seen.contains(box) {
                    seen.insert(box)
                    newChildren.append(box)
                    newParents.append(child)
                }
            }
            children = newChildren
            parents = newParents
            depth += 1
        }
    }

    private func drawNotice(_ text: String, alpha: CGFloat) {
        let font = NSFont.systemFont(ofSize: 16)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: Config.Palette.primary.withAlphaComponent(alpha),
        ]
        let attr = NSAttributedString(string: text, attributes: attrs)
        let size = attr.size()
        let bgW = size.width + 40
        let bgH = size.height + 20
        let rect = NSRect(
            x: (bounds.width - bgW) / 2,
            y: bounds.height * 0.8 - bgH,
            width: bgW, height: bgH
        )

        let ctx = NSGraphicsContext.current!.cgContext
        ctx.setFillColor(Config.Palette.background.withAlphaComponent(alpha).cgColor)
        ctx.setStrokeColor(Config.Palette.darkAccent.withAlphaComponent(alpha).cgColor)
        ctx.setLineWidth(1)
        let path = CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil)
        ctx.addPath(path); ctx.fillPath()
        ctx.addPath(path); ctx.strokePath()

        let textRect = NSRect(
            x: rect.minX + (bgW - size.width) / 2,
            y: rect.minY + (bgH - size.height) / 2,
            width: size.width, height: size.height
        )
        attr.draw(in: textRect)
    }

    // MARK: - Hover / mouse

    override func mouseMoved(with event: NSEvent) {
        guard !scanActive, !isDragging else { return }
        let p = convert(event.locationInWindow, from: nil)
        let mx = p.x, my = p.y

        var bestDist = Double.greatestFiniteMagnitude
        var closest: Box?
        for box in boxes {
            let bx = Double(box.x), by = Double(box.y)
            let bw = Double(box.width), bh = Double(box.height)
            let dx = max(0, max(bx - mx, mx - (bx + bw)))
            let dy = max(0, max(by - my, my - (by + bh)))
            var dist = dx * dx + dy * dy
            if dist == 0 {
                let inside = min(mx - bx, (bx + bw) - mx,
                                 my - by, (by + bh) - my)
                dist = inside * inside
            }
            if dist <= bestDist {
                bestDist = dist
                if !flowmode || dist < 225 { closest = box }
            }
        }

        // Custom-box mode: stay put until the cursor moves inside *any* detected
        // box (smallest containing one wins), then morph back to the regular
        // cluster selection. Using `closest` alone occasionally missed a box
        // when the cursor sat just outside a small element while still inside
        // a larger enclosing one — switching to a containment scan catches
        // both the same-cluster and different-cluster cases.
        if customBox != nil {
            let containing = boxes
                .filter { $0.rect.contains(p) }
                .min(by: { $0.area < $1.area })
            if let target = containing {
                customBox = nil
                hoveredBox = target
                if flowmode {
                    selectedBoxes = [target]
                } else if autocluster {
                    selectedBoxes = expandCluster(from: target)
                } else {
                    selectedBoxes = [target]
                }
                updateEncompassingBox()
                needsDisplay = true
            }
            return
        }

        guard let closest, closest != hoveredBox else { return }
        hoveredBox = closest

        if flowmode {
            if !selectedBoxes.contains(closest) { selectedBoxes.append(closest) }
        } else if autocluster {
            selectedBoxes = expandCluster(from: closest)
        } else {
            selectedBoxes = [closest]
        }
        updateEncompassingBox()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard !scanActive else { return }
        // Pointer ↦ crosshair while the button is held, mirroring most
        // selection tools.
        NSCursor.crosshair.set()
        // Don't act yet — wait to see if this becomes a drag (custom box) or
        // stays a click (toggle of the hovered detected box).
        dragStartPoint = convert(event.locationInWindow, from: nil)
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !scanActive, let start = dragStartPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        let dx = abs(p.x - start.x)
        let dy = abs(p.y - start.y)

        if !isDragging && (dx > dragThreshold || dy > dragThreshold) {
            isDragging = true
            // Drag mode replaces any cluster selection.
            selectedBoxes = []
            hoveredBox = nil
        }
        if isDragging {
            customBox = CGRect(
                x: min(start.x, p.x), y: min(start.y, p.y),
                width:  dx, height: dy
            )
            // Snap directly while the user is still dragging — animation here
            // would just feel laggy.
            updateEncompassingBox(animated: false)
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard !scanActive else { dragStartPoint = nil; NSCursor.arrow.set(); return }
        defer { dragStartPoint = nil; isDragging = false; NSCursor.arrow.set() }

        if isDragging {
            // Custom box already populated by the drag. Keep it.
            return
        }

        // Plain click — clear any prior custom box and toggle the hovered box.
        if customBox != nil {
            customBox = nil
        }
        if let h = hoveredBox {
            if let i = selectedBoxes.firstIndex(of: h) {
                selectedBoxes.remove(at: i)
            } else {
                selectedBoxes.append(h)
            }
            selectedBoxes = selectedBoxes.filter { box in
                !selectedBoxes.contains(where: { $0 != box && $0.contains(box) })
            }
        }
        updateEncompassingBox()
        needsDisplay = true
    }

    private func expandCluster(from start: Box) -> [Box] {
        var seen: Set<Box> = [start]
        var children = network[start] ?? []
        while !children.isEmpty {
            for child in children { seen.insert(child) }
            var next: [Box] = []
            for child in children {
                for n in network[child] ?? [] where !seen.contains(n) {
                    seen.insert(n)
                    next.append(n)
                }
            }
            children = next
        }
        return Array(seen)
    }

    // MARK: - Encompassing box + animation

    private func updateEncompassingBox(animated: Bool = true) {
        // The strict rectangle is either the user-drawn custom box, or the
        // bounding box of the cluster selection — whichever is active.
        let strict: CGRect?
        if let custom = customBox {
            strict = custom
        } else if selectedBoxes.isEmpty {
            strict = nil
        } else {
            let lefts   = selectedBoxes.map { $0.left }
            let tops    = selectedBoxes.map { $0.top }
            let rights  = selectedBoxes.map { $0.right }
            let bottoms = selectedBoxes.map { $0.bottom }
            strict = CGRect(
                x: CGFloat(lefts.min()!),
                y: CGFloat(tops.min()!),
                width:  CGFloat(rights.max()!  - lefts.min()!),
                height: CGFloat(bottoms.max()! - tops.min()!)
            )
        }

        guard let strict else {
            // Shrink animation back to a point at the cursor.
            encRect = nil
            paddedRect = nil
            if let anim = animRect {
                let cursor = convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
                let target = CGRect(x: cursor.x, y: cursor.y, width: 0, height: 0)
                boxAnimator.start(duration: 0.15, easing: .outCubic,
                                  keyframes: [(0, anim), (1, target)])
            }
            return
        }
        encRect = strict

        // Drag-to-create boxes save exactly the rectangle the user drew —
        // padding is only for cluster-derived selections.
        let padding = customBox != nil ? CGFloat(0) : CGFloat(Config.padding)
        let padded = CGRect(
            x: max(0, strict.minX - padding),
            y: max(0, strict.minY - padding),
            width:  min(bounds.width,  strict.maxX + padding) - max(0, strict.minX - padding),
            height: min(bounds.height, strict.maxY + padding) - max(0, strict.minY - padding)
        )
        paddedRect = padded

        if boxAnimator.endRect == padded { return }

        if animated {
            let start = animRect ?? CGRect(
                x: convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil).x,
                y: convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil).y,
                width: 0, height: 0
            )
            boxAnimator.start(duration: 0.15, easing: .outCubic,
                              keyframes: [(0, start), (1, padded)])
        } else {
            boxAnimator.stop()
            // Keep the animator's `endRect` in lockstep with the snapped
            // value — otherwise the next `start()` whose target equals a
            // previous animation's end rect would early-return on the
            // `endRect == padded` guard and skip the morph back.
            boxAnimator.endRect = padded
            animRect = padded
        }
    }

    private func playSuccessFlash(then: (() -> Void)? = nil) {
        // `encRect` only matters for the "is there a selection" guard;
        // the midframe is now derived purely from `paddedRect` so the
        // shrink behaviour is uniform across cluster and manual cases.
        guard let padded = paddedRect, encRect != nil else { then?(); return }
        boxAnimator.onFinished = { [weak self] in
            self?.boxAnimator.onFinished = { [weak self] in
                guard let self else { return }
                if self.encRect == nil {
                    self.animRect = nil
                    self.needsDisplay = true
                }
            }
            then?()
        }

        // Always pulse inward by exactly 12 px regardless of padding —
        // the flicker is a fixed-magnitude confirmation animation, not
        // a function of the selection's own metrics. The midframe is
        // allowed to pass through and even past the strict content for
        // thin-padding or manual selections. If the box is smaller
        // than 24 px in either axis the midframe collapses to a
        // zero-size point in that axis and the animation bottoms out
        // at a point.
        let inset: CGFloat = 12
        let midW = max(0, padded.width  - 2 * inset)
        let midH = max(0, padded.height - 2 * inset)
        let mid = CGRect(
            x: padded.midX - midW / 2,
            y: padded.midY - midH / 2,
            width: midW, height: midH
        )
        boxAnimator.start(duration: 0.25, easing: .inOutQuad,
                          keyframes: [(0, padded), (0.5, mid), (1, padded)])
    }

    // MARK: - Keys

    override func keyDown(with event: NSEvent) {
        // Esc always dismisses, regardless of the user's shortcut
        if event.keyCode == 53 {
            dismiss()
        } else if Config.shortcut(for: .dismiss).matches(event) {
            dismiss()
        } else if Config.shortcut(for: .save).matches(event) {
            if paddedRect != nil { save() }
        } else if Config.shortcut(for: .copy).matches(event) {
            if paddedRect != nil { copyToClipboard() }
        } else if Config.shortcut(for: .preview).matches(event) {
            if paddedRect != nil { openInPreview() }
        } else if Config.shortcut(for: .toggleAutocluster).matches(event) {
            autocluster.toggle()
            recomputeAfterModeChange()
        } else if Config.shortcut(for: .toggleFlow).matches(event) {
            flowmode.toggle()
            recomputeAfterModeChange()
        } else {
            super.keyDown(with: event)
        }
    }

    private func recomputeAfterModeChange() {
        if autocluster {
            if let h = hoveredBox {
                selectedBoxes = expandCluster(from: h)
            } else {
                selectedBoxes = []
            }
        } else {
            selectedBoxes = hoveredBox.map { [$0] } ?? []
        }
        updateEncompassingBox()
        needsDisplay = true
    }

    // MARK: - Actions

    private func dismiss() {
        scanTimer?.invalidate(); scanTimer = nil
        boxAnimator.stop()
        notificationTimer?.invalidate(); notificationTimer = nil

        // Reactivate whatever app was foreground when the overlay launched.
        previousApp?.activate(options: [.activateIgnoringOtherApps])
        onDismiss?()
    }

    private func croppedImage() -> CGImage? {
        guard let cg = capturedCG, let padded = paddedRect else { return nil }
        let sx = imagePixelSize.width  / bounds.width
        let sy = imagePixelSize.height / bounds.height
        let cropRect = CGRect(
            x: padded.minX * sx,
            y: padded.minY * sy,
            width: padded.width  * sx,
            height: padded.height * sy
        ).integral.intersection(CGRect(origin: .zero, size: imagePixelSize))
        return cg.cropping(to: cropRect)
    }

    @discardableResult
    private func save() -> URL? {
        guard let cropped = croppedImage() else { NSSound.beep(); return nil }
        let ts = DateFormatter()
        ts.dateFormat = "yyyyMMdd_HHmmss"
        let folder = Config.saveFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Capture_\(ts.string(from: Date())).png")

        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, cropped, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }

        notify("Saved to: \(url.path)")
        playSuccessFlash()
        return url
    }

    private func copyToClipboard() {
        guard let cropped = croppedImage() else { return }
        let rep = NSBitmapImageRep(cgImage: cropped)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([img])
        notify("Copied image to clipboard")
        playSuccessFlash()
    }

    private func openInPreview() {
        guard let url = save() else { return }
        // Wait for the success flash to finish, then open + dismiss.
        playSuccessFlash { [weak self] in
            NSWorkspace.shared.open([url],
                                    withApplicationAt: URL(fileURLWithPath: "/System/Applications/Preview.app"),
                                    configuration: NSWorkspace.OpenConfiguration()) { _, _ in
                DispatchQueue.main.async { self?.dismiss() }
            }
        }
    }

    // MARK: - Notification

    private func notify(_ text: String) {
        notificationText = text
        notificationStart = CACurrentMediaTime()
        notificationTimer?.invalidate()
        notificationTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.tickNotification(t: t)
        }
        if let notificationTimer { RunLoop.main.add(notificationTimer, forMode: .common) }
    }

    private func tickNotification(t: Timer) {
        let elapsed = CACurrentMediaTime() - notificationStart
        let total: CFTimeInterval = 2.5
        // Same envelope as Python's _message_anim: 0→255 at 10%, hold to 70%, fade out.
        let p = elapsed / total
        let alpha: CGFloat
        switch p {
        case ..<0.1:
            alpha = CGFloat(p / 0.1)
        case 0.1..<0.7:
            alpha = 1
        case 0.7..<1.0:
            alpha = CGFloat((1 - p) / 0.3)
        default:
            alpha = 0
        }
        notificationAlpha = max(0, min(1, alpha))
        if elapsed >= total {
            t.invalidate()
            notificationTimer = nil
            notificationText = nil
            notificationAlpha = 0
        }
        needsDisplay = true
    }
}
