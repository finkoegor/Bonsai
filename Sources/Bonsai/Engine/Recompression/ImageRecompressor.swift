import Foundation

/// Re-encodes the images of a document, each base image together with its
/// soft mask. A stream is replaced only when the result is smaller, or when
/// its group was downsampled and every member must follow.
struct ImageRecompressor: Sendable {
    let catalog: ImageCatalog
    let usage: ImageUsage
    let profile: EncodingProfile
    let codec: JPEGCodec
    /// Directory for the new stream contents.
    let output: URL

    /// A replacement that keeps its original size must come in below this
    /// share of the bytes it replaces.
    private static let requiredSaving = 0.92

    func run() -> [Int: StreamReplacement] {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        let lock = NSLock()
        var replacements: [Int: StreamReplacement] = [:]
        for group in ImageGroup.groups(in: catalog) {
            queue.addOperation {
                let result = process(group)
                lock.lock()
                replacements.merge(result) { first, _ in first }
                lock.unlock()
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        return replacements
    }

    private func process(_ group: ImageGroup) -> [Int: StreamReplacement] {
        let scale = group.allowsResizing ? downsamplingScale(for: group) : nil
        if let scale {
            let resized = encode(group, scale: scale)
            if resized.count == group.members.count { return resized }
        }
        return encode(group, scale: nil)
    }

    /// The scale that brings the group's densest use down to the target
    /// density, or nil when no member may or should shrink.
    private func downsamplingScale(for group: ImageGroup) -> Double? {
        var scale = 0.0
        for member in group.members {
            guard let density = usage.density(of: member), density > 0 else { return nil }
            scale = max(scale, profile.targetDensity / density)
        }
        return scale < EncodingProfile.largestWorthwhileScale ? scale : nil
    }

    /// How much the group is enlarged on screen when the page is viewed at
    /// the preset's viewing density. Images that may be drawn somewhere the
    /// scan cannot measure are treated as strongly enlarged.
    private func magnification(of group: ImageGroup, scale: Double?) -> Double {
        var largest = 1.0
        for member in group.members {
            guard let density = usage.density(of: member), density > 0 else { return Self.unknownMagnification }
            largest = max(largest, profile.viewingDensity / (density * (scale ?? 1)))
        }
        return largest
    }

    private static let unknownMagnification = 3.0

    private func encode(_ group: ImageGroup, scale: Double?) -> [Int: StreamReplacement] {
        let magnification = magnification(of: group, scale: scale)
        var replacements: [Int: StreamReplacement] = [:]
        var originalMasks: [Int: PixelBuffer] = [:]
        var finalMasks: [Int: PixelBuffer] = [:]

        for number in group.masks {
            guard let source = catalog.sources[number], source.channels == 1,
                  let pixels = decodePixels(source) else { continue }
            let reference = scale.map { downsample(pixels, of: source, scale: $0, alpha: nil) } ?? pixels
            originalMasks[number] = pixels
            finalMasks[number] = reference
            if let encoded = encodeMask(source, reference: reference),
               scale != nil || isWorthKeeping(encoded, against: source) {
                replacements[number] = store(encoded, for: source, size: reference)
            }
        }

        for number in group.bases {
            guard let source = catalog.sources[number] else { continue }
            let alpha = source.softMask.flatMap { originalMasks[$0] }.flatMap {
                $0.width == source.width && $0.height == source.height ? $0 : nil
            }
            let finalAlpha = source.softMask.flatMap { finalMasks[$0] }
            if let (encoded, size) = encodeBase(source, scale: scale, alpha: alpha, finalAlpha: finalAlpha,
                                                magnification: magnification),
               scale != nil || isWorthKeeping(encoded, against: source) {
                replacements[number] = store(encoded, for: source, size: size)
            }
        }
        return replacements
    }

    // MARK: Masks

    private func encodeMask(_ source: ImageSource, reference: PixelBuffer) -> EncodedImage? {
        let lossless = Flate.compressPredicted(reference).map { EncodedImage.flate($0, colors: 1) }
        guard !source.hasMatte else { return lossless }
        guard let jpeg = codec.encode(reference, quality: profile.maskQuality, chroma: .full),
              jpeg.count < (lossless?.byteCount ?? .max),
              let decoded = codec.decode(jpeg), decoded.hasSize(of: reference),
              FidelityCheck.largestDifference(reference, decoded) <= profile.maskTolerance else { return lossless }
        return .jpeg(jpeg)
    }

    // MARK: Base images

    private func encodeBase(_ source: ImageSource, scale: Double?, alpha: PixelBuffer?,
                            finalAlpha: PixelBuffer?, magnification: Double) -> (EncodedImage, PixelBuffer)? {
        switch source.storage {
        case .jpeg(let header, _):
            guard let pixels = decodePixels(source) else { return nil }
            let reference = scale.map { downsample(pixels, of: source, scale: $0, alpha: alpha) } ?? pixels
            let chroma = header.chroma ?? .quarter
            let visibility = finalAlpha.flatMap { $0.hasSize(of: reference) ? $0 : nil }
            let limit = scale == nil ? Int(Double(source.encodedLength) * Self.requiredSaving) : .max
            if let jpeg = QualitySearch(codec: codec).lowestAccepted(
                reference, qualities: profile.photoQualities, chroma: chroma, limit: limit,
                accept: { profile.accepts(StructuralSimilarity(reference, $0, alpha: visibility),
                                          magnification: magnification) }) {
                return (.jpeg(jpeg), reference)
            }
            guard scale != nil,
                  let jpeg = codec.encode(reference, quality: profile.photoQualities.upperBound, chroma: chroma)
            else { return nil }
            return (.jpeg(jpeg), reference)

        case .samples(let bytesPerPixel, .other):
            guard scale == nil, let data = try? Data(contentsOf: source.data),
                  let pixels = PixelBuffer(width: source.width, height: source.height,
                                           channels: bytesPerPixel, data: data),
                  let flate = Flate.compressPredicted(pixels) else { return nil }
            return (.flate(flate, colors: bytesPerPixel), pixels)

        case .samples:
            guard let pixels = decodePixels(source) else { return nil }
            let reference = scale.map { downsample(pixels, of: source, scale: $0, alpha: alpha) } ?? pixels
            guard let flate = Flate.compressPredicted(reference) else { return nil }
            let lossless = EncodedImage.flate(flate, colors: reference.channels)
            let visibility = finalAlpha.flatMap { $0.hasSize(of: reference) ? $0 : nil }
            let check = FidelityCheck(reference: reference, alpha: visibility)
            if let jpeg = QualitySearch(codec: codec).lowestAccepted(
                reference, qualities: profile.losslessQualities,
                chroma: .full, limit: flate.count / 2 + 1,
                accept: {
                    profile.accepts(StructuralSimilarity(reference, $0, alpha: visibility),
                                    magnification: magnification)
                        && check.isIndistinguishable(from: $0)
                }) {
                return (.jpeg(jpeg), reference)
            }
            return (lossless, reference)
        }
    }

    // MARK: Helpers

    private func decodePixels(_ source: ImageSource) -> PixelBuffer? {
        guard let data = try? Data(contentsOf: source.data) else { return nil }
        switch source.storage {
        case .jpeg(let header, let wrapped):
            guard let jpeg = wrapped ? Flate.decompress(data) : data,
                  let pixels = codec.decode(jpeg),
                  pixels.width == source.width, pixels.height == source.height,
                  pixels.channels == header.components else { return nil }
            return pixels
        case .samples(let bytesPerPixel, let model):
            guard model != .other else { return nil }
            return PixelBuffer(width: source.width, height: source.height, channels: bytesPerPixel, data: data)
        }
    }

    private func downsample(_ pixels: PixelBuffer, of source: ImageSource, scale: Double,
                            alpha: PixelBuffer?) -> PixelBuffer {
        let width = max(1, Int((Double(source.width) * scale).rounded(.up)))
        let height = max(1, Int((Double(source.height) * scale).rounded(.up)))
        if let alpha, alpha.hasSize(of: pixels) {
            return AreaResampler.downsample(pixels, shownThrough: alpha, width: width, height: height)
        }
        return AreaResampler.downsample(pixels, width: width, height: height)
    }

    private func isWorthKeeping(_ encoded: EncodedImage, against source: ImageSource) -> Bool {
        Double(encoded.byteCount) < Double(source.encodedLength) * Self.requiredSaving
    }

    private func store(_ encoded: EncodedImage, for source: ImageSource, size: PixelBuffer) -> StreamReplacement? {
        var dictionary = source.dictionary
        for key in ["/Length", "/Filter", "/DecodeParms", "/DL"] { dictionary[key] = nil }
        if size.width != source.width || size.height != source.height {
            dictionary["/Width"] = .integer(size.width)
            dictionary["/Height"] = .integer(size.height)
        }
        switch encoded {
        case .jpeg:
            dictionary["/Filter"] = .name("/DCTDecode")
        case .flate(_, let colors):
            dictionary["/Filter"] = .name("/FlateDecode")
            dictionary["/DecodeParms"] = .object(JSONObject([
                ("/Predictor", .integer(15)),
                ("/Colors", .integer(colors)),
                ("/BitsPerComponent", .integer(8)),
                ("/Columns", .integer(size.width)),
            ]))
        }
        let file = output.appendingPathComponent("\(source.number).bin")
        guard (try? encoded.data.write(to: file)) != nil else { return nil }
        return StreamReplacement(dictionary: dictionary, data: file)
    }
}
