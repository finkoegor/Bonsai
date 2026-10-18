import Foundation

/// How densely each image is drawn, gathered from every place that paints it.
struct ImageUsage: Sendable {
    /// The lowest pixel density, in pixels per inch, at which an image object
    /// appears anywhere in the document.
    var minimumDensity: [Int: Double] = [:]
    /// Images that can also be painted from places the scan does not follow,
    /// such as patterns, Type 3 glyphs or annotation appearances.
    var unaccounted: Set<Int> = []
    /// False when some content could not be read; no image may then be resized.
    var isComplete = true

    /// The lowest density an image appears at, or nil when that is unknown.
    func density(of image: Int) -> Double? {
        guard isComplete, !unaccounted.contains(image) else { return nil }
        return minimumDensity[image]
    }
}
