import Foundation

/// Binary PGM and PPM, the formats cjpeg reads and djpeg writes.
enum PNM {
    static func encode(_ image: PixelBuffer) -> Data {
        let magic = image.channels == 1 ? "P5" : "P6"
        var data = Data("\(magic)\n\(image.width) \(image.height)\n255\n".utf8)
        data.append(contentsOf: image.bytes)
        return data
    }

    static func decode(_ data: Data) -> PixelBuffer? {
        let header = [UInt8](data.prefix(256))
        var index = 0
        var fields: [String] = []
        while fields.count < 4, index < header.count {
            let byte = header[index]
            if byte == UInt8(ascii: "#") {
                while index < header.count, header[index] != 0x0A { index += 1 }
            } else if isWhitespace(byte) {
                index += 1
            } else {
                let start = index
                while index < header.count, !isWhitespace(header[index]) { index += 1 }
                fields.append(String(decoding: header[start..<index], as: UTF8.self))
            }
        }
        index += 1
        guard fields.count == 4, fields[3] == "255",
              let width = Int(fields[1]), let height = Int(fields[2]) else { return nil }
        let channels: Int
        switch fields[0] {
        case "P5": channels = 1
        case "P6": channels = 3
        default: return nil
        }
        let start = data.startIndex + index
        let count = width * height * channels
        guard start + count <= data.endIndex else { return nil }
        return PixelBuffer(width: width, height: height, channels: channels,
                           bytes: [UInt8](data[start..<(start + count)]))
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
    }
}
