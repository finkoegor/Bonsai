import Foundation

/// Finds the lowest JPEG quality, in steps of 5, whose result an acceptance
/// test approves. Smooth gradients pass at low qualities, detailed photos and
/// grain need higher ones, so every image gets only the bytes it needs.
/// Qualities are tried from the bottom up: trellis quantization makes
/// similarity jump around between neighbouring qualities, which would mislead
/// a bisection.
struct QualitySearch {
    let codec: JPEGCodec

    func lowestAccepted(_ image: PixelBuffer, qualities: ClosedRange<Int>, chroma: ChromaSubsampling,
                        limit: Int = .max, accept: (PixelBuffer) -> Bool) -> Data? {
        for quality in stride(from: qualities.lowerBound, through: qualities.upperBound, by: 5) {
            guard let jpeg = codec.encode(image, quality: quality, chroma: chroma) else { return nil }
            if jpeg.count >= limit { return nil }
            if let decoded = codec.decode(jpeg), decoded.width == image.width,
               decoded.height == image.height, decoded.channels == image.channels, accept(decoded) {
                return jpeg
            }
        }
        return nil
    }
}
