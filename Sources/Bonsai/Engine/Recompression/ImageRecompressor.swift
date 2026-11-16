import CoreGraphics
import Foundation

/// Re-encodes the images of a document, each base image together with its
/// soft mask. A group is cut down to the part of it that shows, downsampled
/// to the density of the pages it appears on, and encoded at the lowest
/// quality that still looks the same. A stream is replaced only when the
/// result is smaller, or when its group changed shape and every member must
/// follow.
struct ImageRecompressor: Sendable {
    let catalog: ImageCatalog
    let usage: ImageUsage
    let profile: EncodingProfile
    let codec: JPEGCodec
    /// Directory for the new stream contents.
    let output: URL

    /// How a group changes shape: the part that is kept, then the scale
    /// applied to it.
    private struct Shape {
        let crop: PixelRect?
        let scale: Double?
    }

    /// What became of one base image of a group.
    private struct BaseOutcome {
        let source: ImageSource
        let dropsMask: Bool
        /// The new stream, nil when the image keeps its bytes.
        let stored: StreamReplacement?
    }

    /// A replacement that keeps its original shape must come in below this
    /// share of the bytes it replaces.
    private static let requiredSaving = 0.92
    /// A cut must leave at most this share of the pixels to be worth the
    /// form XObject that goes around the image.
    private static let largestWorthwhileCrop = 0.8
    /// Pixels of source images held in memory at one time.
    private static let pixelBudget = 128_000_000
    /// Images that may be drawn somewhere the scan cannot measure are
    /// treated as enlarged this much on screen.
    private static let unknownMagnification = 3.0

    func run() -> RecompressedImages {
        let bare = imagesWithIdleMasks()
        var images = ImageRecompressor(catalog: catalog.withoutSoftMasks(of: bare), usage: usage,
                                       profile: profile, codec: codec, output: output).recompress()
        // An image that lost its mask and kept its bytes still needs its
        // dictionary rewritten.
        for number in bare where images.replacements[number] == nil && images.relocations[number] == nil {
            guard let source = catalog.sources[number] else { continue }
            images.replacements[number] = StreamReplacement(dictionary: source.withoutSoftMask().dictionary, data: nil)
        }
        return images
    }

    /// Images whose soft mask is opaque all over and can go: every place the
    /// image is drawn is known, and none is under a soft mask of the
    /// graphics state, which the image's own mask, even an idle one, would
    /// switch off. Without the mask an image no longer has to share the
    /// shape of others that used the same one.
    private func imagesWithIdleMasks() -> Set<Int> {
        // A mask with /Matte counts too: an image blended toward its matte
        // color by an opacity of 1 everywhere is the image itself.
        let masks = catalog.maskOwners.keys.filter { mask in
            catalog.sources[mask].map { $0.channels == 1 && !$0.hasDecode } ?? false
        }
        let lock = NSLock()
        var idle: Set<Int> = []
        DispatchQueue.concurrentPerform(iterations: masks.count) { index in
            guard let source = catalog.sources[masks[index]],
                  decodePixels(source)?.isOpaque == true else { return }
            lock.lock()
            idle.insert(masks[index])
            lock.unlock()
        }
        return Set(catalog.sources.values.compactMap { source -> Int? in
            guard let mask = source.softMask, idle.contains(mask), usage.covers(source.number),
                  usage.painted.contains(source.number),
                  !usage.paintedUnderSoftMask.contains(source.number) else { return nil }
            return source.number
        })
    }

