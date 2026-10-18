import Foundation

/// How far a preset may go with each kind of image. JPEG qualities use the
/// libjpeg 0 to 100 scale.
struct EncodingProfile: Sendable {
    /// Images denser than this, measured at the largest size they are drawn
    /// on any page, are downsampled to it.
    let targetDensity: Double
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

    func accepts(_ comparison: StructuralSimilarity) -> Bool {
        comparison.mean >= similarity && comparison.worst >= worstSimilarity
            && comparison.brightnessShift <= brightnessTolerance
    }

    /// Downsampling that keeps more than this share of the linear resolution
    /// is skipped: it would cost a resampling pass for little gain.
    static let largestWorthwhileScale = 0.9
}
