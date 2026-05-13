import Foundation

enum ConnectedComponents {
    /// Two-pass union-find connected component labelling on an 8-bit binary image
    /// (foreground = non-zero). Returns the bounding box of every component.
    static func label(_ src: [UInt8], width w: Int, height h: Int) -> [Box] {
        var labels = [Int32](repeating: 0, count: w * h)
        var parent = [Int32](repeating: 0, count: 1)
        parent[0] = 0
        var nextLabel: Int32 = 1

        @inline(__always) func find(_ x: Int32) -> Int32 {
            var x = x
            while parent[Int(x)] != x { x = parent[Int(x)] }
            return x
        }
        @inline(__always) func union(_ a: Int32, _ b: Int32) {
            let ra = find(a), rb = find(b)
            if ra != rb {
                if ra < rb { parent[Int(rb)] = ra } else { parent[Int(ra)] = rb }
            }
        }

        // Pass 1: provisional labels with 8-connectivity.
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                if src[i] == 0 { continue }

                var neighbours: [Int32] = []
                let xm = x - 1, ym = y - 1, xp = x + 1
                if xm >= 0 && labels[y * w + xm] != 0    { neighbours.append(labels[y * w + xm]) }
                if ym >= 0 {
                    if xm >= 0 && labels[ym * w + xm] != 0 { neighbours.append(labels[ym * w + xm]) }
                    if labels[ym * w + x] != 0             { neighbours.append(labels[ym * w + x])  }
                    if xp < w && labels[ym * w + xp] != 0  { neighbours.append(labels[ym * w + xp]) }
                }

                if neighbours.isEmpty {
                    labels[i] = nextLabel
                    parent.append(nextLabel)
                    nextLabel += 1
                } else {
                    let m = neighbours.min()!
                    labels[i] = m
                    for n in neighbours where n != m { union(m, n) }
                }
            }
        }

        // Pass 2: resolve labels and compute per-component bounding boxes.
        var minX = [Int](repeating: Int.max, count: Int(nextLabel))
        var minY = [Int](repeating: Int.max, count: Int(nextLabel))
        var maxX = [Int](repeating: Int.min, count: Int(nextLabel))
        var maxY = [Int](repeating: Int.min, count: Int(nextLabel))
        var roots = Set<Int32>()

        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let l = labels[i]
                if l == 0 { continue }
                let root = find(l)
                roots.insert(root)
                let r = Int(root)
                if x < minX[r] { minX[r] = x }
                if y < minY[r] { minY[r] = y }
                if x > maxX[r] { maxX[r] = x }
                if y > maxY[r] { maxY[r] = y }
            }
        }

        var boxes: [Box] = []
        boxes.reserveCapacity(roots.count)
        for root in roots {
            let r = Int(root)
            boxes.append(Box(x: minX[r], y: minY[r],
                             width: maxX[r] - minX[r] + 1,
                             height: maxY[r] - minY[r] + 1))
        }

        return boxes
    }
}
