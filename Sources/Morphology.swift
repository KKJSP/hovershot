import Accelerate
import Foundation

enum Morphology {
    /// Equivalent to OpenCV `morphologyEx(src, MORPH_CLOSE, getStructuringElement(MORPH_RECT, ksize))`:
    /// dilate with a `kw × kh` rectangle, then erode with the same.
    static func close(_ src: [UInt8], width: Int, height: Int, kw: Int, kh: Int) -> [UInt8] {
        let dilated = dilate(src, width: width, height: height, kw: kw, kh: kh)
        return erode(dilated, width: width, height: height, kw: kw, kh: kh)
    }

    static func dilate(_ src: [UInt8], width: Int, height: Int, kw: Int, kh: Int) -> [UInt8] {
        morph(src, width: width, height: height, kw: kw, kh: kh, dilate: true)
    }

    static func erode(_ src: [UInt8], width: Int, height: Int, kw: Int, kh: Int) -> [UInt8] {
        morph(src, width: width, height: height, kw: kw, kh: kh, dilate: false)
    }

    private static func morph(_ src: [UInt8], width w: Int, height h: Int,
                              kw: Int, kh: Int, dilate: Bool) -> [UInt8] {
        let kx = max(1, kw)
        let ky = max(1, kh)

        // Two passes (separable rectangular structuring element).
        let row = morphRow(src, w: w, h: h, k: kx, dilate: dilate)
        return morphCol(row, w: w, h: h, k: ky, dilate: dilate)
    }

    private static func morphRow(_ src: [UInt8], w: Int, h: Int, k: Int, dilate: Bool) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: w * h)
        let half = k / 2
        for y in 0..<h {
            let row = y * w
            for x in 0..<w {
                var ext: UInt8 = dilate ? 0 : 255
                let lo = max(0, x - half)
                let hi = min(w - 1, x + half)
                for nx in lo...hi {
                    let v = src[row + nx]
                    if dilate {
                        if v > ext { ext = v }
                    } else {
                        if v < ext { ext = v }
                    }
                }
                out[row + x] = ext
            }
        }
        return out
    }

    private static func morphCol(_ src: [UInt8], w: Int, h: Int, k: Int, dilate: Bool) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: w * h)
        let half = k / 2
        for x in 0..<w {
            for y in 0..<h {
                var ext: UInt8 = dilate ? 0 : 255
                let lo = max(0, y - half)
                let hi = min(h - 1, y + half)
                for ny in lo...hi {
                    let v = src[ny * w + x]
                    if dilate {
                        if v > ext { ext = v }
                    } else {
                        if v < ext { ext = v }
                    }
                }
                out[y * w + x] = ext
            }
        }
        return out
    }
}
