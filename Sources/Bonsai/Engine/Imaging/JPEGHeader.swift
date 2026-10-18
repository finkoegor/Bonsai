import Foundation

/// The frame header of a JPEG, read without decoding the image.
struct JPEGHeader: Sendable {
    let width: Int
    let height: Int
    let components: Int
    /// Baseline, extended or progressive Huffman coding with 8-bit samples
    /// and one or three components: the kinds every PDF reader decodes and
    /// mozjpeg can re-encode.
    let isReencodable: Bool
    /// Nil for grayscale or unusual layouts.
    let chroma: ChromaSubsampling?

    init?(_ data: Data) {
        guard let frame = Self.frame(in: [UInt8](data.prefix(1 << 20))) else { return nil }
        let segment = frame.segment
        let bytes = frame.bytes
        let precision = Int(bytes[segment])
        height = Int(bytes[segment + 1]) << 8 | Int(bytes[segment + 2])
        width = Int(bytes[segment + 3]) << 8 | Int(bytes[segment + 4])
        components = Int(bytes[segment + 5])
        isReencodable = precision == 8 && [0xC0, 0xC1, 0xC2].contains(frame.marker)
            && (components == 1 || components == 3)
        if components == 3 {
            let factors = (0..<3).map { bytes[segment + 6 + $0 * 3 + 1] }
            switch (factors[0], factors[1], factors[2]) {
            case (0x11, 0x11, 0x11): chroma = .full
            case (0x21, 0x11, 0x11): chroma = .half
            case (0x22, 0x11, 0x11): chroma = .quarter
            default: chroma = nil
            }
        } else {
            chroma = nil
        }
    }

    /// Locates the start-of-frame segment, stopping at the first scan.
    private static func frame(in bytes: [UInt8]) -> (marker: UInt8, segment: Int, bytes: [UInt8])? {
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var index = 2
        while index + 4 <= bytes.count {
            guard bytes[index] == 0xFF else { return nil }
            let marker = bytes[index + 1]
            if marker == 0xFF { index += 1; continue }
            if marker == 0x01 || (0xD0...0xD7).contains(marker) { index += 2; continue }
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            let segment = index + 4
            guard length >= 2, segment + length - 2 <= bytes.count else { return nil }
            let isFrame = (0xC0...0xCF).contains(marker) && ![0xC4, 0xC8, 0xCC].contains(marker)
            if isFrame {
                guard length >= 8, segment + 6 + Int(bytes[segment + 5]) * 3 <= bytes.count else { return nil }
                return (marker, segment, bytes)
            }
            if marker == 0xDA { return nil }
            index = segment + length - 2
        }
        return nil
    }
}
