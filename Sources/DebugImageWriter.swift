import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes intermediate pipeline products directly into `<saveFolder>/` when
/// debug mode is on. Files are numbered to match the pipeline order:
///   * `0_source.png`     — the captured frame
///   * `1_edges.png`      — Canny edges before morphology
///   * `2_seas.png`       — selectable boxes coloured by sea membership
///   * `3_connections.png`— the final adjacency network as directed arrows
///   * `4_ocr.png`        — Vision-line paragraph classification: red
///                          fills around paragraphs (>20 words), cyan
///                          fills around captions (<10 words). Sentences
///                          (10–20 words) are intentionally uncoloured —
///                          they're the borderline tier the network uses
///                          standard caption gates for.
enum DebugImageWriter {
    static func writeIfEnabled(
        source: CGImage,
        edges: [UInt8],
        width: Int,
        height: Int,
        seas: [BoxFinder.Sea],
        network: [Box: [Box]],
        words: [RecognizedWord],
        lineToParagraph: [Int: Int],
        paragraphSize: [Int: Int]
    ) {
        guard Config.debug else { return }
        let dir = Config.saveFolder

        write(cgImage: source, to: dir.appendingPathComponent("0_source.png"))
        if let edgeImg = grayscaleImage(from: edges, width: width, height: height) {
            write(cgImage: edgeImg, to: dir.appendingPathComponent("1_edges.png"))
        }
        if let seasImg = renderSeas(on: source, seas: seas) {
            write(cgImage: seasImg, to: dir.appendingPathComponent("2_seas.png"))
        }
        if let connectionsImg = renderConnections(on: source, network: network, seas: seas) {
            write(cgImage: connectionsImg, to: dir.appendingPathComponent("3_connections.png"))
        }
        if let groupsImg = renderTextGroups(on: source, words: words,
                                            lineToParagraph: lineToParagraph,
                                            paragraphSize: paragraphSize) {
            write(cgImage: groupsImg, to: dir.appendingPathComponent("4_ocr.png"))
        }
    }

    /// Deterministic per-sea palette, shared between `2_seas.png` and the
    /// box outlines in `3_connections.png` so the same membership is visible
    /// in both views.
    private static let seaPalette: [CGColor] = [
        CGColor(red: 1.00, green: 0.20, blue: 0.20, alpha: 1),
        CGColor(red: 0.20, green: 0.60, blue: 1.00, alpha: 1),
        CGColor(red: 0.20, green: 0.85, blue: 0.40, alpha: 1),
        CGColor(red: 1.00, green: 0.80, blue: 0.20, alpha: 1),
        CGColor(red: 0.85, green: 0.30, blue: 0.85, alpha: 1),
        CGColor(red: 0.30, green: 0.85, blue: 0.85, alpha: 1),
    ]

    // MARK: - Image construction

