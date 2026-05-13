import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes intermediate pipeline products directly into `<saveFolder>/` when
/// debug mode is on:
///   * `source.png`      — the captured frame
///   * `connections.png` — the final adjacency network as directed arrows,
///                         colour-coded by which constructor pass first
///                         added each edge, with faded red fills over
///                         regions classified as paragraphs (> 20 words).
enum DebugImageWriter {
    static func writeIfEnabled(
        source: CGImage,
        seas: [BoxFinder.Sea],
        network: [Box: [Box]],
        edgeOrigins: [BoxPair: EdgeOrigin],
        words: [RecognizedWord],
        lineToParagraph: [Int: Int],
        paragraphSize: [Int: Int]
    ) {
        guard Config.debug else { return }
        let dir = Config.saveFolder

        write(cgImage: source, to: dir.appendingPathComponent("source.png"))
        if let connectionsImg = renderConnections(on: source,
                                                  network: network,
                                                  edgeOrigins: edgeOrigins,
                                                  seas: seas,
                                                  words: words,
                                                  lineToParagraph: lineToParagraph,
                                                  paragraphSize: paragraphSize) {
            write(cgImage: connectionsImg, to: dir.appendingPathComponent("connections.png"))
        }
    }

    /// Deterministic per-sea palette used for box outlines.
    private static let seaPalette: [CGColor] = [
        CGColor(red: 1.00, green: 0.20, blue: 0.20, alpha: 1),
        CGColor(red: 0.20, green: 0.60, blue: 1.00, alpha: 1),
        CGColor(red: 0.20, green: 0.85, blue: 0.40, alpha: 1),
        CGColor(red: 1.00, green: 0.80, blue: 0.20, alpha: 1),
        CGColor(red: 0.85, green: 0.30, blue: 0.85, alpha: 1),
        CGColor(red: 0.30, green: 0.85, blue: 0.85, alpha: 1),
    ]

    /// Per-origin arrow palette. Picked for distinguishability over the
    /// faded source image: orange for the per-sea pairwise pass (the
    /// historical baseline colour), magenta for `connectAlignedSeries`,
    /// cyan-green for `connectCaptions`. An "unknown" fallback grey is
    /// emitted only if the GC misses an entry — useful as a
    /// self-diagnostic that the origin map is incomplete.
    private static let originPalette: [EdgeOrigin: CGColor] = [
        .pairwise:      CGColor(red: 1.00, green: 0.40, blue: 0.00, alpha: 1.0),
        .alignedSeries: CGColor(red: 0.95, green: 0.20, blue: 0.85, alpha: 1.0),
        .captions:      CGColor(red: 0.10, green: 0.85, blue: 0.55, alpha: 1.0),
        .bridges:       CGColor(red: 0.00, green: 0.00, blue: 0.00, alpha: 1.0),
    ]
    private static let unknownOriginColor = CGColor(red: 0.55, green: 0.55, blue: 0.55, alpha: 1.0)

    /// Threshold (in Vision-word count) above which a Vision-line group is
    /// treated as a paragraph and gets a faded fill in `3_connections.png`.
    /// Matches the gate used by `pruneParagraphAnchors` so the overlay
    /// shows exactly which groups that pass would treat as paragraphs.
    private static let paragraphMinWords = 20

    // MARK: - Image construction

    private static func renderConnections(on cgImage: CGImage,
                                          network: [Box: [Box]],
                                          edgeOrigins: [BoxPair: EdgeOrigin],
                                          seas: [BoxFinder.Sea],
                                          words: [RecognizedWord],
                                          lineToParagraph: [Int: Int],
                                          paragraphSize: [Int: Int]) -> CGImage? {
        let width = cgImage.width, height = cgImage.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
                 | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info
        ) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let imageH = CGFloat(height)
        @inline(__always) func cgCenter(_ box: Box) -> CGPoint {
            CGPoint(x: CGFloat(box.left + box.right) / 2,
                    y: imageH - CGFloat(box.top + box.bottom) / 2)
        }

        // Faded paragraph fills under everything so they don't obscure
        // box outlines or arrows. Captions are intentionally uncoloured.
        drawParagraphOverlays(ctx, imageHeight: height, words: words,
                              lineToParagraph: lineToParagraph,
                              paragraphSize: paragraphSize)

        // Map every box to its sea colour so outlines visually carry the
        // sea grouping (the old 2_seas.png view is now folded in here).
        var seaColor: [Box: CGColor] = [:]
        for (idx, sea) in seas.enumerated() {
            let colour = seaPalette[idx % seaPalette.count]
            for box in sea.members { seaColor[box] = colour }
        }
        let fallbackOutline = CGColor(red: 0.60, green: 0.60, blue: 0.60, alpha: 1.0)

        ctx.setLineWidth(2)
        for box in network.keys {
            ctx.setStrokeColor(seaColor[box] ?? fallbackOutline)
            let cgY = CGFloat(height - box.y - box.height)
            ctx.stroke(CGRect(x: CGFloat(box.x), y: cgY,
                              width: CGFloat(box.width), height: CGFloat(box.height)))
        }

        let arrowSize: CGFloat = 14
        var drawn = Set<BoxPair>()

        var counts: [EdgeOrigin: Int] = [
            .pairwise: 0, .alignedSeries: 0, .captions: 0, .bridges: 0,
        ]
        var unknownCount = 0

