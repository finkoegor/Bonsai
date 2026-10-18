import Foundation

/// New contents for an image stream.
enum EncodedImage: Sendable {
    case jpeg(Data)
    /// Flate with PNG predictors over `colors` bytes per pixel.
    case flate(Data, colors: Int)

    var byteCount: Int {
        switch self {
        case .jpeg(let data), .flate(let data, _): data.count
        }
    }

    var data: Data {
        switch self {
        case .jpeg(let data), .flate(let data, _): data
        }
    }
}
