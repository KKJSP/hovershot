import AppKit
import CoreGraphics
import Foundation

struct DetectionResult {
    let boxes: [Box]
    let network: [Box: [Box]]
    /// The seas that survived clustering — keyed by representative LAB colour, each
    /// holding the boxes belonging to that sea. Useful for debugging / visualisation.
    let seas: [(L: Int, a: Int, b: Int, members: [Box])]
}

/// Faithful port of `boxfinder.py`'s `BoxFinder.predict` pipeline:
///   LAB → Canny edges → morphological close → connected components →
///   selectable-box filter → perimeter sea sampling → sea grouping →
///   noisy-box parent connection → adjacency network via `connectionProbability`.
///
/// All numeric thresholds and shape rules match the Python originals.
struct BoxFinder {
    var ksizeBase: (Int, Int)
    /// `(seaGroupingThreshold, calmnessThreshold)` in 8-bit LAB units.
    /// Sea grouping is intentionally tight — at threshold 5 a pure-white
    /// region (L≈255) and a near-white region (L≈251) merge into one sea,
    /// which then bleeds clusters across visually distinct light-grey panels.
    /// Tightening to 3 keeps the calmness/Canny budgets unchanged but only
    /// fuses sea colours that are essentially indistinguishable.
    var colorThreshold: (Int, Int) = (3, 40)
    var marginBase: Int = 2
    var seaPointGap: Int = 10

    private(set) var scale: Double = 1.0

    init() {
        // Pull the user-controlled box-size scale from settings each detection.
        // The reference values (8, 5) match the Python tuning at scale = 1.0.
        let s = Config.boxSize
        ksizeBase = (max(1, Int((8.0 * s).rounded())),
                     max(1, Int((5.0 * s).rounded())))
    }

    private var ksize: (w: Int, h: Int) {
        (max(1, Int(floor(Double(ksizeBase.0) * scale))),
         max(1, Int(floor(Double(ksizeBase.1) * scale))))
    }

    private var margin: Int {
        max(1, Int(ceil(Double(marginBase) * scale)))
    }

    mutating func detect(in cgImage: CGImage) -> DetectionResult {
        let h = cgImage.height
        scale = Double(h) / 1964.0
        let kx = ksize.w
        let ky = ksize.h

        guard let lab = LABConverter.convert(cgImage) else {
            return DetectionResult(boxes: [], network: [:], seas: [])
        }

        // 1. Edge detection on the L channel + morphological closing.
        let edges = EdgeDetect.canny(L: lab.L, width: lab.width, height: lab.height,
                                     lowThreshold: colorThreshold.0,
                                     highThreshold: colorThreshold.1)
        let closed = Morphology.close(edges, width: lab.width, height: lab.height,
                                      kw: kx, kh: ky)

        // 2. Connected-components labelling stands in for `findContours(RETR_TREE)`.
        let (allBoxes, parentIndex) = ConnectedComponents.label(closed,
                                                                 width: lab.width,
                                                                 height: lab.height)

        let initialCount = allBoxes.count

        // 3. Selectable-box filter — port of `_selectable_boxes`.
        let imageArea = lab.width * lab.height
        let maxArea = Double(imageArea) * 0.6
        let maxChildArea = Double(kx * ky) * 250.0

        var selectableSet = Set<Box>()
        for (i, box) in allBoxes.enumerated() {
            if box.width  < kx || box.height < ky { continue }
            if Double(box.area) > maxArea          { continue }
            if Double(box.area) < maxChildArea, parentIndex[i] != -1 {
                let parent = allBoxes[parentIndex[i]]
                if parent.width  - box.width  < 4 * kx ||
                   parent.height - box.height < 6 * ky {
                    continue
                }
            }
            selectableSet.insert(box)
        }
        var selectable = Array(selectableSet)

        // 4. Perimeter sampling → stable boxes + per-box sea colour.
        var stableBoxes: [Box] = []
        var seaColours: [(Int, Int, Int)] = []
        for box in selectable {
            if let (colour, calm) = seaColourAndValidity(lab: lab, box: box), calm {
                stableBoxes.append(box)
                seaColours.append(colour)
            }
        }
        selectable = stableBoxes

        // 5. Group boxes into seas by LAB-colour proximity.
        let seas = groupIntoSeas(boxes: selectable, colours: seaColours)

        // 6. Build the adjacency network.
        let network = buildNetwork(boxes: selectable, seas: seas)

        let seasOut = seas.map { (L: $0.colour.0, a: $0.colour.1, b: $0.colour.2,
                                  members: $0.members) }

        if Config.debug {
            NSLog("[HoverShot] grouped %d boxes into %d boxes across %d seas (initial %d)",
                  initialCount, selectable.count, seas.count, initialCount)
            DebugImageWriter.writeIfEnabled(
                source: cgImage,
                edges: edges,
                width: lab.width,
                height: lab.height,
                seas: seas,
                network: network
            )
        }

        return DetectionResult(boxes: selectable, network: network, seas: seasOut)
    }

