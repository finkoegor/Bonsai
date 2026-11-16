import Foundation

/// Replaces color that cannot be seen through the alpha channel with the
/// average of the visible color around it. Design tools leave noise there,
/// most of all in drop shadows, and an encoder spends bytes preserving it.
/// The fill is flat within each 8 by 8 block, the unit JPEG works in, and
/// takes the color of the nearest visible pixels, so edges do not pick up a
/// fringe when a reader scales the image.
enum HiddenColorFill {
    /// A pixel moves toward the average only if its opacity lets its color
    /// change by at least this many levels without showing.
    private static let leastUsefulRange = 8

    /// - Parameter tolerance: the largest change, in levels, that may show
    ///   on screen over any backdrop. With 0 only fully transparent pixels
    ///   change, and the picture stays exactly as it was.
    static func apply(to image: PixelBuffer, alpha: PixelBuffer, tolerance: Int) -> PixelBuffer {
        precondition(alpha.channels == 1 && alpha.hasSize(of: image))
        let width = image.width, height = image.height, channels = image.channels
        let columns = (width + 7) / 8, rows = (height + 7) / 8

        // Opacity-weighted color sums per block, then per 2 by 2 blocks, and
        // so on up to a single cell.
        var weights = [Float](repeating: 0, count: columns * rows)
        var sums = [Float](repeating: 0, count: columns * rows * channels)
        var hasHidden = false
        image.bytes.withUnsafeBufferPointer { pixels in
            alpha.bytes.withUnsafeBufferPointer { opacities in
                for y in 0..<height {
                    let blockRow = (y / 8) * columns
                    for x in 0..<width {
                        let opacity = opacities[y * width + x]
                        if opacity < 255 { hasHidden = true }
                        guard opacity > 0 else { continue }
                        let cell = blockRow + x / 8
                        let weight = Float(opacity)
                        weights[cell] += weight
                        let index = (y * width + x) * channels
                        for channel in 0..<channels {
                            sums[cell * channels + channel] += weight * Float(pixels[index + channel])
                        }
                    }
                }
            }
        }
        guard hasHidden else { return image }

        var levels = [(columns: columns, rows: rows, weights: weights, sums: sums)]
        while levels[levels.count - 1].columns > 1 || levels[levels.count - 1].rows > 1 {
            let below = levels[levels.count - 1]
            let halfColumns = (below.columns + 1) / 2, halfRows = (below.rows + 1) / 2
            var halfWeights = [Float](repeating: 0, count: halfColumns * halfRows)
            var halfSums = [Float](repeating: 0, count: halfColumns * halfRows * channels)
            for row in 0..<below.rows {
                for column in 0..<below.columns {
                    let from = row * below.columns + column
                    let to = (row / 2) * halfColumns + column / 2
                    halfWeights[to] += below.weights[from]
                    for channel in 0..<channels {
                        halfSums[to * channels + channel] += below.sums[from * channels + channel]
                    }
                }
            }
            levels.append((halfColumns, halfRows, halfWeights, halfSums))
        }
        guard levels[levels.count - 1].weights[0] > 0 else { return image }

        // Averages from the top down: a block with nothing visible takes the
        // average of the larger cell around it.
        var averages = [Float](repeating: 0, count: channels)
        for channel in 0..<channels {
            averages[channel] = levels[levels.count - 1].sums[channel] / levels[levels.count - 1].weights[0]
        }
        var parentColumns = 1
        for level in levels.dropLast().reversed() {
            var current = [Float](repeating: 0, count: level.columns * level.rows * channels)
            for row in 0..<level.rows {
                for column in 0..<level.columns {
                    let cell = row * level.columns + column
                    let parent = (row / 2) * parentColumns + column / 2
                    for channel in 0..<channels {
                        current[cell * channels + channel] = level.weights[cell] > 0
                            ? level.sums[cell * channels + channel] / level.weights[cell]
                            : averages[parent * channels + channel]
                    }
                }
            }
            averages = current
            parentColumns = level.columns
        }
        let targets = averages.map { UInt8(max(0, min(255, $0.rounded()))) }

        // Each pixel moves toward the average of its block as far as its
        // opacity lets it move unseen.
        var result = image
        result.bytes.withUnsafeMutableBufferPointer { pixels in
            alpha.bytes.withUnsafeBufferPointer { opacities in
                for y in 0..<height {
                    let blockRow = (y / 8) * columns
                    for x in 0..<width {
                        let opacity = Int(opacities[y * width + x])
                        let range = opacity == 0 ? 255 : tolerance * 255 / opacity
                        guard range >= leastUsefulRange else { continue }
                        let cell = (blockRow + x / 8) * channels
                        let index = (y * width + x) * channels
                        for channel in 0..<channels {
                            let value = Int(pixels[index + channel])
                            let step = Int(targets[cell + channel]) - value
                            pixels[index + channel] = UInt8(value + max(-range, min(range, step)))
                        }
                    }
                }
            }
        }
        return result
    }
}
