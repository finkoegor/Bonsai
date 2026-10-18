import Foundation

/// zlib streams as the FlateDecode filter expects them.
enum Flate {
    static func compress(_ data: Data) -> Data? {
        guard let deflated = try? (data as NSData).compressed(using: .zlib) as Data else { return nil }
        var stream = Data([0x78, 0x9C])
        stream.append(deflated)
        let checksum = adler32(data)
        stream.append(contentsOf: [UInt8(checksum >> 24), UInt8(checksum >> 16 & 0xFF),
                                   UInt8(checksum >> 8 & 0xFF), UInt8(checksum & 0xFF)])
        return stream
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
        return compress(Data(filtered))
    }

    private static func paeth(_ left: Int, _ up: Int, _ upLeft: Int) -> Int {
        let estimate = left + up - upLeft
        let toLeft = abs(estimate - left), toUp = abs(estimate - up), toUpLeft = abs(estimate - upLeft)
        if toLeft <= toUp && toLeft <= toUpLeft { return left }
        return toUp <= toUpLeft ? up : upLeft
    }

    private static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        data.withUnsafeBytes { buffer in
            var index = 0
            let bytes = buffer.bindMemory(to: UInt8.self)
            while index < bytes.count {
                let end = min(index + 5552, bytes.count)
                while index < end {
                    a &+= UInt32(bytes[index])
                    b &+= a
                    index += 1
                }
                a %= 65521
                b %= 65521
            }
        }
        return b << 16 | a
    }
}