    // MARK: - Stage helpers

    /// Samples the perimeter just outside the box at `seaPointGap` intervals
    /// and decides whether the surrounding background is "calm enough" for
    /// the box to be selectable.
    ///
    /// The original Python check measured each sample's distance to the
    /// **global** perimeter mean, which silently rejected even gentle
    /// gradients: samples at the extremes of the gradient are far from the
    /// mean, fail the budget, and the box gets dropped. The Swift version
    /// instead looks at **consecutive-sample** distances along each edge in
    /// spatial order — gradients yield small step-to-step deltas, while
    /// genuinely noisy backgrounds (text, photo content, multi-element
    /// regions) yield large jumps. The mean colour is still returned so sea
    /// grouping behaviour downstream is unchanged.
    private func seaColourAndValidity(lab: LABImage, box: Box) -> ((Int, Int, Int), Bool)? {
        let m = max(1, margin)
        let gap = seaPointGap

        var top: [(Int, Int, Int)] = []
        var bottom: [(Int, Int, Int)] = []
        var left: [(Int, Int, Int)] = []
        var right: [(Int, Int, Int)] = []

        var cx = box.x
        while cx < box.x + box.width {
            if let s = lab.sample(x: cx, y: box.y - m)              { top.append(s) }
            if let s = lab.sample(x: cx, y: box.y + box.height + m) { bottom.append(s) }
            cx += gap
        }
        var cy = box.y
        while cy < box.y + box.height {
            if let s = lab.sample(x: box.x - m, y: cy)              { left.append(s) }
            if let s = lab.sample(x: box.x + box.width + m, y: cy)  { right.append(s) }
            cy += gap
        }

        let total = top.count + bottom.count + left.count + right.count
        if total == 0 { return ((0, 0, 0), false) }

        var sumL = 0, sumA = 0, sumB = 0
        for edge in [top, bottom, left, right] {
            for s in edge { sumL += s.0; sumA += s.1; sumB += s.2 }
        }
        let meanColour = (sumL / total, sumA / total, sumB / total)

        // Smoothness budget reused from the noise threshold. We compare
        // squared LAB distances between consecutive samples on the same edge
        // (so the comparison is along the perimeter rather than across it).
        let budget = colorThreshold.1
        let budgetSq = budget * budget
        var smooth = 0
        var transitions = 0
        for edge in [top, bottom, left, right] where edge.count >= 2 {
            for i in 1..<edge.count {
                let dl = edge[i].0 - edge[i - 1].0
                let da = edge[i].1 - edge[i - 1].1
                let db = edge[i].2 - edge[i - 1].2
                if dl * dl + da * da + db * db < budgetSq { smooth += 1 }
                transitions += 1
            }
        }

        // Tiny boxes whose edges fit inside a single sample don't have any
        // transitions to inspect — fall back to "calm" rather than rejecting
        // them outright, since the size filter has already vetted them.
        if transitions == 0 { return (meanColour, true) }
        // ≥70% of consecutive transitions must be smooth. Multiplied form
        // avoids floating point — "smooth / transitions ≥ 0.7" rewritten.
        let calm = smooth * 10 >= transitions * 7
        return (meanColour, calm)
    }

    struct Sea {
        var colour: (Int, Int, Int)
        var members: [Box]
    }

    /// Direct port of `_group_boxes_to_seas`: grow seas in encounter order, only
    /// joining a sea if its colour is within `colorThreshold[0]` (LAB-Euclidean).
    private func groupIntoSeas(boxes: [Box], colours: [(Int, Int, Int)]) -> [Sea] {
        var seas: [Sea] = []
        let t = colorThreshold.0
        let t2 = t * t
        for (box, colour) in zip(boxes, colours) {
            var joined = false
            for i in 0..<seas.count {
                let c = seas[i].colour
                let dl = c.0 - colour.0, da = c.1 - colour.1, db = c.2 - colour.2
                if dl * dl + da * da + db * db < t2 {
                    seas[i].members.append(box)
                    joined = true
                    break
                }
            }
            if !joined { seas.append(Sea(colour: colour, members: [box])) }
        }
        return seas
    }

