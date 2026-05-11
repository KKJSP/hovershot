import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes intermediate pipeline products into `<saveFolder>/ScreenshotsDebug/`
/// when debug mode is on. Mirrors the Python version's debug images
/// (`_0_source`, `_1_edges`, `_2_initial_boxes`, `_3_seas`).
enum DebugImageWriter {
    static func writeIfEnabled(
        source: CGImage,
        edges: [UInt8],
        closed: [UInt8],
        width: Int,
        height: Int,
        initialBoxes: [Box],
        seas: [BoxFinder.Sea]
    ) {
        guard Config.debug else { return }
        let dir = Config.saveFolder.appendingPathComponent("ScreenshotsDebug", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        write(cgImage: source, to: dir.appendingPathComponent("0_source.png"))
        if let edgeImg = grayscaleImage(from: edges, width: width, height: height) {
            write(cgImage: edgeImg, to: dir.appendingPathComponent("1_edges.png"))
        }
        if let boxesImg = renderBoxes(on: source, boxes: initialBoxes,
                                      colors: [CGColor(red: 0, green: 1, blue: 0, alpha: 1)]) {
            write(cgImage: boxesImg, to: dir.appendingPathComponent("2_initial_boxes.png"))
        }
        if let seasImg = renderSeas(on: source, seas: seas) {
            write(cgImage: seasImg, to: dir.appendingPathComponent("3_seas.png"))
        }
        _ = closed  // no longer written to disk; intermediate buffer only
    }

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

    private static func renderBoxes(on cgImage: CGImage, boxes: [Box],
                                    colors: [CGColor]) -> CGImage? {
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
        for (i, box) in boxes.enumerated() {
            ctx.setStrokeColor(colors[i % colors.count])
            // CGContext is bottom-left origin; flip the Box y.
            let cgY = CGFloat(height - box.y - box.height)
            ctx.stroke(CGRect(x: CGFloat(box.x), y: cgY,
                              width: CGFloat(box.width), height: CGFloat(box.height)))
        }
        return ctx.makeImage()
    }

    private static func renderSeas(on cgImage: CGImage,
                                   seas: [BoxFinder.Sea]) -> CGImage? {
        // Random-ish but deterministic palette for visual distinction across seas.
        let palette: [CGColor] = [
            CGColor(red: 1.00, green: 0.20, blue: 0.20, alpha: 1),
            CGColor(red: 0.20, green: 0.60, blue: 1.00, alpha: 1),
            CGColor(red: 0.20, green: 0.85, blue: 0.40, alpha: 1),
            CGColor(red: 1.00, green: 0.80, blue: 0.20, alpha: 1),
            CGColor(red: 0.85, green: 0.30, blue: 0.85, alpha: 1),
            CGColor(red: 0.30, green: 0.85, blue: 0.85, alpha: 1),
        ]
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
