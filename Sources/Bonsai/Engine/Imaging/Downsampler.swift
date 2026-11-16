import Foundation

/// Downsamples with a Catmull-Rom filter stretched over the source pixels
/// each new pixel covers. Plain averaging blurs fine detail more than a
/// reader showing the original at the same size would; this filter keeps
/// that detail and rings only faintly at hard edges.
enum Downsampler {
    static func downsample(_ image: PixelBuffer, width: Int, height: Int) -> PixelBuffer {
        resample(image, alpha: nil, width: width, height: height)
    }

    /// Downsamples color that is shown through `alpha` (same dimensions).
    /// Colors are weighted by their opacity, so pixels hidden by the mask do
    /// not bleed dark or stray colors into visible edges.
    static func downsample(_ image: PixelBuffer, shownThrough alpha: PixelBuffer,
                           width: Int, height: Int) -> PixelBuffer {
        precondition(alpha.channels == 1 && alpha.hasSize(of: image))
        return resample(image, alpha: alpha, width: width, height: height)
    }

    /// The source pixels one destination pixel draws on, and their weights,
    /// which add up to 1.
    private struct Taps {
        let first: Int
        let weights: [Float]
    }

    private static func taps(source: Int, destination: Int) -> [Taps] {
        let ratio = Double(source) / Double(destination)
        let reach = 2 * ratio
        return (0..<destination).map { index in
            let center = (Double(index) + 0.5) * ratio
            let first = max(0, Int((center - reach).rounded(.down)))
            let last = min(source - 1, Int((center + reach).rounded(.up)) - 1)
            var weights = (first...max(first, last)).map { pixel in
                kernel((Double(pixel) + 0.5 - center) / ratio)
            }
            let total = weights.reduce(0, +)
            if abs(total) > 1e-9 {
                for position in weights.indices { weights[position] /= total }
            }
            return Taps(first: first, weights: weights.map { Float($0) })
        }
    }

    /// Catmull-Rom: passes through the samples it interpolates, with one
    /// shallow negative lobe on each side.
    private static func kernel(_ offset: Double) -> Double {
        let distance = abs(offset)
        if distance < 1 { return (1.5 * distance - 2.5) * distance * distance + 1 }
        if distance < 2 { return ((-0.5 * distance + 2.5) * distance - 4) * distance + 2 }
        return 0
    }

    private static func resample(_ image: PixelBuffer, alpha: PixelBuffer?, width: Int, height: Int) -> PixelBuffer {
        precondition(width <= image.width && height <= image.height && width > 0 && height > 0)
        let channels = image.channels
        let columns = taps(source: image.width, destination: width)
        let rows = taps(source: image.height, destination: height)

        // Per destination column: color sums, then with an alpha channel
        // also opacity-weighted color sums and the opacity itself.
        let stride = alpha == nil ? channels : channels * 2 + 1
        let rowLength = width * stride
        // Source rows resampled horizontally, kept while destination rows
        // still draw on them.
        let slots = (rows.map(\.weights.count).max() ?? 1) + 1
        let cache = UnsafeMutablePointer<Float>.allocate(capacity: slots * rowLength)
        let accumulator = UnsafeMutablePointer<Float>.allocate(capacity: rowLength)
        defer {
            cache.deallocate()
            accumulator.deallocate()
        }
        var cachedRows = [Int](repeating: -1, count: slots)
        var output = [UInt8](repeating: 0, count: width * height * channels)

        image.bytes.withUnsafeBufferPointer { source in
            withOptionalPointer(alpha?.bytes) { opacities in
                output.withUnsafeMutableBufferPointer { target in
                    for (y, rowTaps) in rows.enumerated() {
                        accumulator.update(repeating: 0, count: rowLength)
                        for (offset, weight) in rowTaps.weights.enumerated() {
                            let sourceRow = rowTaps.first + offset
                            let slot = sourceRow % slots
                            let line = cache.advanced(by: slot * rowLength)
                            if cachedRows[slot] != sourceRow {
                                resampleRow(sourceRow, source: source.baseAddress!, opacities: opacities,
                                            imageWidth: image.width, channels: channels, columns: columns,
                                            stride: stride, into: line)
                                cachedRows[slot] = sourceRow
                            }
                            for index in 0..<rowLength { accumulator[index] += line[index] * weight }
                        }
                        for x in 0..<width {
                            let base = x * stride
                            let opacity = opacities == nil ? 0 : accumulator[base + channels * 2]
                            for channel in 0..<channels {
                                let value = opacity > 1
                                    ? accumulator[base + channels + channel] / opacity
                                    : accumulator[base + channel]
                                target[(y * width + x) * channels + channel] = UInt8(max(0, min(255, value.rounded())))
                            }
                        }
                    }
                }
            }
        }
        return PixelBuffer(width: width, height: height, channels: channels, bytes: output)
    }

    private static func resampleRow(_ row: Int, source: UnsafePointer<UInt8>, opacities: UnsafePointer<UInt8>?,
                                    imageWidth: Int, channels: Int, columns: [Taps], stride: Int,
                                    into line: UnsafeMutablePointer<Float>) {
        let rowStart = row * imageWidth
        line.update(repeating: 0, count: columns.count * stride)
        for (x, taps) in columns.enumerated() {
            let base = x * stride
            for (offset, weight) in taps.weights.enumerated() {
                let pixel = rowStart + taps.first + offset
                if let opacities {
                    let opacity = Float(opacities[pixel]) * weight
                    for channel in 0..<channels {
                        let value = Float(source[pixel * channels + channel])
                        line[base + channel] += value * weight
                        line[base + channels + channel] += value * opacity
                    }
                    line[base + channels * 2] += opacity
                } else {
                    for channel in 0..<channels {
                        line[base + channel] += Float(source[pixel * channels + channel]) * weight
                    }
                }
            }
        }
    }

    private static func withOptionalPointer<Result>(_ bytes: [UInt8]?,
                                                    _ body: (UnsafePointer<UInt8>?) -> Result) -> Result {
        guard let bytes else { return body(nil) }
        return bytes.withUnsafeBufferPointer { body($0.baseAddress) }
    }
}