    // MARK: - Network construction

    /// Two main passes plus two post-processing passes:
    ///   * Per-sea pairwise `connectionProbability`, threshold 0.5.
    ///   * Bridge pass: within each sea, union the connected components and add an
    ///     edge between any two close-but-disconnected components — fixes the case
    ///     where a tiny "bridge" box's poor area-ratio kept it from joining its
    ///     neighbours and split a cluster in two.
    ///   * Aligned-series pass for stacked rows / inline text segments.
    ///
    /// Engulfment is never connected. The Python `_connect_noisy_boxes` step that
    /// linked nested children to their containing parent is intentionally absent
    /// here — full containment splits cluster intent more often than it helps.
    private func buildNetwork(boxes: [Box], seas: [Sea]) -> [Box: [Box]] {
        var network: [Box: [Box]] = [:]

        // The merge distance is intentionally derived from the Python-reference
        // ksize `(8, 5)` (scaled to image resolution) rather than the user-tuned
        // morphology kernel. Smaller user box sizes still get a generous neighbour
        // search radius — otherwise adjacent UI elements would never cluster.
        let refW = 8.0 * scale
        let refH = 5.0 * scale
        let mergeDistance = (refW * refW + refH * refH).squareRoot() * 2

        for sea in seas {
            for box in sea.members {
                if network[box] != nil { continue }
                var connections: [Box] = []
                let boxArea = Double(box.area)
                for other in sea.members where other != box {
                    // Asymmetry: a much-smaller box never gains a forward edge
                    // to a much-larger one. The connection probability formula
                    // already disfavours this direction, but enforce it
                    // explicitly so the rule is uniform across all passes.
                    if boxArea * asymRatio < Double(other.area) { continue }
                    if box.connectionProbability(other, mergeDistance: mergeDistance) > 0.5 {
                        connections.append(other)
                    }
                }
                network[box] = connections
            }
        }

        connectAlignedSeries(seas: seas, network: &network, mergeDistance: mergeDistance)
        connectCaptions(seas: seas, network: &network, mergeDistance: mergeDistance)
        pruneOutlierConnections(network: &network)
        return network
    }

    /// After every connection pass has run, look at each box's neighbour set
    /// as a "neighbourhood scale": if one neighbour's area is wildly out of
    /// distribution vs the others, that's a sign the rule that connected
    /// them did so for the wrong reason. The motivating case is a figure
    /// (heatmap) whose legitimate neighbours are tick labels, title words,
    /// and colourbar parts — all small or medium — that has *also* been
    /// linked to a peer code cell whose area is an order of magnitude bigger
    /// than the median neighbour. We treat that edge as a likely false
    /// positive and remove it from both ends.
    ///
    /// Algorithm:
    ///   * Skip boxes with fewer than 4 neighbours — too noisy to call an
    ///     outlier on so little data.
    ///   * Compute the median neighbour area as the scale estimate.
    ///   * Any neighbour whose area exceeds `outlierFactor × median` is
    ///     marked for pruning.
    ///   * Apply removals symmetrically so BFS from either end agrees.
    ///
    /// The 8× factor is intentionally conservative: a typical column or row
    /// of mixed-size labels (axis ticks + a wider title + a colourbar
    /// gradient strip) stays within that envelope; only the truly peer-sized
    /// outliers (whole notebook cells, neighbouring figures) trip it.
    private func pruneOutlierConnections(network: inout [Box: [Box]]) {
        let outlierFactor: Double = 8.0
        let minNeighbours = 4

        var toPrune: [(Box, Box)] = []
        for (box, neighbours) in network where neighbours.count >= minNeighbours {
            let areas = neighbours.map { Double($0.area) }.sorted()
            let n = areas.count
            let median: Double = n % 2 == 0
                ? (areas[n / 2 - 1] + areas[n / 2]) / 2.0
                : areas[n / 2]
            guard median > 0 else { continue }
            let threshold = outlierFactor * median
            for neighbour in neighbours where Double(neighbour.area) > threshold {
                toPrune.append((box, neighbour))
            }
        }

        for (a, b) in toPrune {
            network[a]?.removeAll { $0 == b }
            network[b]?.removeAll { $0 == a }
        }
    }

