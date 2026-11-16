import Foundation

/// Compares the luma of two images in 8 by 8 windows. The windows sit 4
/// pixels off the JPEG block grid, so each one straddles block borders and
/// sees blocking, and each one is scored on its own, so damage confined to
/// small text or a logo is not averaged away by large smooth areas.
///
/// With an alpha channel, both images are compared the way they show: each
/// pixel is scaled by its opacity, which is what reaches the screen over any
/// backdrop. Errors in faint shadows count for as little as they are seen.
struct StructuralSimilarity {
    /// SSIM averaged over the windows. 1 means identical.
    let mean: Double
    /// The 1st percentile of window SSIM: how the worst part of the image
    /// fares. Crumbling text and ringing around edges pull it down first.
    let worst: Double
    /// The 99th percentile of the change in brightness of smooth windows, in
    /// levels. SSIM barely notices a flat window that turned a level lighter,
    /// yet a gradient made of such windows shows visible steps.
    let brightnessShift: Double

    /// Windows less visible than this, as average opacity out of 255, are
    /// not scored.
    private static let leastScoredOpacity = 16

    /// `alpha`, when given, has the size of the images.
    init(_ reference: PixelBuffer, _ candidate: PixelBuffer, alpha: PixelBuffer? = nil) {
        guard reference.width == candidate.width, reference.height == candidate.height,
              reference.channels == candidate.channels else {
            mean = 0
            worst = 0
            brightnessShift = .infinity
            return
        }
        let width = reference.width, channels = reference.channels
        let offset = 4
        let windowsX = (reference.width - offset) / 8, windowsY = (reference.height - offset) / 8
        let opacity = alpha.flatMap { $0.channels == 1 && $0.hasSize(of: reference) ? $0.bytes : nil }
        let c1 = pow(0.01 * 255, 2.0), c2 = pow(0.03 * 255, 2.0)

        var scores: [Double] = []
        scores.reserveCapacity(max(0, windowsX * windowsY))
        var shifts = [Int](repeating: 0, count: 256)
        var smoothWindows = 0
        if windowsX > 0, windowsY > 0 {
            reference.bytes.withUnsafeBufferPointer { a in
                candidate.bytes.withUnsafeBufferPointer { b in
                    func luma(_ buffer: UnsafeBufferPointer<UInt8>, _ pixel: Int) -> Double {
                        let index = pixel * channels
                        if channels == 1 { return Double(buffer[index]) }
                        return 0.299 * Double(buffer[index]) + 0.587 * Double(buffer[index + 1])
                            + 0.114 * Double(buffer[index + 2])
                    }
                    for windowY in 0..<windowsY {
                        for windowX in 0..<windowsX {
                            let top = offset + windowY * 8, left = offset + windowX * 8
                            var sumA = 0.0, sumB = 0.0, sumAA = 0.0, sumBB = 0.0, sumAB = 0.0
                            var visibility = 0
                            for y in top..<(top + 8) {
                                for x in left..<(left + 8) {
                                    let pixel = y * width + x
                                    let shown = opacity.map { Int($0[pixel]) } ?? 255
                                    visibility += shown
                                    let weight = Double(shown) / 255
                                    let va = luma(a, pixel) * weight, vb = luma(b, pixel) * weight
                                    sumA += va
                                    sumB += vb
                                    sumAA += va * va
                                    sumBB += vb * vb
                                    sumAB += va * vb
                                }
                            }
                            guard visibility >= Self.leastScoredOpacity * 64 else { continue }
                            let meanA = sumA / 64, meanB = sumB / 64
                            let varianceA = sumAA / 64 - meanA * meanA
                            let varianceB = sumBB / 64 - meanB * meanB
                            let covariance = sumAB / 64 - meanA * meanB
                            scores.append(((2 * meanA * meanB + c1) * (2 * covariance + c2))
                                / ((meanA * meanA + meanB * meanB + c1) * (varianceA + varianceB + c2)))
                            if varianceA < 4 {
                                shifts[min(255, Int((abs(meanA - meanB) * 4).rounded()))] += 1
                                smoothWindows += 1
                            }
                        }
                    }
                }
            }
        }

        guard !scores.isEmpty else {
            mean = 1
            worst = 1
            brightnessShift = 0
            return
        }
        mean = scores.reduce(0, +) / Double(scores.count)
        scores.sort()
        worst = scores[min(scores.count - 1, scores.count / 100)]

        var shift = 0
        if smoothWindows > 0 {
            var remaining = Int((Double(smoothWindows) * 0.01).rounded(.up))
            for bucket in stride(from: 255, through: 0, by: -1) {
                remaining -= shifts[bucket]
                if remaining <= 0 {
                    shift = bucket
                    break
                }
            }
        }
        brightnessShift = Double(shift) / 4
    }
}
