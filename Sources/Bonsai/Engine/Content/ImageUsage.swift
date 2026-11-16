import CoreGraphics
import Foundation

/// How each image is used, gathered from every place that paints it.
struct ImageUsage: Sendable {
    /// Per image, the lowest pixel density, in pixels per inch, it is drawn
    /// at on pages of each format.
    var placements: [Int: [PageFormat: Double]] = [:]
    /// Per image, the part that can show anywhere it is drawn: a rectangle in
    /// the unit square images are painted into, origin at the bottom left.
    /// Null when no part of the image ever shows.
    var visibleRegions: [Int: CGRect] = [:]
    /// Images painted as XObjects, as opposed to serving only as masks.
    var painted: Set<Int> = []
    /// Images painted while an ExtGState soft mask was in force. A soft mask
    /// of their own replaces that one, so it cannot be taken away.
    var paintedUnderSoftMask: Set<Int> = []
    /// Images painted under a soft mask of the graphics state, with a
    /// constant alpha below 1 or with a blend mode other than Normal.
    var paintedWithTransparency: Set<Int> = []
    /// Images that can also be painted from places the scan does not follow,
    /// such as patterns, Type 3 glyphs or annotation appearances.
    var unaccounted: Set<Int> = []
    /// False when some content could not be read; no image may then change shape.
    var isComplete = true
    /// True when the document has knockout groups, where even a transparent
    /// part of an image erases what was painted before it.
    var hasKnockoutGroups = false

    /// True when every place an image is painted has been seen.
    func covers(_ image: Int) -> Bool {
        isComplete && !unaccounted.contains(image)
    }

    func placements(of image: Int) -> [PageFormat: Double]? {
        guard covers(image), let known = placements[image], !known.isEmpty else { return nil }
        return known
    }

    func visibleRegion(of image: Int) -> CGRect? {
        guard covers(image) else { return nil }
        return visibleRegions[image]
    }

    /// Folds the usage of duplicate images into the copy that stays.
    /// `duplicates` maps each copy to that object.
    func merging(_ duplicates: [Int: Int]) -> ImageUsage {
        var merged = self
        for (copy, keeper) in duplicates {
            for (format, density) in placements[copy] ?? [:] {
                let known = merged.placements[keeper]?[format] ?? .infinity
                merged.placements[keeper, default: [:]][format] = min(known, density)
            }
            if let region = visibleRegions[copy] {
                merged.visibleRegions[keeper] = (merged.visibleRegions[keeper] ?? .null).union(region)
            }
            if painted.contains(copy) { merged.painted.insert(keeper) }
            if paintedUnderSoftMask.contains(copy) { merged.paintedUnderSoftMask.insert(keeper) }
            if paintedWithTransparency.contains(copy) { merged.paintedWithTransparency.insert(keeper) }
            if unaccounted.contains(copy) { merged.unaccounted.insert(keeper) }
        }
        return merged
    }
}
