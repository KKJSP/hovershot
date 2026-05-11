import Foundation

enum EdgeDetect {
    /// Canny-style edge detection: Sobel magnitude → non-maximum suppression
    /// along the gradient direction → double-threshold hysteresis.
    ///
    /// The NMS pass is essential for behaviour on real screenshots:
    ///   * A smooth background gradient has roughly constant Sobel magnitude
    ///     at every pixel; without NMS, every one of those pixels passes the
    ///     low threshold and hysteresis floods the whole gradient region with
    ///     spurious edges, masking the real UI elements on top. NMS keeps
    ///     only local maxima along the gradient direction — a pure gradient
    ///     has none, so it's zeroed out.
    ///   * Conversely, a *sharp* boundary in lightness produces a single
    ///     ridge column whose magnitude (~4 · ΔL for a 1-pixel transition)
    ///     comfortably exceeds even modest thresholds. Pairing NMS with a
    ///     low `high` budget therefore picks up subtle slightly-darker boxes
    ///     that the previous high=40 threshold dropped entirely.
    ///
    /// The morphological closing downstream still fills any single-pixel gaps
    /// the NMS leaves in the ridge.
    static func canny(L: [UInt8], width w: Int, height h: Int,
                      lowThreshold: Int, highThreshold: Int) -> [UInt8] {
        // Compute the post-NMS magnitude map in a nested scope so the raw
        // Sobel buffer is freed before we allocate the binary output.
        let nms: [UInt8] = {
            var mag = [UInt8](repeating: 0, count: w * h)
            sobelMagnitude(L: L, into: &mag, w: w, h: h)
            var out = [UInt8](repeating: 0, count: w * h)
            nonMaxSuppress(L: L, mag: mag, into: &out, w: w, h: h)
            return out
        }()

        return hysteresis(nms: nms, w: w, h: h,
                          lowThreshold: lowThreshold,
                          highThreshold: highThreshold)
    }

    // MARK: - Stage helpers

    /// 3x3 Sobel magnitude, clamped to 0…255.
    private static func sobelMagnitude(L: [UInt8], into mag: inout [UInt8],
                                       w: Int, h: Int) {
        L.withUnsafeBufferPointer { sp in
            mag.withUnsafeMutableBufferPointer { mp in
                guard let s = sp.baseAddress, let m = mp.baseAddress else { return }
                for y in 1..<(h - 1) {
                    for x in 1..<(w - 1) {
                        let i = y * w + x
                        let p00 = Int(s[i - w - 1]), p01 = Int(s[i - w]), p02 = Int(s[i - w + 1])
                        let p10 = Int(s[i - 1])    ,                      p12 = Int(s[i + 1])
                        let p20 = Int(s[i + w - 1]), p21 = Int(s[i + w]), p22 = Int(s[i + w + 1])
                        let gx = -p00 + p02 + (-2 * p10 + 2 * p12) + (-p20 + p22)
                        let gy = -p00 - 2 * p01 - p02 + p20 + 2 * p21 + p22
                        let mm = Int((Double(gx * gx + gy * gy)).squareRoot())
                        m[i] = mm > 255 ? 255 : UInt8(mm)
                    }
                }
            }
        }
    }

    /// For each pixel with non-zero magnitude, compares it against the two
    /// neighbours along the (approximate) gradient direction and keeps it
    /// only if it's a strict maximum versus one neighbour and >= the other.
    /// Plateaus (constant-magnitude regions = smooth gradients) collapse to
    /// zero because no pixel beats both neighbours.
    private static func nonMaxSuppress(L: [UInt8], mag: [UInt8],
                                        into nms: inout [UInt8],
                                        w: Int, h: Int) {
        L.withUnsafeBufferPointer { sp in
            mag.withUnsafeBufferPointer { mp in
                nms.withUnsafeMutableBufferPointer { np in
                    guard let s = sp.baseAddress, let m = mp.baseAddress,
                          let n = np.baseAddress else { return }
                    for y in 1..<(h - 1) {
                        for x in 1..<(w - 1) {
                            let i = y * w + x
                            let mi = m[i]
                            if mi == 0 { continue }

                            // Recompute gx, gy to find the gradient octant.
                            // Storing them in a dedicated buffer would double
                            // peak memory; the recomputation is a handful of
                            // adds per pixel and not a hot-path issue.
                            let p00 = Int(s[i - w - 1]), p01 = Int(s[i - w]), p02 = Int(s[i - w + 1])
                            let p10 = Int(s[i - 1])    ,                      p12 = Int(s[i + 1])
                            let p20 = Int(s[i + w - 1]), p21 = Int(s[i + w]), p22 = Int(s[i + w + 1])
                            let gx = -p00 + p02 + (-2 * p10 + 2 * p12) + (-p20 + p22)
                            let gy = -p00 - 2 * p01 - p02 + p20 + 2 * p21 + p22

                            let agx = gx >= 0 ? gx : -gx
                            let agy = gy >= 0 ? gy : -gy
                            let n1: UInt8, n2: UInt8
                            // tan(22.5°) ≈ 0.414 — use 2/5 (0.4) for the
                            // octant boundary so all comparisons stay integer.
                            if agy * 5 < agx * 2 {
                                // Horizontal-ish gradient → horizontal neighbours.
                                n1 = m[i - 1];     n2 = m[i + 1]
                            } else if agx * 5 < agy * 2 {
                                // Vertical-ish gradient → vertical neighbours.
                                n1 = m[i - w];     n2 = m[i + w]
                            } else if (gx > 0) == (gy > 0) {
                                // \ diagonal.
                                n1 = m[i - w - 1]; n2 = m[i + w + 1]
                            } else {
                                // / diagonal.
                                n1 = m[i - w + 1]; n2 = m[i + w - 1]
                            }
                            // Asymmetric (`>` then `>=`) tie-breaking keeps
                            // one pixel along a 2-wide ridge while still
                            // collapsing a constant-magnitude plateau.
                            if mi > n1 && mi >= n2 { n[i] = mi }
                        }
                    }
                }
            }
        }
    }

    /// Double-threshold hysteresis: pixels above `high` seed the output, then
    /// BFS spreads through 8-connected NMS pixels above `low`.
    private static func hysteresis(nms: [UInt8], w: Int, h: Int,
                                    lowThreshold: Int, highThreshold: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: w * h)
        var stack: [Int] = []
        stack.reserveCapacity(1024)
        for i in 0..<nms.count {
            if Int(nms[i]) >= highThreshold {
                out[i] = 255
                stack.append(i)
            }
        }
        while let i = stack.popLast() {
            let x = i % w
            let y = i / w
            for dy in -1...1 {
                let ny = y + dy
                if ny < 0 || ny >= h { continue }
                for dx in -1...1 {
                    if dx == 0 && dy == 0 { continue }
                    let nx = x + dx
                    if nx < 0 || nx >= w { continue }
                    let ni = ny * w + nx
                    if out[ni] == 0 && Int(nms[ni]) >= lowThreshold {
                        out[ni] = 255
                        stack.append(ni)
                    }
                }
            }
        }
        return out
    }
}