    /// Link a much-smaller box (label, title, caption) to a substantial anchor
    /// directly above or below it. The other passes deliberately reject pairs
    /// whose heights differ wildly — without that gate, aligned-series glues
    /// unrelated cells together — but legitimate captions are exactly that
    /// shape: a 20px text label above a 600px figure, or a 30px legend right
    /// under a 400px panel. This pass restores those links under these gates:
    ///   * `small.height ≤ 0.4 × big.height` (caption ratio)
    ///   * `big` is itself substantial (min dim ≥ `largeBoxThreshold`)
    ///   * `small` sits strictly above or below `big`
    ///   * If `small` is wider than `big`, it must also be proportionally very
    ///     thin (≤ 5% of `big.height`) and no wider than 1.5× — wide-and-short
    ///     reads as a long descriptive title; wide-and-medium-height reads as
    ///     a peer code cell.
    ///   * x-overlap covers ≥ 40% of `small.width` — tolerates slight
    ///     misalignment without letting an unrelated paragraph word qualify
    ///   * vertical gap ≤ 3 × `small.height`, both directions. The same
    ///     budget works for chart titles directly above a figure and for
    ///     x-axis titles that sit beneath a row of tick labels.
    /// Same-sea only; cross-sea captions are too risky without colour evidence.
    private func connectCaptions(seas: [Sea], network: inout [Box: [Box]],
                                 mergeDistance: Double) {
        let largeThreshold = largeBoxThreshold(mergeDistance)
        for sea in seas where sea.members.count > 1 {
            let members = sea.members
            for i in 0..<members.count {
                for j in (i + 1)..<members.count {
                    let a = members[i], b = members[j]
                    let small: Box, big: Box
                    if a.height < b.height { small = a; big = b }
                    else                   { small = b; big = a }

                    if Double(small.height) > Double(big.height) * 0.4 { continue }
                    if Double(min(big.width, big.height)) < largeThreshold { continue }
                    // A caption *can* be slightly wider than the anchor (long
                    // descriptive titles, axis labels that extend past the
                    // plot's box), but only if it's proportionally very thin —
                    // wide-and-short reads as a title; wide-and-medium-height
                    // is a peer code cell.
                    if small.width > big.width {
                        if small.width > big.width * 3 / 2 { continue }
                        if Double(small.height) > Double(big.height) * 0.05 { continue }
                    }

                    let above = small.bottom <= big.top
                    let below = small.top    >= big.bottom
                    guard above || below else { continue }

                    let xOverlap = min(small.right, big.right) - max(small.left, big.left)
                    if xOverlap <= 0 { continue }
                    // 40% lets a title sit slightly off-centre without losing
                    // the link; tight enough that an unrelated paragraph word
                    // that happens to project under the figure still misses.
                    if Double(xOverlap) < Double(small.width) * 0.4 { continue }

                    let gap = above ? (big.top - small.bottom) : (small.top - big.bottom)
                    // Equal budget above and below — x-axis titles sit beneath
                    // tick labels and need the same room as a chart title
                    // sitting above its plot.
                    let budget = Double(small.height) * 3.0
                    if Double(gap) > budget { continue }

                    linkBoxes(small, big, network: &network)
                }
            }
        }
    }

    /// Threshold above which a box's shorter dimension marks it as "large".
    /// Bridge and aligned-series passes refuse to link two boxes that are both
    /// over this size — without the gate they would re-merge things that the
    /// per-pair size penalty in `connectionProbability` deliberately split
    /// (e.g. notebook output cells stacked vertically, or a cell next to its
    /// embedded image).
    private func largeBoxThreshold(_ mergeDistance: Double) -> Double {
        mergeDistance * 8
    }

    /// Area ratio above which two boxes are considered "very different sized".
    /// When `big.area > asymRatio × small.area`, the link between them is added
    /// only in the `big → small` direction — hovering a tick label shouldn't
    /// drag in the heatmap above it, but hovering the heatmap should still
    /// pull in its labels. The threshold is deliberately generous (20×) so
    /// peer words on the same line stay bidirectional even when their widths
    /// differ a lot — "of" vs "Comparison" sits at roughly 12× and must
    /// remain a peer relation, while heatmap-vs-tick (≈350×) is clearly a
    /// container/label split.
    private let asymRatio: Double = 20.0

