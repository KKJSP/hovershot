import CoreGraphics
import Foundation
import Vision

/// Word-level OCR result for a single recognized word, in image-pixel
/// coordinates (top-left origin) to match the rest of the pipeline.
struct RecognizedWord {
    let text: String
    let confidence: Float
    let box: Box
    /// Index of the `VNRecognizedTextObservation` (line) this word came from.
    /// Words sharing a `lineID` are on the same line per Vision's grouping —
    /// used downstream for paragraph / aligned-row inference.
    let lineID: Int
}

/// Per-box semantic tag inferred from OCR. Attached to `Box`es as a side-map
/// keyed on the box itself; deliberately not folded into `Box` so equality /
/// hashing stay coordinate-only (the network graph relies on that).
enum BoxKind {
    case word(text: String, confidence: Float, lineID: Int)
    case nonText
}

/// Thin wrapper around `VNRecognizeTextRequest` at `.fast` recognition level.
/// Returns word-level boxes in image-pixel space.
///
/// Vision reports normalized rectangles with bottom-left origin and one line
/// per `VNRecognizedTextObservation`. We take the top candidate per line and
/// ask it for per-substring (word) rectangles via `boundingBox(for:)`. Each
/// such rectangle is a quad (`VNRectangleObservation` corners), which we
/// collapse to its axis-aligned bounding box — fine for axis-aligned screen
/// text, and a sensible approximation for the occasional slightly-skewed
/// line. `.fast` level + no language correction keeps latency low; we don't
/// need spelling-corrected strings, just bounds and rough text identity.
enum TextRecognition {
    static func recognizeWords(in cgImage: CGImage) -> [RecognizedWord] {
        let imageW = CGFloat(cgImage.width)
        let imageH = CGFloat(cgImage.height)

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            if Config.debug {
                NSLog("[HoverShot] OCR failed: %@", String(describing: error))
            }
            return []
        }

        guard let observations = request.results else { return [] }

        var words: [RecognizedWord] = []
        words.reserveCapacity(observations.count * 4)

        for (lineID, obs) in observations.enumerated() {
            guard let candidate = obs.topCandidates(1).first else { continue }
            let text = candidate.string

            // Walk whitespace-separated tokens and pull each one's rectangle
            // from Vision. We treat each whitespace-delimited token as a word
            // — punctuation stays attached, which matches how we want hover
            // selection to behave (clicking "Hello," picks up the whole
            // token, not "Hello" without the comma).
            var idx = text.startIndex
            while idx < text.endIndex {
                while idx < text.endIndex, text[idx].isWhitespace {
                    idx = text.index(after: idx)
                }
                guard idx < text.endIndex else { break }
                let start = idx
                while idx < text.endIndex, !text[idx].isWhitespace {
                    idx = text.index(after: idx)
                }
                let range = start..<idx
                let wordText = String(text[range])

                guard let rect = try? candidate.boundingBox(for: range) else {
                    continue
                }

                let xs = [rect.topLeft.x, rect.topRight.x,
                          rect.bottomLeft.x, rect.bottomRight.x]
                let ys = [rect.topLeft.y, rect.topRight.y,
                          rect.bottomLeft.y, rect.bottomRight.y]
                let xMinN = xs.min() ?? 0
                let xMaxN = xs.max() ?? 0
                let yMinN = ys.min() ?? 0
                let yMaxN = ys.max() ?? 0

                let pxLeft   = Int((xMinN * imageW).rounded())
                let pxRight  = Int((xMaxN * imageW).rounded())
                // Vision's y axis points up from the bottom; flip to top-down
                // pixel space.
                let pxTop    = Int(((1 - yMaxN) * imageH).rounded())
                let pxBottom = Int(((1 - yMinN) * imageH).rounded())

                let box = Box(
                    x: max(0, pxLeft),
                    y: max(0, pxTop),
                    width: max(1, pxRight - pxLeft),
                    height: max(1, pxBottom - pxTop)
                )
                words.append(RecognizedWord(
                    text: wordText,
                    confidence: candidate.confidence,
                    box: box,
                    lineID: lineID
                ))
            }
        }

        return words
    }

    /// Tag each `box` as `.word` if a recognized word's bounding box covers
    /// it (or it covers the word) by at least `coverageThreshold` of the
    /// smaller of the two areas, else `.nonText`. Coverage-of-smaller works
    /// across the three common cases — 1:1 word↔CC match, several CC letter
    /// blobs inside one Vision word, and a CC box that swallows a whole word
    /// — where plain IoU would underrate the nested cases.
    static func tagBoxes(_ boxes: [Box],
                         using words: [RecognizedWord],
                         coverageThreshold: Double = 0.5) -> [Box: BoxKind] {
        var tags: [Box: BoxKind] = [:]
        tags.reserveCapacity(boxes.count)
        for box in boxes {
            var best: RecognizedWord?
            var bestCoverage: Double = 0
            for word in words {
                let inter = box.overlap(word.box)
                guard inter > 0 else { continue }
                let minArea = Double(min(box.area, word.box.area))
                guard minArea > 0 else { continue }
                let coverage = inter / minArea
                if coverage > bestCoverage && coverage >= coverageThreshold {
                    bestCoverage = coverage
                    best = word
                }
            }
            if let w = best {
                tags[box] = .word(text: w.text,
                                  confidence: w.confidence,
                                  lineID: w.lineID)
            } else {
                tags[box] = .nonText
            }
        }
        return tags
    }
}
