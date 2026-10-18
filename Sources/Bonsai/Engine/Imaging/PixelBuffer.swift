import Foundation

/// 8-bit pixels, channels interleaved, rows top to bottom.
struct PixelBuffer: Sendable {
    let width: Int
    let height: Int
    let channels: Int
    var bytes: [UInt8]

    init(width: Int, height: Int, channels: Int, bytes: [UInt8]) {
        precondition(bytes.count == width * height * channels)
        self.width = width
        self.height = height
        self.channels = channels
        self.bytes = bytes
    }

    init?(width: Int, height: Int, channels: Int, data: Data) {
        guard data.count == width * height * channels else { return nil }
        self.init(width: width, height: height, channels: channels, bytes: [UInt8](data))
    }

    func hasSize(of other: PixelBuffer) -> Bool {
        width == other.width && height == other.height
    }
}
