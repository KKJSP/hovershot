import CoreGraphics
import Foundation

/// Tightly-packed planar L/a/b channels in OpenCV's 8-bit encoding
/// (L = 0…255 mapped from 0…100, a/b = 0…255 with +128 offset). Storing planar
/// rather than interleaved keeps the perimeter sampling code branch-free.
struct LABImage {
    let width: Int
    let height: Int
    let L: [UInt8]
    let a: [UInt8]
    let b: [UInt8]

    @inline(__always)
    func sample(x: Int, y: Int) -> (Int, Int, Int)? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let i = y * width + x
        return (Int(L[i]), Int(a[i]), Int(b[i]))
    }
}

enum LABConverter {
    /// 256-entry sRGB→linear lookup, computed once. Eliminates the per-pixel `pow`
    /// call from the inner loop — sRGB inputs are bytes, so this is exact.
    private static let srgbToLinearLUT: [Double] = (0...255).map { v in
        let f = Double(v) / 255.0
        return f <= 0.04045 ? (f / 12.92) : pow((f + 0.055) / 1.055, 2.4)
    }

    /// Decodes a CGImage into RGBA bytes and converts to OpenCV-style LAB.
    /// Inner loop uses unsafe pointers + a sRGB LUT — this dominates the
    /// pre-detection cost on Retina screenshots.
    static func convert(_ cgImage: CGImage) -> LABImage? {
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        var rgba = [UInt8](repeating: 0, count: width * height * 4)

        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(
            data: &rgba,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: space, bitmapInfo: info
        ) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var L = [UInt8](repeating: 0, count: width * height)
        var a = [UInt8](repeating: 0, count: width * height)
        var b = [UInt8](repeating: 0, count: width * height)

        // Constants for D65 illuminant CIE LAB conversion.
        let xn = 0.95047
        let yn = 1.00000
        let zn = 1.08883
        let delta = 6.0 / 29.0
        let delta3 = delta * delta * delta
        let inv3delta2 = 1.0 / (3.0 * delta * delta)

        @inline(__always) func f(_ t: Double) -> Double {
            t > delta3 ? Foundation.pow(t, 1.0 / 3.0) : (t * inv3delta2 + 4.0 / 29.0)
        }

        let lut = srgbToLinearLUT
        let count = width * height
        rgba.withUnsafeBufferPointer { rgbaPtr in
            L.withUnsafeMutableBufferPointer { Lp in
                a.withUnsafeMutableBufferPointer { ap in
                    b.withUnsafeMutableBufferPointer { bp in
                        guard let src = rgbaPtr.baseAddress,
                              let Lout = Lp.baseAddress,
                              let aout = ap.baseAddress,
                              let bout = bp.baseAddress else { return }
                        for i in 0..<count {
                            let r  = lut[Int(src[i * 4 + 0])]
                            let g  = lut[Int(src[i * 4 + 1])]
                            let bl = lut[Int(src[i * 4 + 2])]

                            // sRGB → XYZ (D65).
                            let X = r * 0.4124564 + g * 0.3575761 + bl * 0.1804375
                            let Y = r * 0.2126729 + g * 0.7151522 + bl * 0.0721750
                            let Z = r * 0.0193339 + g * 0.1191920 + bl * 0.9503041

                            let fx = f(X / xn)
                            let fy = f(Y / yn)
                            let fz = f(Z / zn)

                            let Lstar = 116.0 * fy - 16.0
                            let astar = 500.0 * (fx - fy)
                            let bstar = 200.0 * (fy - fz)

                            Lout[i] = UInt8(clamping: Int((Lstar * 255.0 / 100.0).rounded()))
                            aout[i] = UInt8(clamping: Int((astar + 128.0).rounded()))
                            bout[i] = UInt8(clamping: Int((bstar + 128.0).rounded()))
                        }
                    }
                }
            }
        }

        return LABImage(width: width, height: height, L: L, a: a, b: b)
    }
}
