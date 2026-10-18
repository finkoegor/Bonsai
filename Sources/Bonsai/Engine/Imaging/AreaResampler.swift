import Foundation

/// Downsamples by exact area averaging: each source pixel contributes in
/// proportion to how much of it falls inside a destination pixel. There are
/// no negative filter lobes, so hard edges get no halos.
enum AreaResampler {
    static func downsample(_ image: PixelBuffer, width: Int, height: Int) -> PixelBuffer {
        resample(image, alpha: nil, width: width, height: height)
    }

    /// Downsamples color that is shown through `alpha` (same dimensions).
    /// Colors are averaged in proportion to their opacity, so pixels hidden
    /// by the mask do not bleed dark or stray colors into visible edges.
    static func downsample(_ image: PixelBuffer, shownThrough alpha: PixelBuffer,
                           width: Int, height: Int) -> PixelBuffer {
        precondition(alpha.channels == 1 && alpha.hasSize(of: image))
        return resample(image, alpha: alpha, width: width, height: height)
    }

    private struct Footprint {
        let first: Int
        let weights: [Float]
    }

    private static func footprints(source: Int, destination: Int) -> [Footprint] {
        let scale = Double(source) / Double(destination)
        return (0..<destination).map { index in
            let start = Double(index) * scale
            let end = min(Double(source), Double(index + 1) * scale)
            let first = Int(start.rounded(.down))
            let last = min(source - 1, Int((end - 1e-9).rounded(.down)))
            let weights = (first...max(first, last)).map { pixel in
                Float(min(Double(pixel + 1), end) - max(Double(pixel), start))
            }
            return Footprint(first: first, weights: weights)
        }
    }

    private static func resample(_ image: PixelBuffer, alpha: PixelBuffer?, width: Int, height: Int) -> PixelBuffer {
        precondition(width <= image.width && height <= image.height && width > 0 && height > 0)
        let channels = image.channels
        let columns = footprints(source: image.width, destination: width)
        let rows = footprints(source: image.height, destination: height)

        // Per destination column: plain color sums, opacity-weighted color
        // sums and opacity, in that order.
        let stride = alpha == nil ? channels : channels * 2 + 1
        var output = [UInt8](repeating: 0, count: width * height * channels)
        var accumulator = [Float](repeating: 0, count: width * stride)
        var rowBuffer = [Float](repeating: 0, count: width * stride)
        var cachedRow = -1

        image.bytes.withUnsafeBufferPointer { source in
            let alphaBytes = alpha?.bytes
            for (y, rowFootprint) in rows.enumerated() {
                for index in accumulator.indices { accumulator[index] = 0 }
                var rowWeight: Float = 0
                for (offset, weight) in rowFootprint.weights.enumerated() {
                    let sourceRow = rowFootprint.first + offset
                    if sourceRow != cachedRow {
                        resampleRow(sourceRow, source: source, alpha: alphaBytes, imageWidth: image.width,
                                    channels: channels, columns: columns, stride: stride, into: &rowBuffer)
                        cachedRow = sourceRow
                    }
                    for index in 0..<accumulator.count { accumulator[index] += rowBuffer[index] * weight }
                    rowWeight += weight
                }
                for x in 0..<width {
                    let base = x * stride
                    let columnWeight = columns[x].weights.reduce(0, +)
                    let area = max(rowWeight * columnWeight, 1e-6)
                    let opacity = alpha == nil ? 0 : accumulator[base + channels * 2]
                    for channel in 0..<channels {
                        let value: Float
                        if alpha != nil, opacity > 0.5 {
                            value = accumulator[base + channels + channel] / opacity
                        } else {
                            value = accumulator[base + channel] / area
                        }
                        output[(y * width + x) * channels + channel] = UInt8(max(0, min(255, value.rounded())))
                    }
                }
            }
        }
        return PixelBuffer(width: width, height: height, channels: channels, bytes: output)
    }

    private static func resampleRow(_ row: Int, source: UnsafeBufferPointer<UInt8>, alpha: [UInt8]?,
                                    imageWidth: Int, channels: Int, columns: [Footprint], stride: Int,
                                    into buffer: inout [Float]) {
        let rowStart = row * imageWidth
        for (x, footprint) in columns.enumerated() {
            let base = x * stride
            for index in base..<(base + stride) { buffer[index] = 0 }
            for (offset, weight) in footprint.weights.enumerated() {
                let pixel = rowStart + footprint.first + offset
                let opacity = alpha.map { Float($0[pixel]) * weight } ?? 0
                for channel in 0..<channels {
                    let value = Float(source[pixel * channels + channel])
                    buffer[base + channel] += value * weight
                    if alpha != nil { buffer[base + channels + channel] += value * opacity }
                }
                if alpha != nil { buffer[base + channels * 2] += opacity }
            }
        }
    }
}
