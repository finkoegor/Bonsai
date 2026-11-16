import Foundation
import zlib

/// zlib streams as the FlateDecode filter expects them.
enum Flate {
    /// `level` is zlib's 1 to 9. Text compresses best at 9; rows of
    /// filtered pixels gain next to nothing past 7 and take longer.
    static func compress(_ data: Data, level: Int32 = 9) -> Data? {
        guard data.count < Int(UInt32.max) else { return nil }
        var stream = z_stream()
        guard deflateInit2_(&stream, level, Z_DEFLATED, 15, 9, Z_DEFAULT_STRATEGY, ZLIB_VERSION,
                            Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { deflateEnd(&stream) }
        var output = Data(count: Int(deflateBound(&stream, uLong(data.count))))
        let status: Int32 = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { buffer in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(buffer.count)
                return deflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else { return nil }
        output.count = Int(stream.total_out)
        return output
    }

    static func decompress(_ stream: Data) -> Data? {
        let bytes = [UInt8](stream.prefix(2))
        guard stream.count > 6, bytes.count == 2, bytes[0] & 0x0F == 8,
              (Int(bytes[0]) << 8 | Int(bytes[1])) % 31 == 0, bytes[1] & 0x20 == 0 else { return nil }
        let body = stream.subdata(in: (stream.startIndex + 2)..<(stream.endIndex - 4))
        return try? (body as NSData).decompressed(using: .zlib) as Data
    }

    /// Compresses 8-bit pixels with PNG row predictors, choosing the filter
    /// for each row like libpng does. The result needs
    /// `/DecodeParms << /Predictor 15 /Colors n /BitsPerComponent 8 /Columns w >>`.
    static func compressPredicted(_ image: PixelBuffer) -> Data? {
        let rowLength = image.width * image.channels
        let bpp = image.channels
        var filtered = [UInt8](repeating: 0, count: (rowLength + 1) * image.height)
        var candidate = [UInt8](repeating: 0, count: rowLength)
        var best = [UInt8](repeating: 0, count: rowLength)

        image.bytes.withUnsafeBufferPointer { pixels in
            for y in 0..<image.height {
                let row = y * rowLength
                let above = row - rowLength
                var bestType: UInt8 = 0
                var bestCost = Int.max
                for type in UInt8(0)...4 {
                    var cost = 0
                    for i in 0..<rowLength {
                        let value = Int(pixels[row + i])
                        let left = i >= bpp ? Int(pixels[row + i - bpp]) : 0
                        let up = y > 0 ? Int(pixels[above + i]) : 0
                        let upLeft = (y > 0 && i >= bpp) ? Int(pixels[above + i - bpp]) : 0
                        let predictor: Int
                        switch type {
                        case 1: predictor = left
                        case 2: predictor = up
                        case 3: predictor = (left + up) / 2
                        case 4: predictor = paeth(left, up, upLeft)
                        default: predictor = 0
                        }
                        let residual = UInt8(truncatingIfNeeded: value - predictor)
                        candidate[i] = residual
                        cost += residual < 128 ? Int(residual) : 256 - Int(residual)
                    }
                    if cost < bestCost {
                        bestCost = cost
                        bestType = type
                        swap(&best, &candidate)
                    }
                }
                let target = y * (rowLength + 1)
                filtered[target] = bestType
                for i in 0..<rowLength { filtered[target + 1 + i] = best[i] }
            }
        }
        return compress(Data(filtered), level: 7)
    }

    private static func paeth(_ left: Int, _ up: Int, _ upLeft: Int) -> Int {
        let estimate = left + up - upLeft
        let toLeft = abs(estimate - left), toUp = abs(estimate - up), toUpLeft = abs(estimate - upLeft)
        if toLeft <= toUp && toLeft <= toUpLeft { return left }
        return toUp <= toUpLeft ? up : upLeft
    }
}
