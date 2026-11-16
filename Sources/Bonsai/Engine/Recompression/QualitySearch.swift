import Foundation

/// Finds a low JPEG quality whose result an acceptance test approves. Smooth
/// gradients pass at low qualities, detailed photos and grain need higher
/// ones, so every image gets only the bytes it needs.
///
/// The search starts in the lower part of the range, walks in steps of 10
/// to where rejected qualities turn into accepted ones, and settles that
/// spot with one step of 5. It relies only on a higher quality being larger:
/// trellis quantization makes similarity jump between neighbouring
/// qualities, so the result may sit one step above the true minimum.
struct QualitySearch {
    let codec: JPEGCodec

    private enum Verdict {
        case accepted(EncodedImage)
        case rejected
        /// As large as `limit` or larger; higher qualities will be too.
        case tooLarge
    }

    /// `limit` is the size, in bytes as stored, the result must stay under.
    func lowestAccepted(_ image: PixelBuffer, qualities: ClosedRange<Int>, chroma: ChromaSubsampling,
                        limit: Int = .max, accept: (PixelBuffer) -> Bool) -> EncodedImage? {
        codec.withInput(image) { input in
            lowestAccepted(input, of: image, qualities: qualities, chroma: chroma, limit: limit, accept: accept)
        } ?? nil
    }

    private func lowestAccepted(_ input: JPEGCodec.Input, of image: PixelBuffer, qualities: ClosedRange<Int>,
                                chroma: ChromaSubsampling, limit: Int,
                                accept: (PixelBuffer) -> Bool) -> EncodedImage? {
        func verdict(at quality: Int) -> Verdict? {
            guard let jpeg = codec.encode(input, quality: quality, chroma: chroma) else { return nil }
            let encoded = EncodedImage.packing(jpeg: jpeg)
            if encoded.byteCount >= limit { return .tooLarge }
            guard let decoded = codec.decode(jpeg), decoded.hasSize(of: image),
                  decoded.channels == image.channels, accept(decoded) else { return .rejected }
            return .accepted(encoded)
        }

        let start = min(qualities.upperBound, qualities.lowerBound + 20)
        guard let first = verdict(at: start) else { return nil }
        var best: EncodedImage?
        /// The lowest quality not rejected so far and the highest rejected.
        var ceiling = start
        var floor = qualities.lowerBound - 1

        if case .rejected = first {
            floor = start
            ceiling = .max
            while floor < qualities.upperBound {
                let quality = min(qualities.upperBound, floor + 10)
                guard let next = verdict(at: quality) else { return nil }
                if case .rejected = next {
                    floor = quality
                    continue
                }
                if case .accepted(let encoded) = next { best = encoded }
                ceiling = quality
                break
            }
            guard ceiling != .max else { return nil }
        } else {
            if case .accepted(let encoded) = first { best = encoded }
            while ceiling - 10 >= qualities.lowerBound {
                guard let next = verdict(at: ceiling - 10) else { return best }
                if case .rejected = next {
                    floor = ceiling - 10
                    break
                }
                if case .accepted(let encoded) = next { best = encoded }
                ceiling -= 10
            }
        }

        if ceiling - 5 > floor, let between = verdict(at: ceiling - 5), case .accepted(let encoded) = between {
            best = encoded
        }
        return best
    }
}
