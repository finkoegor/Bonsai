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
            "Images keep enough detail to zoom in on a 5K display. Text, vectors and effects stay untouched."
        case .recommended:
            "Images stay sharp on Retina displays, even zoomed in. Text, vectors and effects stay untouched."
        case .extreme:
            "Images are sized for full screen viewing and may soften when zoomed. Text and vectors stay sharp."
        }
    }

    var profile: EncodingProfile {
        switch self {
        case .low:
            EncodingProfile(targetDensity: 600, similarity: 0.99, brightnessTolerance: 1,
                            photoQualities: 50...95, losslessQualities: 70...95,
                            maskQuality: 95, maskTolerance: 4)
        case .recommended:
            EncodingProfile(targetDensity: 300, similarity: 0.95, brightnessTolerance: 1.5,
                            photoQualities: 40...90, losslessQualities: 65...90,
                            maskQuality: 85, maskTolerance: 8)
        case .extreme:
            EncodingProfile(targetDensity: 150, similarity: 0.93, brightnessTolerance: 2,
                            photoQualities: 30...85, losslessQualities: 55...85,
                            maskQuality: 75, maskTolerance: 10)
        }
    }
}
