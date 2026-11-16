import CoreGraphics
import Foundation

/// How far a preset may go with each kind of image. JPEG qualities use the
/// libjpeg 0 to 100 scale.
struct EncodingProfile: Sendable {
    /// The screen, in pixels, a page fitted to it must still look sharp on.
    /// Images keep the density that screen shows the page at: a wide slide
    /// needs fewer pixels per inch than a small sheet.
    let screen: CGSize
    /// Bounds for that density, in pixels per inch of page.
    let densities: ClosedRange<Double>
    /// The density pages are assumed to be looked at when artifacts are
    /// judged: full screen on a Retina display is about 130 to 190 pixels
    /// per inch of page.
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

    /// The density images are kept at on a page of the given format. Images
    /// drawn denser than this are downsampled to it.
    func density(on page: PageFormat) -> Double {
        let fitted = min(Double(screen.width) * 72 / max(page.width, 1),
                         Double(screen.height) * 72 / max(page.height, 1))
        return min(max(fitted, densities.lowerBound), densities.upperBound)
    }

    /// The thresholds hold for an image shown at its own resolution. An image
    /// drawn at a lower density than `viewingDensity` is magnified on screen
    /// by `magnification`. Its artifacts grow in both directions, so the
    /// allowed loss of structure shrinks with the square of the
    /// magnification, and the allowed brightness steps, which only get
    /// wider, with the magnification itself.
    func accepts(_ comparison: StructuralSimilarity, magnification: Double) -> Bool {
        let stretch = max(1, magnification)
        let factor = stretch * stretch
        return comparison.mean >= 1 - (1 - similarity) / factor
            && comparison.worst >= 1 - (1 - worstSimilarity) / factor
            && comparison.brightnessShift <= brightnessTolerance / stretch
    }

    /// Downsampling that keeps more than this share of the linear resolution
    /// is skipped: it would cost a resampling pass for little gain.
    static let largestWorthwhileScale = 0.9
}