        for (from, neighbours) in network {
            for to in neighbours {
                let pair = BoxPair(from, to)
                if drawn.contains(pair) { continue }
                drawn.insert(pair)

                let forward = network[from]?.contains(to) ?? false
                let reverse = network[to]?.contains(from) ?? false

                let origin = edgeOrigins[pair]
                let lineColor = origin.flatMap { originPalette[$0] } ?? unknownOriginColor
                if let o = origin { counts[o, default: 0] += 1 } else { unknownCount += 1 }

                let p0 = cgCenter(from)
                let p1 = cgCenter(to)
                ctx.setStrokeColor(lineColor)
                ctx.setLineWidth(1)
                ctx.move(to: p0)
                ctx.addLine(to: p1)
                ctx.strokePath()

                if forward { drawArrow(ctx, tip: p1, from: p0, size: arrowSize, color: lineColor) }
                if reverse { drawArrow(ctx, tip: p0, from: p1, size: arrowSize, color: lineColor) }
            }
        }

        drawOriginLegend(ctx, imageWidth: width, imageHeight: height,
                         counts: counts, unknown: unknownCount)

        return ctx.makeImage()
    }

    /// Faded red rectangle behind each Vision-paragraph (size > 20 words).
    /// Captions and sentences left uncoloured so the overlay only
    /// highlights the regions `pruneParagraphAnchors` is actually trying
    /// to keep separate.
    private static func drawParagraphOverlays(_ ctx: CGContext,
                                              imageHeight: Int,
                                              words: [RecognizedWord],
                                              lineToParagraph: [Int: Int],
                                              paragraphSize: [Int: Int]) {
        var byParagraph: [Int: [Box]] = [:]
        for word in words {
            guard let para = lineToParagraph[word.lineID] else { continue }
            byParagraph[para, default: []].append(word.box)
        }

        let fill   = CGColor(red: 1.00, green: 0.20, blue: 0.20, alpha: 0.18)
        let stroke = CGColor(red: 1.00, green: 0.20, blue: 0.20, alpha: 0.55)
        ctx.setLineWidth(1)

        for (paraIdx, boxes) in byParagraph {
            let size = paragraphSize[paraIdx] ?? boxes.count
            if size <= paragraphMinWords { continue }
            let xMin = boxes.map(\.left).min()  ?? 0
            let xMax = boxes.map(\.right).max() ?? 0
            let yMin = boxes.map(\.top).min()   ?? 0
            let yMax = boxes.map(\.bottom).max() ?? 0
            let cgY = CGFloat(imageHeight - yMax)
            let rect = CGRect(x: CGFloat(xMin), y: cgY,
                              width:  CGFloat(xMax - xMin),
                              height: CGFloat(yMax - yMin))
            ctx.setFillColor(fill)
            ctx.fill(rect)
            ctx.setStrokeColor(stroke)
            ctx.stroke(rect)
        }
    }

    /// Compact top-left legend so the user can read the diagnostic
    /// without remembering the colour mapping.
    private static func drawOriginLegend(_ ctx: CGContext,
                                         imageWidth: Int, imageHeight: Int,
                                         counts: [EdgeOrigin: Int],
                                         unknown: Int) {
        let entries: [(EdgeOrigin, String)] = [
            (.pairwise,      "pairwise"),
            (.alignedSeries, "alignedSeries"),
            (.captions,      "captions"),
            (.bridges,       "bridges"),
        ]
        let rowH: CGFloat = 22
        let swatchW: CGFloat = 24
        let pad: CGFloat = 10
        let textPad: CGFloat = 8
        let lineCount = entries.count + (unknown > 0 ? 1 : 0)
        let boxH = CGFloat(lineCount) * rowH + 2 * pad
        let boxW: CGFloat = 220
        let originY = CGFloat(imageHeight) - boxH - 12

        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
        ctx.fill(CGRect(x: 12, y: originY, width: boxW, height: boxH))

        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.current = nsCtx

        var y = originY + boxH - pad - rowH
        for (origin, label) in entries {
            let colour = originPalette[origin] ?? unknownOriginColor
            ctx.setFillColor(colour)
            ctx.fill(CGRect(x: 12 + pad, y: y + 4, width: swatchW, height: rowH - 8))
            let count = counts[origin] ?? 0
            let text = "\(label)  \(count)"
            NSAttributedString(string: text, attributes: attrs).draw(
                at: CGPoint(x: 12 + pad + swatchW + textPad, y: y + 3)
            )
            y -= rowH
        }
        if unknown > 0 {
            ctx.setFillColor(unknownOriginColor)
            ctx.fill(CGRect(x: 12 + pad, y: y + 4, width: swatchW, height: rowH - 8))
            NSAttributedString(string: "unknown  \(unknown)", attributes: attrs).draw(
                at: CGPoint(x: 12 + pad + swatchW + textPad, y: y + 3)
            )
        }
    }

    /// Small filled triangle whose tip sits at `tip`, base perpendicular to
    /// the segment running back toward `from`.
    private static func drawArrow(_ ctx: CGContext, tip: CGPoint, from origin: CGPoint,
                                   size: CGFloat, color: CGColor) {
        let dx = tip.x - origin.x
        let dy = tip.y - origin.y
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 0.0001 else { return }
        let ux = dx / len, uy = dy / len
        let px = -uy * size * 0.3
        let py =  ux * size * 0.3
        let baseX = tip.x - ux * size
        let baseY = tip.y - uy * size
        ctx.setFillColor(color)
        ctx.beginPath()
        ctx.move(to: tip)
        ctx.addLine(to: CGPoint(x: baseX + px, y: baseY + py))
        ctx.addLine(to: CGPoint(x: baseX - px, y: baseY - py))
        ctx.closePath()
        ctx.fillPath()
    }

    // MARK: - PNG output

    private static func write(cgImage: CGImage, to url: URL) {
        let type: CFString
        if #available(macOS 11.0, *) {
            type = UTType.png.identifier as CFString
        } else {
            type = "public.png" as CFString
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cgImage, nil)
        CGImageDestinationFinalize(dest)
    }
}