    private func recompress() -> RecompressedImages {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = max(2, ProcessInfo.processInfo.activeProcessorCount)
        let budget = PixelBudget(capacity: Self.pixelBudget)
        let lock = NSLock()
        var images = RecompressedImages()

        let groups = ImageGroup.groups(in: catalog)
            .map { group in (group, group.members.reduce(0) { $0 + pixelCount(of: $1) }) }
            .sorted { $0.1 > $1.1 }
        for (group, pixels) in groups {
            queue.addOperation {
                let result = budget.reserving(pixels) { process(group) }
                lock.lock()
                images.merge(result)
                lock.unlock()
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        return images
    }

    private func pixelCount(of image: Int) -> Int {
        catalog.sources[image].map { $0.width * $0.height } ?? 0
    }

    private func process(_ group: ImageGroup) -> RecompressedImages {
        var alphas: [Int: PixelBuffer] = [:]
        for number in group.masks {
            if let source = catalog.sources[number], source.isPlainAlpha, let pixels = decodePixels(source) {
                alphas[number] = pixels
            }
        }
        if let shape = shape(for: group, alphas: alphas),
           let reshaped = encode(group, shape: shape, alphas: alphas) {
            return reshaped
        }
        return encode(group, shape: nil, alphas: alphas) ?? RecompressedImages()
    }

    // MARK: Shape

    private func shape(for group: ImageGroup, alphas: [Int: PixelBuffer]) -> Shape? {
        guard group.allowsResizing else { return nil }
        let scale = downsamplingScale(for: group)
        let crop = visibleRect(of: group, scale: scale ?? 1, alphas: alphas)
        return scale == nil && crop == nil ? nil : Shape(crop: crop, scale: scale)
    }

    /// The scale that brings the group down to the density of the pages it
    /// is drawn on, or nil when no member may or should shrink.
    private func downsamplingScale(for group: ImageGroup) -> Double? {
        var scale = 0.0
        for member in group.members {
            guard let placements = usage.placements(of: member) else { return nil }
            for (page, density) in placements where density > 0 {
                scale = max(scale, profile.density(on: page) / density)
            }
        }
        return scale > 0 && scale < EncodingProfile.largestWorthwhileScale ? scale : nil
    }

    /// How much the group is enlarged on screen when its pages are viewed
    /// at the preset's viewing density.
    private func magnification(of group: ImageGroup, scale: Double?) -> Double {
        var largest = 1.0
        for member in group.members {
            guard let placements = usage.placements(of: member) else { return Self.unknownMagnification }
            for density in placements.values where density > 0 {
                largest = max(largest, profile.viewingDensity / (density * (scale ?? 1)))
            }
        }
        return largest
    }

    /// The part of the group that can show: what clips, form boxes and soft
    /// masks leave of each image wherever it is drawn, and within that the
    /// pixels its own alpha does not hide. Nil when the whole image shows,
    /// or when cutting it is not safe or not worth it.
    ///
    /// An image painted under a soft mask, a constant alpha or a blend mode
    /// set outside it is left whole: PDFium applies such settings wrongly to
    /// a form XObject standing in for an image. Inside a transparency group
    /// they start afresh, which is where design tools draw masked layers.
    private func visibleRect(of group: ImageGroup, scale: Double, alphas: [Int: PixelBuffer]) -> PixelRect? {
        guard let first = group.members.first.flatMap({ catalog.sources[$0] }),
              group.members.allSatisfy({ member in
                  catalog.sources[member].map { $0.width == first.width && $0.height == first.height } ?? false
              }),
              group.bases.allSatisfy({ catalog.isRelocatable($0) && !usage.paintedWithTransparency.contains($0) }),
              group.masks.allSatisfy({ catalog.isOnlySoftMask($0) && !usage.painted.contains($0) })
        else { return nil }
        let width = first.width, height = first.height

        var kept = PixelRect(x: 0, y: 0, width: 0, height: 0)
        for base in group.bases {
            guard let region = usage.visibleRegion(of: base) else { return nil }
            if region.isNull || region.isEmpty { continue }
            let left = Int((Double(region.minX) * Double(width)).rounded(.down))
            let right = Int((Double(region.maxX) * Double(width)).rounded(.up))
            let top = Int(((1 - Double(region.maxY)) * Double(height)).rounded(.down))
            let bottom = Int(((1 - Double(region.minY)) * Double(height)).rounded(.up))
            kept = kept.union(PixelRect(x: left, y: top, width: right - left, height: bottom - top))
        }

        // In a knockout group a transparent pixel still erases what lies
        // under it, so only the clip may cut an image there.
        let masks = Set(group.bases.compactMap { catalog.sources[$0]?.softMask })
        if !usage.hasKnockoutGroups,
           group.bases.allSatisfy({ catalog.sources[$0]?.softMask != nil }),
           masks.allSatisfy({ alphas[$0] != nil }) {
            var shown = PixelRect(x: 0, y: 0, width: 0, height: 0)
            for mask in masks {
                if let bounds = alphas[mask]?.boundsOfVisible { shown = shown.union(bounds) }
            }
            kept = kept.intersection(shown)
        }

        // A margin keeps the pixels a reader blends into the visible edge
        // when it scales the image. The origin lands on a block boundary so
        // that a JPEG can be cut without re-encoding.
        let full = PixelRect(x: 0, y: 0, width: width, height: height)
        let margin = Int((3 / scale).rounded(.up)) + 2
        var rect = kept.isEmpty ? PixelRect(x: 0, y: 0, width: 1, height: 1) : kept.expanded(by: margin)
        let left = max(0, rect.x) / JPEGCodec.blockSize * JPEGCodec.blockSize
        let top = max(0, rect.y) / JPEGCodec.blockSize * JPEGCodec.blockSize
        rect = PixelRect(x: left, y: top, width: rect.maxX - left, height: rect.maxY - top).intersection(full)
        rect.width = max(rect.width, min(JPEGCodec.blockSize, width - rect.x))
        rect.height = max(rect.height, min(JPEGCodec.blockSize, height - rect.y))

        guard Double(rect.area) <= Double(full.area) * Self.largestWorthwhileCrop else { return nil }
        return rect
    }

    // MARK: Encoding a group

    /// Returns nil when the group was to change shape and a member could
    /// not follow; the group then stays in its original shape.
    private func encode(_ group: ImageGroup, shape: Shape?, alphas: [Int: PixelBuffer]) -> RecompressedImages? {
        let crop = shape?.crop, scale = shape?.scale
        let magnification = magnification(of: group, scale: scale)
        var images = RecompressedImages()

        // Masks in their final shape. `shown` holds the ones that are plain
        // opacity, which tells how much of each base image is seen.
        var finalMasks: [Int: PixelBuffer] = [:]
        var shown: [Int: PixelBuffer] = [:]
        for number in group.masks {
            guard let source = catalog.sources[number], source.channels == 1,
                  let pixels = alphas[number] ?? decodePixels(source) else {
                if shape != nil { return nil }
                continue
            }
            var reference = crop.map { pixels.cropped(to: $0) } ?? pixels
            if let scale { reference = downsample(reference, scale: scale, alpha: nil) }
            finalMasks[number] = reference
            if alphas[number] != nil { shown[number] = reference }
        }

        // Masks of images that are not in the group stay in use whatever
        // happens to the images that are.
        var masksInUse = Set(group.masks.filter { mask in
            catalog.maskOwners[mask, default: []].contains { !group.bases.contains($0) }
        })

        // Images sharing a mask are independent of each other once the
        // shape is settled, so they are encoded side by side.
        var outcomes = [BaseOutcome?](repeating: nil, count: group.bases.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: group.bases.count) { index in
            guard let source = catalog.sources[group.bases[index]] else { return }
            // A soft mask that hides nothing goes away, unless the image is
            // drawn under a soft mask of the graphics state: its own mask,
            // even an opaque one, switches that one off.
            let opacity = source.softMask.flatMap { shown[$0] }
            let dropsMask = opacity?.isOpaque == true && usage.covers(source.number)
                && usage.painted.contains(source.number) && !usage.paintedUnderSoftMask.contains(source.number)
            let encoded = encodeBase(source, crop: crop, scale: scale,
                                     alpha: dropsMask ? nil : source.softMask.flatMap { alphas[$0] },
                                     visibility: dropsMask ? nil : opacity,
                                     magnification: magnification)
            var stored: StreamReplacement?
            if let encoded, shape != nil || isWorthKeeping(encoded.image, against: source) {
                stored = store(encoded.image, for: source, width: encoded.width, height: encoded.height,
                               withoutSoftMask: dropsMask)
            }
            lock.lock()
            outcomes[index] = BaseOutcome(source: source, dropsMask: dropsMask, stored: stored)
            lock.unlock()
        }

        for outcome in outcomes {
            guard let outcome else {
                if shape != nil { return nil }
                continue
            }
            let source = outcome.source
            if let mask = source.softMask, !outcome.dropsMask { masksInUse.insert(mask) }
            if shape != nil {
                guard let stored = outcome.stored else { return nil }
                if let crop {
                    let frame = CGRect(x: Double(crop.x) / Double(source.width),
                                       y: 1 - Double(crop.maxY) / Double(source.height),
                                       width: Double(crop.width) / Double(source.width),
                                       height: Double(crop.height) / Double(source.height))
                    images.relocations[source.number] = ImageRelocation(image: stored, frame: frame)
                } else {
                    images.replacements[source.number] = stored
                }
            } else if let stored = outcome.stored {
                images.replacements[source.number] = stored
            } else if outcome.dropsMask {
                images.replacements[source.number] = StreamReplacement(
                    dictionary: source.withoutSoftMask().dictionary, data: nil)
            }
        }

        for number in group.masks where masksInUse.contains(number) {
            guard let source = catalog.sources[number], let reference = finalMasks[number] else { continue }
            if let encoded = encodeMask(source, reference: reference),
               shape != nil || isWorthKeeping(encoded, against: source) {
                images.replacements[number] = store(encoded, for: source, width: reference.width,
                                                    height: reference.height, withoutSoftMask: false)
            } else if shape != nil {
                return nil
            }
        }
        return images
    }

    // MARK: Masks

    private func encodeMask(_ source: ImageSource, reference: PixelBuffer) -> EncodedImage? {
        let lossless = Flate.compressPredicted(reference).map { EncodedImage.flate($0, colors: 1) }
        guard !source.hasMatte,
              let jpeg = codec.encode(reference, quality: profile.maskQuality, chroma: .full),
              let decoded = codec.decode(jpeg), decoded.hasSize(of: reference), decoded.channels == 1,
              FidelityCheck.largestDifference(reference, decoded) <= profile.maskTolerance,
              StructuralSimilarity(reference, decoded).brightnessShift <= profile.brightnessTolerance
        else { return lossless }
        let lossy = EncodedImage.packing(jpeg: jpeg)
        return lossy.byteCount < (lossless?.byteCount ?? .max) ? lossy : lossless
    }

    // MARK: Base images

    /// - Parameters:
    ///   - alpha: the image's opacity at its original size, when known.
    ///   - visibility: the same opacity in the shape the image will have.
    private func encodeBase(_ source: ImageSource, crop: PixelRect?, scale: Double?, alpha: PixelBuffer?,
                            visibility: PixelBuffer?, magnification: Double)
        -> (image: EncodedImage, width: Int, height: Int)? {
        let changesShape = crop != nil || scale != nil
        switch source.storage {
        case .jpeg(let header, let wrapped):
            guard let jpeg = jpegData(of: source), let pixels = decodePixels(source, jpeg: jpeg) else { return nil }
            let reference = prepare(pixels, crop: crop, scale: scale, alpha: alpha, visibility: visibility,
                                    tolerance: 1)
            let chroma = header.chroma ?? .quarter

            // What the image costs with its pixels left exactly as they are.
            var untouched: (image: EncodedImage, width: Int, height: Int)?
            if scale == nil, let crop {
                untouched = codec.crop(jpeg, to: crop).map { (EncodedImage.packing(jpeg: $0), crop.width, crop.height) }
            } else if !changesShape, !wrapped, source.dictionary["/DecodeParms"] == nil {
                let packed = EncodedImage.packing(jpeg: jpeg)
                if case .deflatedJPEG = packed { untouched = (packed, source.width, source.height) }
            }
            let ceiling = untouched?.image.byteCount ?? (changesShape ? Int.max : source.encodedLength)
            let limit = ceiling == .max ? Int.max : Int(Double(ceiling) * Self.requiredSaving)

            if let found = QualitySearch(codec: codec).lowestAccepted(
                reference, qualities: profile.photoQualities, chroma: chroma, limit: limit,
                accept: { profile.accepts(StructuralSimilarity(reference, $0, alpha: visibility),
                                          magnification: magnification) }) {
                return (found, reference.width, reference.height)
            }
            if let untouched { return untouched }
            guard scale != nil,
                  let best = codec.encode(reference, quality: profile.photoQualities.upperBound, chroma: chroma)
            else { return nil }
            return (.packing(jpeg: best), reference.width, reference.height)

        case .samples(let bytesPerPixel, .other):
            guard !changesShape, let data = try? Data(contentsOf: source.data),
                  let pixels = PixelBuffer(width: source.width, height: source.height,
                                           channels: bytesPerPixel, data: data),
                  let flate = Flate.compressPredicted(pixels) else { return nil }
            return (.flate(flate, colors: bytesPerPixel), pixels.width, pixels.height)

        case .samples:
            guard let pixels = decodePixels(source) else { return nil }
            let reference = prepare(pixels, crop: crop, scale: scale, alpha: alpha, visibility: visibility,
                                    tolerance: 0)
            guard let flate = Flate.compressPredicted(reference) else { return nil }
            let check = FidelityCheck(reference: reference, alpha: visibility)
            if let found = QualitySearch(codec: codec).lowestAccepted(
                reference, qualities: profile.losslessQualities,
                chroma: .full, limit: flate.count / 2 + 1,
                accept: {
                    profile.accepts(StructuralSimilarity(reference, $0, alpha: visibility),
                                    magnification: magnification)
                        && check.isIndistinguishable(from: $0)
                }) {
                return (found, reference.width, reference.height)
            }
            return (.flate(flate, colors: reference.channels), reference.width, reference.height)
        }
    }

    /// Brings decoded pixels into the shape they will be stored in. Color
    /// hidden by the alpha channel is then evened out; `tolerance` is the
    /// change, in levels, that may show on screen.
    private func prepare(_ pixels: PixelBuffer, crop: PixelRect?, scale: Double?, alpha: PixelBuffer?,
                         visibility: PixelBuffer?, tolerance: Int) -> PixelBuffer {
        var reference = crop.map { pixels.cropped(to: $0) } ?? pixels
        if let scale {
            let opacity = alpha.flatMap { $0.hasSize(of: pixels) ? $0 : nil }
            reference = downsample(reference, scale: scale, alpha: opacity.map { mask in
                crop.map { mask.cropped(to: $0) } ?? mask
            })
        }
        if let visibility, visibility.hasSize(of: reference) {
            reference = HiddenColorFill.apply(to: reference, alpha: visibility, tolerance: tolerance)
        }
        return reference
    }

    // MARK: Helpers

    /// The JPEG file of an image stored as one, without its Flate layer.
    private func jpegData(of source: ImageSource) -> Data? {
        guard case .jpeg(_, let wrapped) = source.storage,
              let data = try? Data(contentsOf: source.data) else { return nil }
        return wrapped ? Flate.decompress(data) : data
    }

    private func decodePixels(_ source: ImageSource, jpeg: Data? = nil) -> PixelBuffer? {
        switch source.storage {
        case .jpeg(let header, _):
            guard let jpeg = jpeg ?? jpegData(of: source),
                  let pixels = codec.decode(jpeg),
                  pixels.width == source.width, pixels.height == source.height,
                  pixels.channels == header.components else { return nil }
            return pixels
        case .samples(let bytesPerPixel, let model):
            guard model != .other, let data = try? Data(contentsOf: source.data) else { return nil }
            return PixelBuffer(width: source.width, height: source.height, channels: bytesPerPixel, data: data)
        }
    }

    private func downsample(_ pixels: PixelBuffer, scale: Double, alpha: PixelBuffer?) -> PixelBuffer {
        let width = max(1, Int((Double(pixels.width) * scale).rounded(.up)))
        let height = max(1, Int((Double(pixels.height) * scale).rounded(.up)))
        if let alpha, alpha.hasSize(of: pixels) {
            return Downsampler.downsample(pixels, shownThrough: alpha, width: width, height: height)
        }
        return Downsampler.downsample(pixels, width: width, height: height)
    }

    private func isWorthKeeping(_ encoded: EncodedImage, against source: ImageSource) -> Bool {
        Double(encoded.byteCount) < Double(source.encodedLength) * Self.requiredSaving
    }

    private func store(_ encoded: EncodedImage, for source: ImageSource, width: Int, height: Int,
                       withoutSoftMask: Bool) -> StreamReplacement? {
        var dictionary = source.dictionary
        for key in ["/Length", "/Filter", "/DecodeParms", "/DL"] { dictionary[key] = nil }
        if withoutSoftMask { dictionary["/SMask"] = nil }
        if width != source.width || height != source.height {
            dictionary["/Width"] = .integer(width)
            dictionary["/Height"] = .integer(height)
        }
        switch encoded {
        case .jpeg:
            dictionary["/Filter"] = .name("/DCTDecode")
        case .deflatedJPEG:
            dictionary["/Filter"] = .array([.name("/FlateDecode"), .name("/DCTDecode")])
        case .flate(_, let colors):
            dictionary["/Filter"] = .name("/FlateDecode")
            dictionary["/DecodeParms"] = .object(JSONObject([
                ("/Predictor", .integer(15)),
                ("/Colors", .integer(colors)),
                ("/BitsPerComponent", .integer(8)),
                ("/Columns", .integer(width)),
            ]))
        }
        let file = output.appendingPathComponent("\(source.number).bin")
        guard (try? encoded.data.write(to: file)) != nil else { return nil }
        return StreamReplacement(dictionary: dictionary, data: file)
    }
}
