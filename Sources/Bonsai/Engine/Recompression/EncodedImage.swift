import Foundation

/// New contents for an image stream.
enum EncodedImage: Sendable {
    case jpeg(Data)
    /// A JPEG inside a Flate layer. Images with large flat areas, such as
    /// blurred backdrops, repeat the same few bits block after block, and
    /// Flate folds those runs.
    case deflatedJPEG(Data)
    /// Flate with PNG predictors over `colors` bytes per pixel.
    case flate(Data, colors: Int)

    /// A Flate layer must save at least this share to be worth the extra
    /// decoding step.
    private static let leastDeflateGain = 0.03

    /// Wraps a JPEG in Flate when that makes it smaller.
    static func packing(jpeg: Data) -> EncodedImage {
        if let deflated = Flate.compress(jpeg, level: 6),
           Double(deflated.count) <= Double(jpeg.count) * (1 - leastDeflateGain) {
            return .deflatedJPEG(deflated)
        }
        return .jpeg(jpeg)
    }

    var data: Data {
        switch self {
        case .jpeg(let data), .deflatedJPEG(let data), .flate(let data, _): data
        }
    }

    var byteCount: Int { data.count }
}
