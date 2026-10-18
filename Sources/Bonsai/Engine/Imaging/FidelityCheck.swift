import Foundation

/// Decides whether a JPEG made from a losslessly stored image can stand in
/// for it. Two kinds of damage are measured on visible pixels, each weighted
/// by its opacity:
/// - outliers: the 99.9th percentile of the per-pixel error, which stays low
///   on photographs and climbs on line art and small text;
/// - ringing: errors next to areas that are perfectly flat in the reference,
///   the halo JPEG leaves around crisp shapes on solid fills.
/// Thresholds were calibrated on Keynote, PowerPoint, Canva and Quartz exports.
struct FidelityCheck {
    private static let largestOutlier = 40
    private static let largestRingingShare = 0.002

    private let reference: PixelBuffer
    private let opacity: [UInt8]?
    private let flat: [Bool]

    init(reference: PixelBuffer, alpha: PixelBuffer?) {
        self.reference = reference
        self.opacity = alpha.flatMap { $0.channels == 1 && $0.hasSize(of: reference) ? $0.bytes : nil }
        self.flat = Self.flatNeighbourhoods(reference)
    }

    func isIndistinguishable(from candidate: PixelBuffer) -> Bool {
        guard candidate.bytes.count == reference.bytes.count else { return false }
        let channels = reference.channels
        var histogram = [Int](repeating: 0, count: 256)
        var visible = 0
        var ringing = 0
        for pixel in 0..<(reference.width * reference.height) {
            let alpha = opacity.map { Int($0[pixel]) } ?? 255
            guard alpha >= 8 else { continue }
            var error = 0
            for channel in 0..<channels {
                let index = pixel * channels + channel
                error = max(error, abs(Int(reference.bytes[index]) - Int(candidate.bytes[index])))
            }
            let weighted = error * alpha / 255
            histogram[weighted] += 1
            visible += 1
            if flat[pixel], weighted > 6 { ringing += 1 }
        }
        guard visible > 0 else { return true }

        var remaining = Int((Double(visible) * 0.001).rounded(.up))
        var outlier = 255
        for value in stride(from: 255, through: 0, by: -1) {
            remaining -= histogram[value]
            if remaining <= 0 {
                outlier = value
                break
            }
        }
        return outlier <= Self.largestOutlier && Double(ringing) / Double(visible) <= Self.largestRingingShare
    }

    /// The largest difference of any channel at any pixel.
    static func largestDifference(_ reference: PixelBuffer, _ candidate: PixelBuffer) -> Int {
        guard reference.bytes.count == candidate.bytes.count else { return .max }
        var largest = 0
        reference.bytes.withUnsafeBufferPointer { a in
            candidate.bytes.withUnsafeBufferPointer { b in
                for index in 0..<a.count {
                    let difference = abs(Int(a[index]) - Int(b[index]))
                    if difference > largest { largest = difference }
                }
            }
        }
        return largest
    }

    /// Pixels whose 5 by 5 neighbourhood varies by at most 3 levels (channel sum).
    private static func flatNeighbourhoods(_ image: PixelBuffer) -> [Bool] {
        let width = image.width, height = image.height, channels = image.channels
        var sums = [Int16](repeating: 0, count: width * height)
        for pixel in 0..<(width * height) {
            var sum = 0
            for channel in 0..<channels { sum += Int(image.bytes[pixel * channels + channel]) }
            sums[pixel] = Int16(sum)
        }
        let low = window(window(sums, width: width, height: height, horizontal: true, pick: min),
                         width: width, height: height, horizontal: false, pick: min)
        let high = window(window(sums, width: width, height: height, horizontal: true, pick: max),
                          width: width, height: height, horizontal: false, pick: max)
        return (0..<(width * height)).map { high[$0] - low[$0] <= 3 }
    }

    /// One pass of a 5-tap minimum or maximum filter, clamped at the edges.
    private static func window(_ values: [Int16], width: Int, height: Int, horizontal: Bool,
                               pick: (Int16, Int16) -> Int16) -> [Int16] {
        var result = values
        for y in 0..<height {
            for x in 0..<width {
                var picked = values[y * width + x]
                for offset in -2...2 where offset != 0 {
                    let nx = horizontal ? min(max(x + offset, 0), width - 1) : x
                    let ny = horizontal ? y : min(max(y + offset, 0), height - 1)
                    picked = pick(picked, values[ny * width + nx])
                }
                result[y * width + x] = picked
            }
        }
        return result
    }
}
