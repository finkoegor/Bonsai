import Foundation

/// An image XObject as stored in the source file.
struct ImageSource: Sendable {
    enum ColorModel: Sendable {
        case gray
        case rgb
        /// Indexed, CMYK, Lab, Separation, DeviceN: kept lossless.
        case other
    }

    enum Storage: Sendable {
        /// A JPEG, optionally wrapped in a Flate layer in the file.
        case jpeg(JPEGHeader, wrappedInFlate: Bool)
        /// Raw samples, 8 bits per component, after general filters are removed.
        case samples(bytesPerPixel: Int, model: ColorModel)
    }

    let number: Int
    /// The dictionary as stored in the file, less a soft mask taken away.
    let dictionary: JSONObject
    let width: Int
    let height: Int
    /// Bytes the stream occupies in the file today.
    let encodedLength: Int
    /// The stream contents with general filters removed.
    let data: URL
    let storage: Storage
    let softMask: Int?
    /// True for soft masks with /Matte: their image is premultiplied, so
    /// neither may change shape or pick up lossy error.
    let hasMatte: Bool
    /// True when a /Decode array remaps the samples.
    let hasDecode: Bool

    /// True for a soft mask whose samples are opacity as stored: 0 hides a
    /// pixel, 255 shows it in full.
    var isPlainAlpha: Bool {
        channels == 1 && !hasMatte && !hasDecode
    }

    var channels: Int? {
        switch storage {
        case .jpeg(let header, _): header.components
        case .samples(let bytesPerPixel, let model): model == .other ? nil : bytesPerPixel
        }
    }

    /// The same image with its soft mask taken away.
    func withoutSoftMask() -> ImageSource {
        var stripped = dictionary
        stripped["/SMask"] = nil
        return ImageSource(number: number, dictionary: stripped, width: width, height: height,
                           encodedLength: encodedLength, data: data, storage: storage,
                           softMask: nil, hasMatte: hasMatte, hasDecode: hasDecode)
    }

    var isResampleable: Bool {
        guard !hasMatte else { return false }
        switch storage {
        case .jpeg(let header, _): return header.isReencodable
        case .samples(_, let model): return model != .other
        }
    }
}
