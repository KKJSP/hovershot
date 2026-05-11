import Foundation

/// Faithful port of `Box` in Python's `boxfinder.py`. Coordinates are in image
/// (top-left origin) pixel space. Two `Box`es with identical coordinates are
/// considered equal — this is critical for using `Box` as a dictionary key in
/// the network graph, exactly as the Python code does.
struct Box: Hashable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    var left: Int   { x }
    var right: Int  { x + width }
    var top: Int    { y }
    var bottom: Int { y + height }
    var area: Int   { width * height }

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    func expand(_ amount: Int) -> Box {
        Box(x: x - amount, y: y - amount,
            width: width + 2 * amount, height: height + 2 * amount)
    }

    func scaled(_ amount: (Double, Double)) -> Box {
        Box(
            x: Int(Double(x) * amount.0),
            y: Int(Double(y) * amount.1),
            width: Int(Double(width) * amount.0),
            height: Int(Double(height) * amount.1)
        )
    }

    func contains(_ other: Box) -> Bool {
        left   <= other.left  &&
        right  >= other.right &&
        top    <= other.top   &&
        bottom >= other.bottom
    }

    func overlaps(_ other: Box) -> Bool {
        !(right < other.left || left > other.right ||
          bottom < other.top || top  > other.bottom)
    }

    func overlap(_ other: Box) -> Double {
        guard overlaps(other) else { return 0 }
        let xo = max(0, min(right, other.right)   - max(left, other.left))
        let yo = max(0, min(bottom, other.bottom) - max(top,  other.top))
        return Double(xo * yo)
    }

    /// Closest distance between the boxes' edges. 0 if they touch or overlap.
    func edgeDistance(_ other: Box) -> Double {
        let dx = max(0, max(left - other.right, other.left - right))
        let dy = max(0, max(top  - other.bottom, other.top - bottom))
        return (Double(dx) * Double(dx) + Double(dy) * Double(dy)).squareRoot()
    }

    /// Shadow-overlap measure used to decide if two boxes share a row or column.
    func alignment(_ other: Box, margin: Double) -> Double {
        let widthOverlap  = Double(max(0, min(right,  other.right)  - max(left, other.left)))
        let heightOverlap = Double(max(0, min(bottom, other.bottom) - max(top,  other.top)))

        let widthOverlapFraction  = min((widthOverlap  + margin) / Double(other.width),  1)
        let heightOverlapFraction = min((heightOverlap + margin) / Double(other.height), 1)

        let heightFactor = min((Double(height) + margin) / Double(other.height), 1)
        let widthFactor  = min((Double(width)  + margin) / Double(other.width),  1)

        let widthAlignment  = widthOverlapFraction  * heightFactor
        let heightAlignment = heightOverlapFraction * widthFactor

        return max(widthAlignment, heightAlignment)
    }

    /// Probability in `[0, 1]` that two boxes belong to the same cluster.
    /// Adapted from the Python `connection_probability` with an added size
    /// penalty: when both boxes are physically large (e.g. notebook cells, an
    /// embedded image and its container) a 5px gap shouldn't be enough to
    /// glue them together, even though the relative gap is tiny. Small boxes
    /// (text, icons) are unaffected and continue to cluster eagerly.
    func connectionProbability(_ other: Box, mergeDistance: Double) -> Double {
        // Never connect a box to one that completely engulfs it. Partial overlaps
        // are still considered through the rest of the formula.
        if contains(other) || other.contains(self) { return 0 }

        let edge = edgeDistance(other)
        let distanceScore = min(1, max(0, (mergeDistance * 3 - edge) / mergeDistance / 2))

        let areaRatio = min(Double(area) * 5 / Double(other.area), 1)
        let proximity = min(1, mergeDistance / max(1, edge) / 2)
        let adjustedProximity = proximity * areaRatio
        let align = alignment(other, margin: mergeDistance)
        let alignmentScore = adjustedProximity + (1 - adjustedProximity) * align

        // Size penalty. Keyed off the *smaller* box's shorter dimension so the
        // damping only fires when both boxes are large — a small element next
        // to a large one (icon next to a panel) keeps a penalty of 1 and
        // clusters normally.
        let smallerMinDim = Double(min(min(width, height), min(other.width, other.height)))
        let sizeBudget = mergeDistance * 8
        let s = min(1.0, sizeBudget / max(1.0, smallerMinDim))
        let sizePenalty = s * s

        return distanceScore * alignmentScore * sizePenalty
    }
}
