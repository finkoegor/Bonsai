import Foundation

extension PixelBuffer {
    var bounds: PixelRect { PixelRect(x: 0, y: 0, width: width, height: height) }

    /// The pixels inside `rect`, which must lie within the image.
    func cropped(to rect: PixelRect) -> PixelBuffer {
        precondition(!rect.isEmpty && rect.intersection(bounds) == rect)
        if rect == bounds { return self }
        let rowLength = rect.width * channels
        var result = [UInt8](repeating: 0, count: rowLength * rect.height)
        bytes.withUnsafeBufferPointer { source in
            result.withUnsafeMutableBufferPointer { target in
                for row in 0..<rect.height {
                    let from = ((rect.y + row) * width + rect.x) * channels
                    target.baseAddress!.advanced(by: row * rowLength)
                        .update(from: source.baseAddress!.advanced(by: from), count: rowLength)
                }
            }
        }
        return PixelBuffer(width: rect.width, height: rect.height, channels: channels, bytes: result)
    }

    /// For an alpha channel: true when every pixel is fully opaque.
    var isOpaque: Bool {
        bytes.withUnsafeBufferPointer { buffer in
            buffer.allSatisfy { $0 == 255 }
        }
    }

    /// For an alpha channel: the smallest rectangle holding every pixel that
    /// is not fully transparent, nil when there is none.
    var boundsOfVisible: PixelRect? {
        precondition(channels == 1)
        return bytes.withUnsafeBufferPointer { buffer -> PixelRect? in
            func rowHasVisible(_ row: Int) -> Bool {
                let start = row * width
                for index in start..<(start + width) where buffer[index] != 0 { return true }
                return false
            }
            guard let top = (0..<height).first(where: rowHasVisible),
                  let bottom = (0..<height).last(where: rowHasVisible) else { return nil }
            var left = width, right = -1
            for row in top...bottom {
                let start = row * width
                var first = 0
                while first < left, buffer[start + first] == 0 { first += 1 }
                left = min(left, first)
                var last = width - 1
                while last > right, buffer[start + last] == 0 { last -= 1 }
                right = max(right, last)
            }
            return PixelRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
        }
    }
}
