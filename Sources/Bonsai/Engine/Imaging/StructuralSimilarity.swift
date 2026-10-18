import Foundation

/// Compares the luma of two images block by block (8 by 8 pixels).
struct StructuralSimilarity {
    /// SSIM averaged over blocks. 1 means identical; it falls when edges
    /// blur, texture or grain disappears or blocks appear.
    let mean: Double
    /// The 99th percentile of the change in brightness of smooth blocks, in
    /// levels. SSIM barely notices a flat block that turned a level lighter,
    /// yet a gradient made of such blocks shows visible steps. Textured
    /// blocks hide such shifts and are left out.
    let brightnessShift: Double

    init(_ reference: PixelBuffer, _ candidate: PixelBuffer) {
        guard reference.width == candidate.width, reference.height == candidate.height,
              reference.channels == candidate.channels else {
            mean = 0
            brightnessShift = .infinity
            return
        }
        let width = reference.width, channels = reference.channels
        let blocksX = reference.width / 8, blocksY = reference.height / 8
        guard blocksX > 0, blocksY > 0 else {
            mean = 1
            brightnessShift = 0
            return
        }
        let c1 = pow(0.01 * 255, 2.0), c2 = pow(0.03 * 255, 2.0)

        var total = 0.0
        var shifts = [Int](repeating: 0, count: 256)
        var smoothBlocks = 0
        reference.bytes.withUnsafeBufferPointer { a in
            candidate.bytes.withUnsafeBufferPointer { b in
                func luma(_ buffer: UnsafeBufferPointer<UInt8>, _ pixel: Int) -> Double {
                    let index = pixel * channels
                    if channels == 1 { return Double(buffer[index]) }
                    return 0.299 * Double(buffer[index]) + 0.587 * Double(buffer[index + 1])
                        + 0.114 * Double(buffer[index + 2])
                }
                for blockY in 0..<blocksY {
                    for blockX in 0..<blocksX {
                        var sumA = 0.0, sumB = 0.0, sumAA = 0.0, sumBB = 0.0, sumAB = 0.0
                        for y in (blockY * 8)..<(blockY * 8 + 8) {
                            for x in (blockX * 8)..<(blockX * 8 + 8) {
                                let pixel = y * width + x
                                let va = luma(a, pixel), vb = luma(b, pixel)
                                sumA += va
                                sumB += vb
                                sumAA += va * va
                                sumBB += vb * vb
                                sumAB += va * vb
                            }
                        }
                        let meanA = sumA / 64, meanB = sumB / 64
                        let varianceA = sumAA / 64 - meanA * meanA
                        let varianceB = sumBB / 64 - meanB * meanB
                        let covariance = sumAB / 64 - meanA * meanB
                        total += ((2 * meanA * meanB + c1) * (2 * covariance + c2))
                            / ((meanA * meanA + meanB * meanB + c1) * (varianceA + varianceB + c2))
                        if varianceA < 4 {
                            shifts[min(255, Int((abs(meanA - meanB) * 4).rounded()))] += 1
                            smoothBlocks += 1
                        }
                    }
                }
            }
        }
        let blocks = blocksX * blocksY
        mean = total / Double(blocks)

        var shift = 0
        if smoothBlocks > 0 {
            var remaining = Int((Double(smoothBlocks) * 0.01).rounded(.up))
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
