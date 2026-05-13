import AppKit
import CoreGraphics
import Foundation

struct DetectionResult {
    let boxes: [Box]
    let network: [Box: [Box]]
    /// The seas that survived clustering — keyed by representative LAB colour, each
    /// holding the boxes belonging to that sea. Useful for debugging / visualisation.
    let seas: [(L: Int, a: Int, b: Int, members: [Box])]
    /// Per-box OCR classification. Boxes matched to a Vision word carry
    /// `.word(text, confidence, lineID)`; everything else is `.nonText`. The
    /// network and clustering passes don't consume this yet — it's plumbed
    /// through so debug output and the upcoming caption / paragraph /
    /// heading-vs-body passes can see it without re-running OCR.
    let tags: [Box: BoxKind]
    /// Raw Vision output, kept around so debug visualisation and later
    /// paragraph-inference passes can use line groupings directly rather
    /// than reverse-engineering them from tagged boxes.
    let words: [RecognizedWord]
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

        // Kick OCR off on a parallel worker while the LAB / Canny / morphology
        // / CC pipeline runs on this thread. Vision's `.fast` text recogniser
        // is independent of all the colour-domain work below, so the two
        // pipelines overlap cleanly and we pay roughly `max(ocr, cc)` instead
        // of their sum. Joined just before tagging.
        let ocrGroup = DispatchGroup()
        var recognizedWords: [RecognizedWord] = []
        ocrGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            recognizedWords = TextRecognition.recognizeWords(in: cgImage)
            ocrGroup.leave()
        }

        guard let lab = LABConverter.convert(cgImage) else {
            ocrGroup.wait()
            return DetectionResult(boxes: [], network: [:], seas: [],
                                   tags: [:], words: recognizedWords)
        }

        // 1. Edge detection on the L channel + morphological closing.
        let edges = EdgeDetect.canny(L: lab.L, width: lab.width, height: lab.height,
                                     lowThreshold: colorThreshold.0,
                                     highThreshold: colorThreshold.1)
        let closed = Morphology.close(edges, width: lab.width, height: lab.height,
                                      kw: kx, kh: ky)

        // 2. Connected-components labelling stands in for `findContours(RETR_TREE)`.
        //    The legacy `parentIndex` is intentionally unused now — the
        //    nested-children rule that consumed it was a font-size-blind
        //    proxy for "drop interior pieces of text", which the OCR-driven
        //    sub-letter pass below handles directly.
        let (allBoxes, _) = ConnectedComponents.label(closed,
                                                       width: lab.width,
                                                       height: lab.height)

        let initialCount = allBoxes.count

        // 3. Selectable-box filter — size and image-area bounds only.
        //    The old `maxChildArea` + parent-shape gate is removed (phase 4):
        //    nested-children was the legacy stand-in for "interior of a
        //    word/letter", and we now reject those text-internal CC blobs
        //    directly via `dropSubLetterBoxes` once OCR has reported the
        //    word boundaries.
        let imageArea = lab.width * lab.height
        let maxArea = Double(imageArea) * 0.6

        var selectableSet = Set<Box>()
        for box in allBoxes {
            if box.width  < kx || box.height < ky { continue }
            if Double(box.area) > maxArea          { continue }
            selectableSet.insert(box)
        }
        var selectable = Array(selectableSet)

        // 4. Join the OCR worker. We need word boundaries before the
        //    sub-letter / over-merge pass and the perimeter sampling that
        //    follows — selectable filter above is cheap, so by the time we
        //    arrive here the OCR worker has typically already finished and
        //    `wait()` is close to a no-op.
        ocrGroup.wait()

        // 5. OCR-driven cleanups, in order:
        //
        //    a. `applyVisionBoxes` — in regions Vision identifies as text,
        //       prefer Vision's word-level boxes over CC's coarser
        //       morphology-derived ones. The morphology kernel is a single
        //       size for the whole image and chronically glues multiple
        //       words at small font sizes; Vision is font-size-blind and
        //       puts boundaries in the right places. CC boxes whose
        //       interior is densely covered by recognised words get
        //       dropped; every Vision word is added as a selectable. This
        //       also fixes the long-standing "Vision sees a word but the
        //       pipeline never exposes it as a box" gap — missed CC
        //       regions are recovered by the unconditional word add.
        //    b. `dropSubLetterBoxes` — remove residual letter-internal CC
        //       blobs (the dot of "i", the counter of "o", a stem fragment)
        //       that sit fully inside a Vision word and are much smaller
        //       than it. These survived step (a) because their parent CC
        //       was either a non-text container kept around, or because
        //       Vision didn't quite cover the surrounding region.
        selectable = applyVisionBoxes(selectable, words: recognizedWords)
        selectable = dropSubLetterBoxes(selectable, words: recognizedWords)

        // 6. Sea-colour sampling → stable boxes + per-box sea colour. Two
        //    strategies, depending on the box's origin:
        //
        //    * Vision-derived word boxes (`visionDerived`): sample the
        //      *interior* of an expanded box and pick the dominant colour
        //      (mode of an LAB histogram). Perimeter sampling fails for
        //      words in two ways — left/right margins hit adjacent words,
        //      and below-margin hits underlines / descenders when the
        //      Vision box excludes them. Sampling the interior of a box
        //      grown by half its dimensions on each side lets the
        //      surrounding background dominate the histogram (the glyph
        //      occupies only ~10–15 % of the expanded area), so two words
        //      on the same background reliably land in the same sea
        //      regardless of glyph density, underlines, or descenders.
        //      The calmness gate doesn't apply — Vision already told us
        //      the region is real text.
        //
        //    * Non-text CC boxes (everything else): perimeter sampling +
        //      calmness gate, unchanged. We're grouping by *surrounding
        //      context* there (a button's sea is the page background it
        //      sits on), which is exactly what the perimeter samples.
        let visionDerived: Set<Box> = Set(recognizedWords.map { $0.box })
        var stableBoxes: [Box] = []
        var seaColours: [((Int, Int, Int), (Int, Int, Int))] = []
        for box in selectable {
            if visionDerived.contains(box) {
                guard let pair = interiorColourPair(lab: lab, box: box) else { continue }
                stableBoxes.append(box)
                seaColours.append(pair)
            } else {
                guard let (colour, calm) = seaColourAndValidity(lab: lab, box: box),
                      calm else { continue }
                stableBoxes.append(box)
                seaColours.append((colour, colour))   // degenerate single-colour pair
            }
        }
        selectable = stableBoxes

        // 7. Group boxes into seas by LAB-colour proximity.
        let seas = groupIntoSeas(boxes: selectable, colours: seaColours)

        // 8. Vision-line paragraph index + sizes. Computed here (rather than
        //    inside `buildNetwork`) so the debug visualisation can show the
        //    same classification the network construction uses.
        let lineToParagraph = paragraphIndex(for: recognizedWords)
        let paragraphSize = paragraphSizes(words: recognizedWords,
                                           lineToParagraph: lineToParagraph)

        // Median Vision-word area. Used by `pruneLargeBoxConnections` to
        // define "large" (= ≥ 20 × median word area). Median rather than
        // mean so a stray banner-text Vision detection doesn't inflate
        // the baseline. Fallback 400 (~ 20×20 word) if Vision produced
        // nothing recognisable.
        let medianWordArea: Double = {
            let areas = recognizedWords.map { Double($0.box.area) }.sorted()
            guard !areas.isEmpty else { return 400.0 }
            return areas[areas.count / 2]
        }()

        // 9. Tag boxes and build the adjacency network.
        let tags = TextRecognition.tagBoxes(selectable, using: recognizedWords)
        let network = buildNetwork(boxes: selectable, seas: seas, tags: tags,
                                   lineToParagraph: lineToParagraph,
                                   paragraphSize: paragraphSize,
                                   medianWordArea: medianWordArea)

        let seasOut = seas.map { (L: $0.primaryColour.0,
                                  a: $0.primaryColour.1,
                                  b: $0.primaryColour.2,
                                  members: $0.members) }

        if Config.debug {
            let wordCount = tags.values.reduce(0) { acc, t in
                if case .word = t { return acc + 1 } else { return acc }
            }
            NSLog("[HoverShot] grouped %d boxes into %d boxes across %d seas (initial %d); OCR matched %d/%d",
                  initialCount, selectable.count, seas.count, initialCount,
                  wordCount, recognizedWords.count)
            DebugImageWriter.writeIfEnabled(
                source: cgImage,
                edges: edges,
                width: lab.width,
                height: lab.height,
                seas: seas,
                network: network,
                words: recognizedWords,
                lineToParagraph: lineToParagraph,
                paragraphSize: paragraphSize
            )
        }

        return DetectionResult(boxes: selectable, network: network, seas: seasOut,
                               tags: tags, words: recognizedWords)
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

    /// Pair of dominant LAB colours inside a Vision word box, found by
    /// streaming-cluster sampling: each sample joins an existing cluster
    /// whose centre is within ~6 LAB units, or starts a new one. The most
    /// populated cluster's centre is the **primary** colour, and the next
    /// cluster whose centre is *contrastingly far* (LAB distance > 30) is
    /// the **secondary**. Returns `(primary, primary)` if the box is
    /// effectively single-colour (no contrasting second cluster found).
    ///
    /// Clustering instead of fixed-bin histograms because the sea-grouping
    /// threshold (3 LAB units) is finer than any practical bin size; with
    /// bins, two near-identical samples can straddle a bin boundary and
    /// produce two centres that the sea grouper treats as different.
    /// Clustering's running-mean centre tracks the true colour to within
    /// the merge threshold, so an underlined word and a non-underlined one
    /// on the same background land on the same primary regardless of the
    /// small underline contribution.
    ///
    /// The "two most prominent contrasting colours" formulation comes from
    /// the observation that for tight Vision word boxes the densest
    /// cluster is often *text* (black, say) rather than background, since
    /// glyphs can occupy a majority of a tight box at body sizes. We
    /// return both colours and let `seaPairsMatch` decide pairwise — that
    /// way swapping which one is text vs. background between two
    /// otherwise-identical words doesn't fragment the sea.
    private func interiorColourPair(lab: LABImage, box: Box) -> ((Int, Int, Int), (Int, Int, Int))? {
        let totalPixels = box.width * box.height
        guard totalPixels > 0 else { return nil }

        let targetSamples: Double = 400
        let stride = max(1, Int((Double(totalPixels) / targetSamples).squareRoot()))

        // Cluster merge threshold (squared). 6 LAB units covers anti-alias
        // halos and minor jpeg-style noise without lumping distinct
        // colours together.
        let mergeThresholdSq: Int = 6 * 6
        struct Cluster {
            var sumL: Int, sumA: Int, sumB: Int, count: Int
            var center: (Int, Int, Int)
        }
        var clusters: [Cluster] = []

        var y = box.y
        while y < box.y + box.height {
            var x = box.x
            while x < box.x + box.width {
                if let s = lab.sample(x: x, y: y) {
                    var matched = false
                    for i in 0..<clusters.count {
                        let c = clusters[i].center
                        let dl = c.0 - s.0, da = c.1 - s.1, db = c.2 - s.2
                        if dl * dl + da * da + db * db < mergeThresholdSq {
                            clusters[i].sumL += s.0
                            clusters[i].sumA += s.1
                            clusters[i].sumB += s.2
                            clusters[i].count += 1
                            let n = clusters[i].count
                            clusters[i].center = (
                                clusters[i].sumL / n,
                                clusters[i].sumA / n,
                                clusters[i].sumB / n
                            )
                            matched = true
                            break
                        }
                    }
                    if !matched {
                        clusters.append(Cluster(
                            sumL: s.0, sumA: s.1, sumB: s.2, count: 1, center: s
                        ))
                    }
                }
                x += stride
            }
            y += stride
        }

        let sorted = clusters.sorted { $0.count > $1.count }
        guard let primary = sorted.first else { return nil }
        let primaryColour = primary.center

        let contrastThresholdSq = 30 * 30
        for c in sorted.dropFirst() {
            let dl = c.center.0 - primaryColour.0
            let da = c.center.1 - primaryColour.1
            let db = c.center.2 - primaryColour.2
            if dl * dl + da * da + db * db > contrastThresholdSq {
                return (primaryColour, c.center)
            }
        }
        return (primaryColour, primaryColour)
    }

    struct Sea {
        /// Primary colour — for text words, the most-populated cluster
        /// inside the tight box (often the text colour). For non-text
        /// boxes, the mean of perimeter samples.
        var primaryColour: (Int, Int, Int)
        /// Secondary colour — the first contrasting cluster (> 30 LAB
        /// units from primary) for text words; equal to `primaryColour`
        /// for non-text boxes (degenerate single-colour pair).
        var secondaryColour: (Int, Int, Int)
        var members: [Box]
    }

    /// Compare two colour pairs for sea-membership equivalence.
    ///
    /// Cases:
    ///   * Both pairs degenerate (single colour): match if those colours
    ///     are within `t²` LAB distance squared. Standard single-colour
    ///     comparison.
    ///   * One degenerate, one distinct: match if the degenerate colour
    ///     is within `t²` of *either* colour in the distinct pair. This
    ///     handles the caption-and-anchor case — a chart with perimeter
    ///     colour X is in the same sea as a word with background X and
    ///     any text colour, so captions don't need cross-sea linking.
    ///   * Both distinct: match if some pairing of colours puts both
    ///     pairs of corresponding colours within `t²`. Two words on the
    ///     same background with the same text colour share a sea even if
    ///     primary/secondary roles are swapped between them; two words
    ///     with the same background but *different* text colours
    ///     (highlighted link in a paragraph, say) do *not* share — that's
    ///     an accepted trade-off for cleanly handling the underline case.
    private func seaPairsMatch(_ a: ((Int, Int, Int), (Int, Int, Int)),
                                _ b: ((Int, Int, Int), (Int, Int, Int)),
                                tSq: Int) -> Bool {
        let aDegen = labDistanceSq(a.0, a.1) < tSq
        let bDegen = labDistanceSq(b.0, b.1) < tSq
        if aDegen && bDegen {
            return labDistanceSq(a.0, b.0) < tSq
        }
        if aDegen {
            return labDistanceSq(a.0, b.0) < tSq || labDistanceSq(a.0, b.1) < tSq
        }
        if bDegen {
            return labDistanceSq(b.0, a.0) < tSq || labDistanceSq(b.0, a.1) < tSq
        }
        return (labDistanceSq(a.0, b.0) < tSq && labDistanceSq(a.1, b.1) < tSq)
            || (labDistanceSq(a.0, b.1) < tSq && labDistanceSq(a.1, b.0) < tSq)
    }

    @inline(__always)
    private func labDistanceSq(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Int {
        let dl = a.0 - b.0, da = a.1 - b.1, db = a.2 - b.2
        return dl * dl + da * da + db * db
    }

    /// Grow seas in encounter order using pair-based matching. A new box
    /// joins the first existing sea whose colour pair matches its own
    /// (`seaPairsMatch`); otherwise it starts a new sea.
    private func groupIntoSeas(
        boxes: [Box],
        colours: [((Int, Int, Int), (Int, Int, Int))]
    ) -> [Sea] {
        var seas: [Sea] = []
        let t = colorThreshold.0
        let tSq = t * t
        for (box, pair) in zip(boxes, colours) {
            var joined = false
            for i in 0..<seas.count {
                let seaPair = (seas[i].primaryColour, seas[i].secondaryColour)
                if seaPairsMatch(seaPair, pair, tSq: tSq) {
                    seas[i].members.append(box)
                    joined = true
                    break
                }
            }
            if !joined {
                seas.append(Sea(primaryColour: pair.0,
                                secondaryColour: pair.1,
                                members: [box]))
            }
        }
        return seas
    }

    // MARK: - Network construction

    /// One main pass plus several post-processing passes, run in order:
    ///   * Per-sea pairwise `connectionProbability`, threshold 0.5.
    ///   * `pruneOutlierConnections` — area-median outlier pruning. Runs
    ///     first so the additive series/caption passes start from a clean
    ///     base; an outlier edge here would otherwise drag in its
    ///     neighbour-set during those passes and survive intact.
    ///   * `connectAlignedSeries` for stacked rows / inline text segments.
    ///   * `connectCaptions` — OCR-aware text-label-to-anchor linker.
    ///   * `pruneCrossingConnections` — drop edges whose shortest connecting
    ///     segment cuts through an unrelated box.
    ///   * `pruneParagraphAnchors` (phase 5) — for words living in a
    ///     paragraph of N≥30 words, drop links to giant non-text neighbours.
    ///     A single caption legitimately attaches to a figure; a body
    ///     paragraph does not.
    ///   * `applyHeadingAsymmetry` (phase 3) — for heading-sized words,
    ///     suppress the `body → heading` direction so cluster-expansion
    ///     from a heading pulls in its body, but never the reverse.
    ///
    /// Engulfment is never connected. The Python `_connect_noisy_boxes` step that
    /// linked nested children to their containing parent is intentionally absent
    /// here — full containment splits cluster intent more often than it helps.
    private func buildNetwork(boxes: [Box], seas: [Sea],
                              tags: [Box: BoxKind],
                              lineToParagraph: [Int: Int],
                              paragraphSize: [Int: Int],
                              medianWordArea: Double) -> [Box: [Box]] {
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
                    // Asymmetric area gate — much-smaller boxes don't get
                    // forward edges to much-larger ones, regardless of
                    // probability. Existing rule.
                    if boxArea * asymRatio < Double(other.area) { continue }
                    if box.connectionProbability(other, mergeDistance: mergeDistance) > 0.5 {
                        connections.append(other)
                    }
                }
                network[box] = connections
            }
        }

        pruneOutlierConnections(network: &network)
        connectAlignedSeries(seas: seas, tags: tags,
                             network: &network, mergeDistance: mergeDistance)
        connectCaptions(boxes: boxes, tags: tags, seas: seas,
                        lineToParagraph: lineToParagraph,
                        paragraphSize: paragraphSize,
                        network: &network, mergeDistance: mergeDistance)
        pruneCrossingConnections(boxes: boxes, network: &network)
        pruneLargeBoxConnections(tags: tags,
                                 lineToParagraph: lineToParagraph,
                                 paragraphSize: paragraphSize,
                                 medianWordArea: medianWordArea,
                                 network: &network)
        pruneParagraphAnchors(tags: tags,
                              lineToParagraph: lineToParagraph,
                              paragraphSize: paragraphSize,
                              network: &network)
        applyHeadingAsymmetry(tags: tags, network: &network)
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

    /// Drop edges whose shortest connecting segment passes through the
    /// interior of a third box that isn't a neighbour of either endpoint.
    /// The motivating case is a cross-sea or wide-gap link where two boxes
    /// got connected "over" an unrelated element sitting between them — once
    /// `expandCluster` walks the edge, the unrelated box's own neighbourhood
    /// can be pulled in via its other links.
    ///
    /// "Shortest segment" is edge-to-edge, not centre-to-centre: when the
    /// boxes share a row, the segment is horizontal at the midpoint of their
    /// y-projection overlap; when they share a column, vertical at the
    /// x-projection midpoint; otherwise corner-to-corner. The line therefore
    /// runs through the empty gap between the boxes, which is where a
    /// blocker would actually sit.
    ///
    /// A blocker is any box C (≠ A, B) that:
    ///   * is not in `network[A]` or `network[B]` (either direction —
    ///     `linkBoxes` may create one-way edges for size-asymmetric pairs,
    ///     and we want a directed A→B to still count B as A's neighbour for
    ///     this purpose);
    ///   * does not envelop the segment (both endpoints inside C). A
    ///     containing element — page panel, card, notebook cell — is
    ///     non-adjacent to its children (engulfment edges are forbidden by
    ///     `connectionProbability`), so without this gate every adjacent
    ///     word in a paragraph that sits inside a container would have its
    ///     edge pruned because the short word-to-word segment lies inside
    ///     the container's interior. Skip C if it wraps the segment; only
    ///     boxes that separate the endpoints (segment exits C between them)
    ///     count as blockers; and
    ///   * the segment's interior crosses (Liang–Barsky clip with strict
    ///     `tmin < tmax`, so tangents / corner touches don't trigger).
    ///
    /// Overlapping pairs are skipped: there is no separating gap to inspect.
    /// Touching pairs (edge distance = 0, no overlap on either axis) yield a
    /// zero-length segment and are also skipped.
    ///
    /// Removal is symmetric, mirroring the other prune passes.
    private func pruneCrossingConnections(boxes: [Box], network: inout [Box: [Box]]) {
        // Undirected neighbour membership: a directed A→B still counts B as
        // A's neighbour (and vice versa) for the blocker test.
        var neighbourSet: [Box: Set<Box>] = [:]
        for (origin, targets) in network {
            for target in targets {
                neighbourSet[origin, default: []].insert(target)
                neighbourSet[target, default: []].insert(origin)
            }
        }

        var toPrune: [(Box, Box)] = []
        for (a, neighbours) in network {
            for b in neighbours {
                guard let segment = shortestSegment(a, b) else { continue }
                for c in boxes where c != a && c != b {
                    if neighbourSet[a]?.contains(c) == true { continue }
                    if neighbourSet[b]?.contains(c) == true { continue }
                    if pointInside(segment.0, box: c)
                        && pointInside(segment.1, box: c) { continue }
                    if segmentIntersectsBox(p1: segment.0, p2: segment.1, box: c) {
                        toPrune.append((a, b))
                        break
                    }
                }
            }
        }

        for (a, b) in toPrune {
            network[a]?.removeAll { $0 == b }
            network[b]?.removeAll { $0 == a }
        }
    }

    /// Endpoints of the shortest segment between two axis-aligned boxes:
    /// midpoint of the projection overlap on whichever axis they overlap,
    /// nearest edge coordinate on the axis they don't. Returns nil for
    /// overlapping or touching pairs where the segment degenerates to a
    /// point.
    private func shortestSegment(_ a: Box, _ b: Box) -> ((Double, Double), (Double, Double))? {
        let xa: Double, xb: Double
        if a.right <= b.left {
            xa = Double(a.right); xb = Double(b.left)
        } else if b.right <= a.left {
            xa = Double(a.left);  xb = Double(b.right)
        } else {
            let mid = Double(max(a.left, b.left) + min(a.right, b.right)) / 2.0
            xa = mid; xb = mid
        }
        let ya: Double, yb: Double
        if a.bottom <= b.top {
            ya = Double(a.bottom); yb = Double(b.top)
        } else if b.bottom <= a.top {
            ya = Double(a.top);    yb = Double(b.bottom)
        } else {
            let mid = Double(max(a.top, b.top) + min(a.bottom, b.bottom)) / 2.0
            ya = mid; yb = mid
        }
        if xa == xb && ya == yb { return nil }
        return ((xa, ya), (xb, yb))
    }

    /// Inclusive point-in-box test (boundary counts as inside). Used to
    /// detect when a candidate blocker actually wraps the segment rather
    /// than cutting across it.
    private func pointInside(_ p: (Double, Double), box: Box) -> Bool {
        return p.0 >= Double(box.left) && p.0 <= Double(box.right)
            && p.1 >= Double(box.top)  && p.1 <= Double(box.bottom)
    }

    /// Liang–Barsky clip: does the open segment (p1, p2) cross the interior
    /// of `box`? Strict `tmin < tmax` so touches / tangents return false.
    private func segmentIntersectsBox(p1: (Double, Double), p2: (Double, Double),
                                      box: Box) -> Bool {
        let xmin = Double(box.left), xmax = Double(box.right)
        let ymin = Double(box.top),  ymax = Double(box.bottom)
        let dx = p2.0 - p1.0, dy = p2.1 - p1.1
        let ps: [Double] = [-dx,  dx, -dy,  dy]
        let qs: [Double] = [p1.0 - xmin, xmax - p1.0, p1.1 - ymin, ymax - p1.1]

        var tmin: Double = 0, tmax: Double = 1
        for i in 0..<4 {
            let p = ps[i], q = qs[i]
            if p == 0 {
                if q < 0 { return false }
            } else {
                let t = q / p
                if p < 0 {
                    if t > tmax { return false }
                    if t > tmin { tmin = t }
                } else {
                    if t < tmin { return false }
                    if t < tmax { tmax = t }
                }
            }
        }
        return tmin < tmax
    }

    /// Link a `.word` to a substantial `.nonText` anchor whenever the
    /// word sits very close to one of the anchor's edges — a chart title
    /// above a plot, an axis label below a row of ticks, a legend right
    /// next to a panel.
    ///
    /// Gates (in order):
    ///   * Anchor must be substantial (`min(w, h) ≥ largeBoxThreshold`).
    ///   * `word.height ≤ 0.4 × anchor.height`.
    ///   * Same sea (cross-sea is too eager when applied broadly).
    ///   * **Direction-aware edge proximity**. Edge-to-edge gaps (not
    ///     centre-to-centre); same proximity budget on each axis:
    ///     `budget = min(anchor.width, anchor.height) / 8`.
    ///       * x-overlap > 0, y-overlap = 0 (word above or below):
    ///         require `y-gap ≤ budget`.
    ///       * y-overlap > 0, x-overlap = 0 (word to the side of):
    ///         require `x-gap ≤ budget`.
    ///       * Both overlap (word inside anchor): reject — that's a
    ///         label on top of the box, not a caption around its edge.
    ///       * Neither overlap (corner-position): reject — captions sit
    ///         on an edge.
    ///
    /// Using the smaller of `width/8` and `height/8` keeps elongated
    /// anchors (e.g. a 1000×120 banner) from adopting captions that are
    /// far away along their shorter axis — `height/8` is the relevant
    /// scale there, not `width/8`.
    ///
    /// Multi-word lines propagate: once any word on a Vision line links
    /// to an anchor, every word with the same `lineID` links too. Keeps
    /// "Time (s)" intact when only the first word passed proximity.
    private func connectCaptions(boxes: [Box],
                                 tags: [Box: BoxKind],
                                 seas: [Sea],
                                 lineToParagraph: [Int: Int],
                                 paragraphSize: [Int: Int],
                                 network: inout [Box: [Box]],
                                 mergeDistance: Double) {
        let largeThreshold = largeBoxThreshold(mergeDistance)
        // Single proximity budget shared by both axes:
        // `min(anchor.width, anchor.height) / 8`. Edge-to-edge gaps.
        // For non-square anchors the shorter axis controls — a 1000×120
        // banner uses 15 (= 120/8), not 125, as the cap.
        let proximityDivisor: Double = 8.0

        var words: [Box] = []
        var anchors: [Box] = []
        for box in boxes {
            switch tags[box] {
            case .word:         words.append(box)
            case .nonText, nil: anchors.append(box)
            }
        }

        var seaOf: [Box: Int] = [:]
        seaOf.reserveCapacity(boxes.count)
        for (idx, sea) in seas.enumerated() {
            for box in sea.members { seaOf[box] = idx }
        }

        var captionEdges: [(word: Box, anchor: Box)] = []
        for word in words {
            for anchor in anchors {
                if Double(min(anchor.width, anchor.height)) < largeThreshold { continue }
                if Double(word.height) > Double(anchor.height) * 0.4 { continue }

                // Same-sea only — captions across colour boundaries are
                // too risky without per-element grouping evidence.
                if let wordSea = seaOf[word], let anchorSea = seaOf[anchor],
                   wordSea != anchorSea { continue }

                let xOverlap = min(word.right, anchor.right) - max(word.left, anchor.left)
                let yOverlap = min(word.bottom, anchor.bottom) - max(word.top, anchor.top)

                if xOverlap > 0 && yOverlap > 0 {
                    // Word is inside the anchor — label, not caption.
                    continue
                }

                let budget = Double(min(anchor.width, anchor.height)) / proximityDivisor

                if xOverlap > 0 {
                    // Word above or below — check the edge-to-edge y-gap.
                    let yGap = word.bottom <= anchor.top
                        ? anchor.top - word.bottom
                        : word.top - anchor.bottom
                    if Double(yGap) > budget { continue }
                } else if yOverlap > 0 {
                    // Word to the side — check the edge-to-edge x-gap.
                    let xGap = word.right <= anchor.left
                        ? anchor.left - word.right
                        : word.left - anchor.right
                    if Double(xGap) > budget { continue }
                } else {
                    // No overlap on either axis — corner position. Reject.
                    continue
                }

                captionEdges.append((word, anchor))
            }
        }

        for (w, a) in captionEdges {
            linkBoxes(w, a, network: &network)
        }

        // Line propagation — once any word on a Vision line links to an
        // anchor, every word with the same `lineID` links too. Multi-
        // word captions like "Time (s)" stay intact even when only one
        // of the words passed the proximity gate.
        var wordsByLine: [Int: [Box]] = [:]
        for word in words {
            if case let .word(_, _, lineID) = tags[word] {
                wordsByLine[lineID, default: []].append(word)
            }
        }
        var anchorsByLine: [Int: Set<Box>] = [:]
        for (w, a) in captionEdges {
            if case let .word(_, _, lineID) = tags[w] {
                anchorsByLine[lineID, default: []].insert(a)
            }
        }
        for (lineID, anchorSet) in anchorsByLine {
            guard let lineWords = wordsByLine[lineID] else { continue }
            for anchor in anchorSet {
                for w in lineWords {
                    linkBoxes(w, anchor, network: &network)
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
    ///
    /// Text-text relaxation: when both boxes are tagged `.word`, the gates
    /// relax — the heightRatio gate drops, `projectionMin` shrinks to 0.3,
    /// and the gap budget grows to 2.5× avg height. Rationale:
    ///   * Words on the same line connect even with awkward x-overlap (a
    ///     thin "(s)" next to "Time" doesn't satisfy the 50% projection
    ///     gate, but they should still chain).
    ///   * Words in adjacent lines connect across the typical inter-line
    ///     gap, which can exceed 1.5× avg height especially in spacious
    ///     layouts.
    ///   * Heading-vs-body height ratios that fail the 0.7 default now
    ///     link bidirectionally; `applyHeadingAsymmetry` strips the
    ///     `body → heading` direction afterward, leaving the desired
    ///     "heading expands to body" behaviour.
    /// Non-text or mixed pairs keep the original stricter gates so an
    /// icon-vs-label or chart-vs-tick pair doesn't get glued.
    private func connectAlignedSeries(seas: [Sea],
                                      tags: [Box: BoxKind],
                                      network: inout [Box: [Box]],
                                      mergeDistance: Double) {
        let heightRatioMin: Double = 0.7
        let projectionMin:  Double = 0.5
        let gapFactor:      Double = 1.5
        let textProjectionMin: Double = 0.3
        let textGapFactor:     Double = 2.5
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

                    let aWord: Bool
                    if case .word = tags[a] { aWord = true } else { aWord = false }
                    let bWord: Bool
                    if case .word = tags[b] { bWord = true } else { bWord = false }
                    let bothText = aWord && bWord

                    let xOverlap = min(a.right,  b.right)  - max(a.left, b.left)
                    let yOverlap = min(a.bottom, b.bottom) - max(a.top,  b.top)

                    let hRatio = Double(min(a.height, b.height)) / Double(max(a.height, b.height))
                    let avgH = Double(a.height + b.height) / 2.0

                    let effProjectionMin = bothText ? textProjectionMin : projectionMin
                    let effGapFactor     = bothText ? textGapFactor     : gapFactor
                    let effHeightGate    = bothText ? 0.0                : heightRatioMin

                    var connect = false

                    // Horizontal series — words on the same line, tab strips, etc.
                    if yOverlap > 0 && xOverlap <= 0 {
                        let yFrac = Double(yOverlap) / Double(min(a.height, b.height))
                        let xGap  = Double(-xOverlap)
                        if yFrac >= effProjectionMin && hRatio >= effHeightGate
                            && xGap <= avgH * effGapFactor {
                            connect = true
                        }
                    }

                    // Vertical stack — code lines, list rows, paragraph blocks.
                    // x-projections overlap, heights similar, y-gap small.
                    // Width ratio gate keeps a 15px tick label from chaining
                    // to a 900px code cell beneath it just because they share
                    // a column on a `min(widths)` basis — but that gate only
                    // makes sense when at least one side is non-text; two
                    // text words of wildly different widths ("of" vs.
                    // "Comparison") legitimately belong in the same column.
                    if !connect && xOverlap > 0 && yOverlap <= 0 {
                        let xFrac = Double(xOverlap) / Double(min(a.width, b.width))
                        let widthRatio = Double(min(a.width, b.width)) / Double(max(a.width, b.width))
                        let widthGate = bothText ? 0.0 : 0.3
                        let yGap  = Double(-yOverlap)
                        if xFrac >= effProjectionMin && hRatio >= effHeightGate
                            && widthRatio >= widthGate
                            && yGap <= avgH * effGapFactor {
                            connect = true
                        }
                    }

                    guard connect else { continue }
                    linkBoxes(a, b, network: &network)
                }
            }
        }
    }

    // MARK: - OCR-driven box cleanups (phase 4)

    /// Drop CC boxes that are sub-parts of a Vision word — the dot of "i",
    /// the inner counter of "o", a stem fragment that connected-components
    /// labelled as its own region. These pollute the network with
    /// text-internal links and serve no useful selection purpose.
    ///
    /// A box `B` is sub-letter if some Vision word `W` covers ≥ 80% of
    /// `B`'s area and `W` is at least 2× larger than `B`. The 2× size
    /// guard prevents the rule from firing on a tight UI element whose
    /// bounds happen to closely match its embedded text (a small button
    /// labelled "OK", say) — the word and the surrounding box have
    /// similar areas there, so the guard rejects the pruning.
    private func dropSubLetterBoxes(_ boxes: [Box],
                                    words: [RecognizedWord]) -> [Box] {
        let coverageRequired: Double = 0.8
        let minSizeRatio: Double = 2.0
        return boxes.filter { box in
            for word in words {
                let inter = word.box.overlap(box)
                guard inter > 0 else { continue }
                let coverage = inter / Double(box.area)
                if coverage >= coverageRequired
                    && Double(word.box.area) >= Double(box.area) * minSizeRatio {
                    return false
                }
            }
            return true
        }
    }

    /// OCR-first box selection. In regions Vision identifies as text,
    /// prefer Vision's word-level boxes over the coarser CC ones. The
    /// motivation is twofold: (1) CC's morphology kernel is one-size-fits-
    /// all and chronically glues multiple words at small font sizes,
    /// producing a single CC region where the user wanted word-level
    /// granularity; (2) Vision detects words that CC sometimes misses
    /// entirely (low-contrast text, tight ligatures, unusual fonts), and
    /// without this step those words never become selectable.
    ///
    /// Algorithm:
    ///   1. For each CC box, compute the total Vision-word area
    ///      substantially inside it (≥ 50% of word area in the CC box).
    ///      If that area covers ≥ 50% of the CC box's area, the CC is a
    ///      "text region" — drop it. Vision word boxes added in step 2
    ///      take its place.
    ///   2. Add every Vision word box to the selectable list (deduped by
    ///      `Box` equality). Words inside a kept CC (e.g. the label on a
    ///      button) are added in addition to the CC, so both become
    ///      selectable; words inside a dropped text-region CC are
    ///      introduced here for the first time; words that no CC box ever
    ///      saw are recovered.
    ///
    /// The 50% coverage gate distinguishes text regions (line of body
    /// text, wide heading) from UI containers that happen to hold text (a
    /// button labelled "Save now") — the latter typically have far more
    /// non-text area than text, so the gate doesn't fire and the
    /// container stays whole alongside its word boxes.
    private func applyVisionBoxes(_ boxes: [Box],
                                  words: [RecognizedWord]) -> [Box] {
        let wordCoverageInBox: Double = 0.5
        let dropCoverage: Double = 0.5

        var dropped: Set<Box> = []
        for box in boxes {
            var totalWordArea = 0
            for w in words {
                let inter = box.overlap(w.box)
                guard inter > 0 else { continue }
                if inter / Double(w.box.area) < wordCoverageInBox { continue }
                totalWordArea += w.box.area
            }
            if Double(totalWordArea) >= Double(box.area) * dropCoverage {
                dropped.insert(box)
            }
        }

        var seen: Set<Box> = []
        var result: [Box] = []
        result.reserveCapacity(boxes.count + words.count)
        for box in boxes where !dropped.contains(box) {
            if seen.insert(box).inserted { result.append(box) }
        }
        for word in words {
            if seen.insert(word.box).inserted { result.append(word.box) }
        }
        return result
    }

    // MARK: - Paragraph-aware pruning (phase 5)

    /// Group Vision lines into paragraphs by vertical adjacency + x-extent
    /// overlap, using union-find so multi-column layouts don't break apart
    /// when lines interleave by y-position. Two lines join the same
    /// paragraph when:
    ///   * `y-gap ≤ avg(line heights)` (within typical line spacing), and
    ///   * `x-overlap ≥ 30% × min(line widths)` (share a column).
    ///
    /// Returns `lineID → paragraphIndex`. A standalone line that doesn't
    /// chain to any neighbour ends up in a paragraph of size 1, which the
    /// classifier downstream treats as a one-word caption / label.
    ///
    /// Why union-find instead of pairwise-consecutive: with two columns of
    /// body text running side by side, sorting by `top` interleaves them
    /// (A1, B1, A2, B2, ...). A consecutive-pair walk would never link A1
    /// to A2 because B1 sits between them in the sorted order. Union-find
    /// on all qualifying pairs preserves column structure.
    private func paragraphIndex(for words: [RecognizedWord]) -> [Int: Int] {
        var byLine: [Int: [RecognizedWord]] = [:]
        for w in words { byLine[w.lineID, default: []].append(w) }
        if byLine.isEmpty { return [:] }

        struct LineBox { let id: Int; let box: Box }
        var lines: [LineBox] = []
        for (id, lineWords) in byLine {
            let xMin = lineWords.map { $0.box.left }.min() ?? 0
            let xMax = lineWords.map { $0.box.right }.max() ?? 0
            let yMin = lineWords.map { $0.box.top }.min() ?? 0
            let yMax = lineWords.map { $0.box.bottom }.max() ?? 0
            lines.append(LineBox(id: id, box: Box(
                x: xMin, y: yMin,
                width: max(1, xMax - xMin),
                height: max(1, yMax - yMin)
            )))
        }

        let yGapFactor: Double = 1.0
        let xOverlapFraction: Double = 0.3

        var parent = Array(0..<lines.count)
        func find(_ x: Int) -> Int {
            var cur = x
            while parent[cur] != cur {
                parent[cur] = parent[parent[cur]]
                cur = parent[cur]
            }
            return cur
        }
        for i in 0..<lines.count {
            for j in (i + 1)..<lines.count {
                let a = lines[i].box, b = lines[j].box
                let yDist: Int
                if a.bottom <= b.top {
                    yDist = b.top - a.bottom
                } else if b.bottom <= a.top {
                    yDist = a.top - b.bottom
                } else {
                    yDist = 0
                }
                let avgH = (a.height + b.height) / 2
                if Double(yDist) > Double(avgH) * yGapFactor { continue }
                let xOverlap = min(a.right, b.right) - max(a.left, b.left)
                if xOverlap <= 0 { continue }
                let minW = min(a.width, b.width)
                if Double(xOverlap) < Double(minW) * xOverlapFraction { continue }
                let ra = find(i), rb = find(j)
                if ra != rb { parent[ra] = rb }
            }
        }

        var rootToPara: [Int: Int] = [:]
        var nextPara = 0
        var paraOfLine: [Int: Int] = [:]
        for i in 0..<lines.count {
            let root = find(i)
            if rootToPara[root] == nil {
                rootToPara[root] = nextPara
                nextPara += 1
            }
            paraOfLine[lines[i].id] = rootToPara[root]
        }
        return paraOfLine
    }

    /// Compute `paragraphIndex → word count` from a Vision word list and a
    /// `lineID → paragraphIndex` map. The size is the total number of
    /// Vision words in the paragraph, regardless of how many of them
    /// survived later filtering — we're classifying *the text's nature*
    /// (caption / sentence / paragraph), and a missed word in the
    /// selectable pipeline shouldn't change that classification.
    private func paragraphSizes(words: [RecognizedWord],
                                lineToParagraph: [Int: Int]) -> [Int: Int] {
        var sizes: [Int: Int] = [:]
        for w in words {
            guard let para = lineToParagraph[w.lineID] else { continue }
            sizes[para, default: 0] += 1
        }
        return sizes
    }

    // MARK: - Large-box edge restriction

    /// Restrict the neighbour set of "large" non-text boxes (figures,
    /// panels, charts — anything that can hold ≥ 20 typical words) to
    /// caption-tier text only. Two large boxes never link to each other;
    /// a large box never links to a sentence or paragraph word.
    ///
    /// Definition of "large": `area > 20 × medianWordArea`. Median (not
    /// mean) so that a banner-text outlier in the Vision output doesn't
    /// shift the threshold.
    ///
    /// Runs as a post-process pass after `connectCaptions` so caption
    /// edges added there (which already passed the 1/8 proximity gate)
    /// survive, while the per-sea pairwise's "everything in the same sea
    /// can connect" promiscuity is reined in.
    private func pruneLargeBoxConnections(tags: [Box: BoxKind],
                                          lineToParagraph: [Int: Int],
                                          paragraphSize: [Int: Int],
                                          medianWordArea: Double,
                                          network: inout [Box: [Box]]) {
        let captionMaxWords = 5
        let largeAreaThreshold = medianWordArea * 20.0

        var largeBoxes: Set<Box> = []
        for (box, kind) in tags {
            guard case .nonText = kind else { continue }
            if Double(box.area) > largeAreaThreshold {
                largeBoxes.insert(box)
            }
        }
        if largeBoxes.isEmpty { return }

        var toPrune: [(Box, Box)] = []
        for largeBox in largeBoxes {
            guard let neighbours = network[largeBox] else { continue }
            for n in neighbours {
                if largeBoxes.contains(n) {
                    toPrune.append((largeBox, n))
                    continue
                }
                if case let .word(_, _, lineID) = tags[n] {
                    let size = lineToParagraph[lineID]
                        .flatMap { paragraphSize[$0] } ?? 1
                    if size > captionMaxWords {
                        toPrune.append((largeBox, n))
                    }
                }
            }
        }

        for (a, b) in toPrune {
            network[a]?.removeAll { $0 == b }
            network[b]?.removeAll { $0 == a }
        }
    }

    // MARK: - Paragraph-aware pruning

    /// Two responsibilities:
    ///
    /// 1. **Tiered word ↔ non-text prune.** A `.word` is classified by
    ///    paragraph size and large `.nonText` neighbours are pruned
    ///    accordingly:
    ///      * **Paragraph** (> 20 words): prune `.nonText` neighbours
    ///        larger than `5 × median(word area)`.
    ///      * **Sentence** (10–20 words): prune `.nonText` neighbours
    ///        larger than `20 × median(word area)`.
    ///      * **Caption** (≤ 10 words): not subject to this rule.
    ///
    /// 2. **Cross-paragraph word ↔ word prune.** Any `.word` ↔ `.word`
    ///    edge spanning different Vision paragraphs is cut. The
    ///    aligned-series gate is geometry-only; paragraph identity is
    ///    the logical-grouping boundary those edges shouldn't cross.
    private func pruneParagraphAnchors(tags: [Box: BoxKind],
                                       lineToParagraph: [Int: Int],
                                       paragraphSize: [Int: Int],
                                       network: inout [Box: [Box]]) {
        let captionMaxWords = 10
        let sentenceMaxWords = 20
        let paragraphMultiplier: Double = 5.0
        let sentenceMultiplier: Double = 20.0

        var wordsByParagraph: [Int: [Box]] = [:]
        var paragraphOfBox: [Box: Int] = [:]
        for (box, kind) in tags {
            guard case let .word(_, _, lineID) = kind,
                  let para = lineToParagraph[lineID] else { continue }
            wordsByParagraph[para, default: []].append(box)
            paragraphOfBox[box] = para
        }

        var toPrune: [(Box, Box)] = []

        // (1) Tiered word ↔ non-text.
        for (paraIdx, paraBoxes) in wordsByParagraph {
            let size = paragraphSize[paraIdx] ?? paraBoxes.count
            let multiplier: Double
            if size > sentenceMaxWords      { multiplier = paragraphMultiplier }
            else if size > captionMaxWords  { multiplier = sentenceMultiplier }
            else                            { continue }
            let areas = paraBoxes.map { Double($0.area) }.sorted()
            let median = areas[areas.count / 2]
            guard median > 0 else { continue }
            let threshold = median * multiplier

            for word in paraBoxes {
                guard let neighbours = network[word] else { continue }
                for n in neighbours {
                    guard case .nonText = tags[n] else { continue }
                    if Double(n.area) > threshold {
                        toPrune.append((word, n))
                    }
                }
            }
        }

        // (2) Cross-paragraph word ↔ word.
        for (word, paraA) in paragraphOfBox {
            guard let neighbours = network[word] else { continue }
            for n in neighbours {
                guard let paraB = paragraphOfBox[n] else { continue }
                if paraA != paraB {
                    toPrune.append((word, n))
                }
            }
        }

        for (a, b) in toPrune {
            network[a]?.removeAll { $0 == b }
            network[b]?.removeAll { $0 == a }
        }
    }

    // MARK: - Heading / body directional asymmetry (phase 3)

    /// Suppress `body → heading` edges so cluster expansion from a heading
    /// pulls in its body, but never the reverse. A `.word` box is a
    /// "heading" when its height exceeds `1.5 ×` the median word height in
    /// the screenshot; everything else `.word` is "body".
    ///
    /// The asymmetry applies only to `.word → .word` edges. Word-to-anchor
    /// links (a heading-sized title above a chart, an axis label below a
    /// plot) remain bidirectional — the user typically wants the chart and
    /// its title to expand together regardless of which side they hover.
    ///
    /// We don't add new edges here: linking heading to body is handled by
    /// the per-sea pairwise / aligned-series passes when their gates
    /// admit. The asymmetry pass is purely subtractive on the existing
    /// graph, which keeps it a safe final-cleanup step.
    private func applyHeadingAsymmetry(tags: [Box: BoxKind],
                                       network: inout [Box: [Box]]) {
        var heights: [Int] = []
        for (box, kind) in tags {
            if case .word = kind { heights.append(box.height) }
        }
        if heights.count < 3 { return }   // not enough text to call a median
        heights.sort()
        let median = Double(heights[heights.count / 2])
        let headingThreshold = median * 1.5

        var headingBoxes = Set<Box>()
        for (box, kind) in tags {
            if case .word = kind, Double(box.height) > headingThreshold {
                headingBoxes.insert(box)
            }
        }
        if headingBoxes.isEmpty { return }

        // Drop heading neighbours from each body word's forward edge list.
        let keys = Array(network.keys)
        for box in keys {
            guard case .word = tags[box] else { continue }
            if headingBoxes.contains(box) { continue }
            network[box]?.removeAll { headingBoxes.contains($0) }
        }
    }

}