    /// Add an undirected geometric relation as one or two directed edges,
    /// depending on the size disparity between the boxes:
    ///   * Similar sizes (within `asymRatio`× area): both directions added.
    ///   * One box much larger: only the `large → small` direction is added.
    /// `expandCluster` walks forward edges only, so omitting the
    /// `small → large` edge prevents hovering a small thing from pulling its
    /// anchor into the selection while still letting the anchor reach down
    /// into its own labels/captions.
    private func linkBoxes(_ a: Box, _ b: Box, network: inout [Box: [Box]]) {
        let aArea = Double(a.area)
        let bArea = Double(b.area)
        let aMuchSmaller = aArea * asymRatio < bArea
        let bMuchSmaller = bArea * asymRatio < aArea
        if !aMuchSmaller, !(network[a]?.contains(b) ?? false) {
            network[a, default: []].append(b)
        }
        if !bMuchSmaller, !(network[b]?.contains(a) ?? false) {
            network[b, default: []].append(a)
        }
    }

    /// Final pass: connect boxes that read as part of a series — text on the
    /// same line, code lines stacked vertically, table rows, tab strips. The
    /// shared property is consistent *thickness* (height) along with a low gap
    /// in the other dimension; widths can differ wildly (e.g. "def" vs.
    /// "hello_world"), so we never gate on width similarity.
    private func connectAlignedSeries(seas: [Sea], network: inout [Box: [Box]],
                                      mergeDistance: Double) {
        let heightRatioMin: Double = 0.7   // heights within 30% of each other
        let projectionMin:  Double = 0.5   // ≥ 50% overlap on the perpendicular axis
        let gapFactor:      Double = 1.5   // gap ≤ 1.5× avg height
        let largeThreshold = largeBoxThreshold(mergeDistance)

        for sea in seas where sea.members.count > 1 {
            let members = sea.members
            for i in 0..<members.count {
                let a = members[i]
                for j in (i + 1)..<members.count {
                    let b = members[j]

                    // Two genuinely large boxes (notebook cells, big tiles)
                    // shouldn't be glued into one cluster just because they
                    // share a row or column — even with a 1.5× height gap
                    // budget the gap factor blows up at large heights.
                    let aLarge = Double(min(a.width, a.height)) > largeThreshold
                    let bLarge = Double(min(b.width, b.height)) > largeThreshold
                    if aLarge && bLarge { continue }

                    let xOverlap = min(a.right,  b.right)  - max(a.left, b.left)
                    let yOverlap = min(a.bottom, b.bottom) - max(a.top,  b.top)

                    let hRatio = Double(min(a.height, b.height)) / Double(max(a.height, b.height))
                    let avgH = Double(a.height + b.height) / 2.0

                    var connect = false

                    // Horizontal series — words on the same line, tab strips, etc.
                    // y-projections overlap (boxes share the same row), heights
                    // are similar, x-gap is small relative to the row height.
                    if yOverlap > 0 && xOverlap <= 0 {
                        let yFrac = Double(yOverlap) / Double(min(a.height, b.height))
                        let xGap  = Double(-xOverlap)
                        if yFrac >= projectionMin && hRatio >= heightRatioMin
                            && xGap <= avgH * gapFactor {
                            connect = true
                        }
                    }

                    // Vertical stack — code lines, list rows, paragraph blocks.
                    // x-projections overlap, heights similar, y-gap ≤ avg height.
                    // Width ratio also has to be reasonable: a 15px-wide tick
                    // label sitting under a 900px code cell shares a column on
                    // a `min(widths)` basis but absolutely isn't part of the
                    // same row, and without this gate the tick→cell-below link
                    // transitively pulls in the wrong cell when the user picks
                    // a figure above the tick.
                    if !connect && xOverlap > 0 && yOverlap <= 0 {
                        let xFrac = Double(xOverlap) / Double(min(a.width, b.width))
                        let widthRatio = Double(min(a.width, b.width)) / Double(max(a.width, b.width))
                        let yGap  = Double(-yOverlap)
                        if xFrac >= projectionMin && hRatio >= heightRatioMin
                            && widthRatio >= 0.3
                            && yGap <= avgH * gapFactor {
                            connect = true
                        }
                    }

                    guard connect else { continue }
                    linkBoxes(a, b, network: &network)
                }
            }
        }
    }

}