    private static func grayscaleImage(from buffer: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.linearGray) else { return nil }
        var data = buffer
        return data.withUnsafeMutableBufferPointer { ptr -> CGImage? in
            guard let ctx = CGContext(
                data: ptr.baseAddress,
                width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return nil }
            return ctx.makeImage()
        }
    }

    private static func renderSeas(on cgImage: CGImage,
                                   seas: [BoxFinder.Sea]) -> CGImage? {
        let palette = seaPalette
        let width = cgImage.width, height = cgImage.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
                 | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info
        ) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setLineWidth(2)
        for (idx, sea) in seas.enumerated() {
            ctx.setStrokeColor(palette[idx % palette.count])
            for box in sea.members {
                let cgY = CGFloat(height - box.y - box.height)
                ctx.stroke(CGRect(x: CGFloat(box.x), y: cgY,
                                  width: CGFloat(box.width), height: CGFloat(box.height)))
            }
        }
        return ctx.makeImage()
    }

    /// Render the directed adjacency network as faded arrows over the source.
    /// One line per undirected pair (so we don't double-draw), with one or two
    /// arrowheads depending on which directions exist:
    ///   * `a → b` only: single arrowhead at `b` (the "large can reach small"
    ///     case after asymmetric size pruning).
    ///   * `a → b` and `b → a`: arrowheads at both ends (peers).
    /// Arrowheads are kept small and lines low-alpha because dense screenshots
    /// produce hundreds of edges; too-bold rendering becomes unreadable.
    private static func renderConnections(on cgImage: CGImage,
                                          network: [Box: [Box]],
                                          seas: [BoxFinder.Sea]) -> CGImage? {
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

        // Map every box to its sea colour so outlines match `2_seas.png`.
        var seaColor: [Box: CGColor] = [:]
        for (idx, sea) in seas.enumerated() {
            let colour = seaPalette[idx % seaPalette.count]
            for box in sea.members { seaColor[box] = colour }
        }
        let fallbackOutline = CGColor(red: 0.60, green: 0.60, blue: 0.60, alpha: 1.0)

        ctx.setLineWidth(1)
        for box in network.keys {
            ctx.setStrokeColor(seaColor[box] ?? fallbackOutline)
            let cgY = CGFloat(height - box.y - box.height)
            ctx.stroke(CGRect(x: CGFloat(box.x), y: cgY,
                              width: CGFloat(box.width), height: CGFloat(box.height)))
        }

        let lineColor = CGColor(red: 1.00, green: 0.40, blue: 0.00, alpha: 1.0)
        let arrowSize: CGFloat = 14
        var drawn = Set<UnorderedPair>()

        for (from, neighbours) in network {
            for to in neighbours {
                let pair = UnorderedPair(from, to)
                if drawn.contains(pair) { continue }
                drawn.insert(pair)

                let forward = network[from]?.contains(to) ?? false
                let reverse = network[to]?.contains(from) ?? false

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

        return ctx.makeImage()
    }

    /// Render the paragraph/caption classification overlay. Each Vision
    /// paragraph (a union-find component of recognised lines) gets a
    /// filled rectangle bounding all its words:
    ///   * paragraph (> 20 words) — faded red
    ///   * caption (< 10 words) — faded cyan
    ///   * sentence (10–20 words) — left transparent
    ///
    /// Drawn directly over the source so the user can sanity-check which
    /// text regions the network construction treats as candidates for
    /// caption linking vs. paragraph anchor pruning. If a body block
    /// shows up as cyan or transparent, the union-find didn't chain its
    /// lines (often a column-overlap or y-gap tuning issue); if a tight
    /// caption shows up as red, the paragraph threshold needs raising.
    private static func renderTextGroups(on cgImage: CGImage,
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

        let paragraphFill   = CGColor(red: 1.00, green: 0.20, blue: 0.20, alpha: 0.22)
        let paragraphStroke = CGColor(red: 1.00, green: 0.20, blue: 0.20, alpha: 0.85)
        let captionFill     = CGColor(red: 0.10, green: 0.75, blue: 0.90, alpha: 0.22)
        let captionStroke   = CGColor(red: 0.10, green: 0.75, blue: 0.90, alpha: 0.85)

        // Group word boxes by paragraph.
        var byParagraph: [Int: [Box]] = [:]
        for word in words {
            guard let para = lineToParagraph[word.lineID] else { continue }
            byParagraph[para, default: []].append(word.box)
        }

        ctx.setLineWidth(2)
        for (paraIdx, boxes) in byParagraph {
            let size = paragraphSize[paraIdx] ?? boxes.count
            let fill: CGColor
            let stroke: CGColor
            if size > 20 {
                fill = paragraphFill; stroke = paragraphStroke
            } else if size < 10 {
                fill = captionFill; stroke = captionStroke
            } else {
                continue   // sentence — uncoloured
            }
            let xMin = boxes.map(\.left).min()  ?? 0
            let xMax = boxes.map(\.right).max() ?? 0
            let yMin = boxes.map(\.top).min()   ?? 0
            let yMax = boxes.map(\.bottom).max() ?? 0
            let cgY = CGFloat(height - yMax)
            let rect = CGRect(x: CGFloat(xMin), y: cgY,
                              width:  CGFloat(xMax - xMin),
                              height: CGFloat(yMax - yMin))
            ctx.setFillColor(fill)
            ctx.fill(rect)
            ctx.setStrokeColor(stroke)
            ctx.stroke(rect)
        }

        return ctx.makeImage()
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
        // Half-base perpendicular vector (width = size * 0.6).
        let px = -uy * size * 0.3
        let py =  ux * size * 0.3
        // Base centre is `size` pixels back from the tip along the segment.
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

    /// Hashable key for an undirected `{a, b}` box pair — used to de-duplicate
    /// arrow drawing when both directions exist in the network.
    private struct UnorderedPair: Hashable {
        let first: Box
        let second: Box
        init(_ x: Box, _ y: Box) {
            if (x.x, x.y, x.width, x.height) <= (y.x, y.y, y.width, y.height) {
                first = x; second = y
            } else {
                first = y; second = x
            }
        }
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
