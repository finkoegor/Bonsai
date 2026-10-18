import CoreGraphics
import PDFKit

/// Average colors of a page rendered by PDFKit, in a 5 by 5 grid of tiles.
struct PageSignature {
    private let means: [Double]

    init?(_ page: PDFPage, width: Int = 160, grid: Int = 5) {
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let height = max(grid, Int(CGFloat(width) * bounds.height / bounds.width))
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let rendered: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.setFillColor(.white)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: CGFloat(width) / bounds.width, y: CGFloat(height) / bounds.height)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            page.draw(with: .cropBox, to: context)
            return true
        }
        guard rendered else { return nil }

        var means: [Double] = []
        means.reserveCapacity(grid * grid * 3)
        for tileY in 0..<grid {
            for tileX in 0..<grid {
                let x0 = tileX * width / grid, x1 = max(x0 + 1, (tileX + 1) * width / grid)
                let y0 = tileY * height / grid, y1 = max(y0 + 1, (tileY + 1) * height / grid)
                var sums = [0.0, 0.0, 0.0]
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        let index = (y * width + x) * 4
                        for channel in 0..<3 { sums[channel] += Double(pixels[index + channel]) }
                    }
                }
                let count = Double((x1 - x0) * (y1 - y0))
                means.append(contentsOf: sums.map { $0 / count })
            }
        }
        self.means = means
    }

    /// The largest difference between corresponding tile averages.
    func distance(to other: PageSignature) -> Double {
        guard means.count == other.means.count else { return .infinity }
        return zip(means, other.means).map { abs($0 - $1) }.max() ?? 0
    }
}
