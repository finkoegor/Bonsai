import CoreGraphics
import Foundation

enum Preset: String, CaseIterable, Identifiable, Codable {
    case low, recommended, extreme

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: "Low compression"
        case .recommended: "Recommended"
        case .extreme: "Extreme compression"
        }
    }

    /// The title in one word, for tight places.
    var shortTitle: String {
        switch self {
        case .low: "Low"
        case .recommended: "Recommended"
        case .extreme: "Extreme"
        }
    }

    var subtitle: String {
        switch self {
        case .low: "Highest quality, lighter file"
        case .recommended: "Great quality, great compression"
        case .extreme: "Smallest file, reduced quality"
        }
    }

    var icon: String {
        switch self {
        case .low: "gem"
        case .recommended: "balance-scale"
        case .extreme: "bolt"
        }
    }

    var summary: String {
        switch self {
        case .low:
            "Images keep enough detail to zoom in on a 5K display. Text, vectors and effects look exactly the same."
        case .recommended:
            "Images stay sharp with the page filling a Retina or 5K display. Text, vectors and effects look exactly the same."
        case .extreme:
            "Images are sized for an ordinary display and soften when zoomed. Text and vectors stay sharp."
        }
    }

    var profile: EncodingProfile {
        switch self {
        case .low:
            EncodingProfile(screen: CGSize(width: 7680, height: 4320), densities: 300...450, viewingDensity: 300,
                            similarity: 0.99, worstSimilarity: 0.92, brightnessTolerance: 1,
                            photoQualities: 50...95, losslessQualities: 70...95,
                            maskQuality: 95, maskTolerance: 4)
        case .recommended:
            EncodingProfile(screen: CGSize(width: 5120, height: 2880), densities: 150...200, viewingDensity: 150,
                            similarity: 0.95, worstSimilarity: 0.8, brightnessTolerance: 1.5,
                            photoQualities: 40...95, losslessQualities: 65...95,
                            maskQuality: 85, maskTolerance: 8)
        case .extreme:
            EncodingProfile(screen: CGSize(width: 2880, height: 1620), densities: 110...150, viewingDensity: 130,
                            similarity: 0.93, worstSimilarity: 0.65, brightnessTolerance: 2,
                            photoQualities: 30...95, losslessQualities: 55...95,
                            maskQuality: 75, maskTolerance: 10)
        }
    }
}
