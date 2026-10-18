import Foundation

/// How far a preset may go with each kind of image. JPEG qualities use the
/// libjpeg 0 to 100 scale.
struct EncodingProfile: Sendable {
    /// Images denser than this, measured at the largest size they are drawn
    /// on any page, are downsampled to it.
    let targetDensity: Double
    /// The density the preset promises to look right at: full screen on a
    /// Retina display is about 130 to 190 pixels per inch of page.
    let viewingDensity: Double
    /// The lowest `StructuralSimilarity.mean` a re-encoded image may reach
    /// against its reference.
    let similarity: Double
    /// The lowest `StructuralSimilarity.worst` a re-encoded image may reach,
    /// so that text, logos and edges never crumble.
    let worstSimilarity: Double
    /// The largest `StructuralSimilarity.brightnessShift` a re-encoded image
    /// may show, in levels.
    let brightnessTolerance: Double
    /// Qualities searched for images that already were JPEG.
    let photoQualities: ClosedRange<Int>
    /// Qualities searched for losslessly stored images, which must also pass
    /// `FidelityCheck` to become JPEG. They keep full color resolution, since
    /// halved chroma fringes the edges such images tend to have.
    let losslessQualities: ClosedRange<Int>
    /// Soft masks (alpha channels).
    let maskQuality: Int
    /// The largest alpha error a JPEG mask may show at any pixel, out of 255.
    let maskTolerance: Int

    /// The thresholds hold for an image shown at its own resolution. An image
    /// drawn at a lower density than `viewingDensity` is magnified on screen
    /// by `magnification` and its artifacts with it, so the allowed loss
    /// shrinks in proportion.
    func accepts(_ comparison: StructuralSimilarity, magnification: Double) -> Bool {
        let factor = max(1, magnification)
        return comparison.mean >= 1 - (1 - similarity) / factor
            && comparison.worst >= 1 - (1 - worstSimilarity) / factor
            && comparison.brightnessShift <= brightnessTolerance / factor
    }

    /// Downsampling that keeps more than this share of the linear resolution
    /// is skipped: it would cost a resampling pass for little gain.
    static let largestWorthwhileScale = 0.9
}
