import Foundation

/// The image XObjects of a document that Bonsai can re-encode, and which of
/// them serve as soft masks.
struct ImageCatalog: Sendable {
    let sources: [Int: ImageSource]
    /// Soft mask object number to the images it masks.
    let maskOwners: [Int: [Int]]
    /// Objects something refers to as an image rather than as an XObject to
    /// paint: explicit masks, page thumbnails, alternate images.
    let heldAsImages: Set<Int>

    /// Dictionary entries an image may carry and still be cut down: a form
    /// XObject painting the cut image stands in for it, and anything else,
    /// such as structure or optional content, is tied to the image itself.
    private static let plainEntries: Set<String> = [
        "/Type", "/Subtype", "/Width", "/Height", "/ColorSpace", "/BitsPerComponent", "/Filter",
        "/DecodeParms", "/Length", "/DL", "/SMask", "/Interpolate", "/Intent", "/Name", "/Decode",
    ]

    /// `duplicates` maps copies to the object that stays; copies are left out
    /// and references to them read as references to the object that stays.
    init(store: PDFObjectStore, files: StreamFiles, duplicates: [Int: Int]) {
        var sources: [Int: ImageSource] = [:]
        var owners: [Int: [Int]] = [:]
        for number in store.bodies.keys.sorted() where duplicates[number] == nil {
            guard let dictionary = store.streamDictionary(number),
                  dictionary["/Subtype"]?.name == "/Image" else { continue }
            let mask = dictionary["/SMask"]?.reference.map { duplicates[$0] ?? $0 }
            if let mask { owners[mask, default: []].append(number) }
            if let source = Self.source(number, dictionary: dictionary, softMask: mask, store: store, files: files) {
                sources[number] = source
            }
        }
        self.sources = sources
        self.maskOwners = owners

        var held: Set<Int> = []
        for body in store.bodies.values {
            switch body {
            case .value(let value): Self.collectImageReferences(in: value, into: &held)
            case .stream(let dictionary): Self.collectImageReferences(in: .object(dictionary), into: &held)
            }
        }
        self.heldAsImages = held
    }

    private init(sources: [Int: ImageSource], maskOwners: [Int: [Int]], heldAsImages: Set<Int>) {
        self.sources = sources
        self.maskOwners = maskOwners
        self.heldAsImages = heldAsImages
    }

    /// The catalog with the soft masks of `images` taken away. Masks left
    /// without an image to mask drop out.
    func withoutSoftMasks(of images: Set<Int>) -> ImageCatalog {
        var sources = sources
        var owners = maskOwners
        for image in images {
            guard let source = sources[image], let mask = source.softMask else { continue }
            sources[image] = source.withoutSoftMask()
            owners[mask]?.removeAll { $0 == image }
            if owners[mask]?.isEmpty == true {
                owners[mask] = nil
                sources[mask] = nil
            }
        }
        return ImageCatalog(sources: sources, maskOwners: owners, heldAsImages: heldAsImages)
    }

    /// True when a form XObject can take the place of this image.
    func isRelocatable(_ number: Int) -> Bool {
        guard let source = sources[number], maskOwners[number] == nil, !heldAsImages.contains(number) else {
            return false
        }
        return source.dictionary.keys.allSatisfy(Self.plainEntries.contains)
    }

    /// True when a soft mask serves only as that: cutting it down together
    /// with its images leaves nothing else to follow.
    func isOnlySoftMask(_ number: Int) -> Bool {
        maskOwners[number] != nil && !heldAsImages.contains(number)
    }
}

private extension ImageCatalog {
    static func collectImageReferences(in value: JSONValue, into held: inout Set<Int>) {
        switch value {
        case .object(let object):
            for (key, member) in object.members {
                if ["/Mask", "/Thumb", "/Image"].contains(key), let number = member.reference {
                    held.insert(number)
                }
                collectImageReferences(in: member, into: &held)
            }
        case .array(let array):
            for element in array { collectImageReferences(in: element, into: &held) }
        default:
            break
        }
    }

    static func source(_ number: Int, dictionary: JSONObject, softMask: Int?, store: PDFObjectStore,
                       files: StreamFiles) -> ImageSource? {
        guard dictionary["/ImageMask"]?.boolean != true,
              dictionary["/Mask"] == nil, dictionary["/SMaskInData"] == nil,
              dictionary["/BitsPerComponent"]?.integer == 8,
              let width = dictionary["/Width"]?.integer, let height = dictionary["/Height"]?.integer,
              width > 0, height > 0,
              let file = files.entries[number],
              let encodedLength = store.encodedLength(number), encodedLength > 0,
              let storage = storage(dictionary: dictionary, file: file, width: width, height: height, store: store)
        else { return nil }

        return ImageSource(number: number, dictionary: dictionary, width: width, height: height,
                           encodedLength: encodedLength, data: file.url, storage: storage,
                           softMask: softMask,
                           hasMatte: dictionary["/Matte"] != nil,
                           hasDecode: dictionary["/Decode"] != nil)
    }

    static func storage(dictionary: JSONObject, file: StreamFiles.Entry, width: Int, height: Int,
                        store: PDFObjectStore) -> ImageSource.Storage? {
        switch file.remainingFilters {
        case []:
            guard let size = (try? file.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                  size > 0, size % (width * height) == 0 else { return nil }
            let bytesPerPixel = size / (width * height)
            guard (1...4).contains(bytesPerPixel) else { return nil }
            let model = colorModel(dictionary["/ColorSpace"], bytesPerPixel: bytesPerPixel, store: store)
            return .samples(bytesPerPixel: bytesPerPixel, model: model)

        case ["/DCTDecode"], ["/FlateDecode", "/DCTDecode"]:
            guard allowsReencoding(dictionary["/DecodeParms"], store: store) else { return nil }
            let wrapped = file.remainingFilters.count == 2
            let jpeg = wrapped
                ? (try? Data(contentsOf: file.url)).flatMap(Flate.decompress)
                : prefix(of: file.url)
            guard let jpeg, let header = JPEGHeader(jpeg),
                  header.width == width, header.height == height, header.isReencodable else { return nil }
            return .jpeg(header, wrappedInFlate: wrapped)

        default:
            return nil
        }
    }

    /// Decode parameters a re-encoded JPEG can drop. Encoder hints such as
    /// /QFactor mean nothing to readers; /ColorTransform 1 is the YCbCr
    /// conversion every new JPEG uses by default. /ColorTransform 0 would
    /// make readers skip that conversion, so such images stay as they are.
    static func allowsReencoding(_ parameters: JSONValue?, store: PDFObjectStore) -> Bool {
        guard let parameters = store.resolve(parameters) else { return true }
        switch parameters {
        case .null:
            return true
        case .object(let object):
            let transform = object["/ColorTransform"].map { $0.integer == 1 } ?? true
            return transform && object["/Predictor"] == nil
        case .array(let array):
            return array.allSatisfy { allowsReencoding($0, store: store) }
        default:
            return false
        }
    }

    /// The first megabyte of a file, enough for any JPEG header.
    static func prefix(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: 1 << 20)
    }

    static func colorModel(_ value: JSONValue?, bytesPerPixel: Int, store: PDFObjectStore) -> ImageSource.ColorModel {
        guard let space = store.resolve(value) else { return .other }
        var family: String?
        var components: Int?
        if let name = space.name {
            family = name
        } else if let array = space.array, let first = array.first?.name {
            family = first
            if first == "/ICCBased", array.count > 1 {
                components = store.resolveDictionary(array[1])?["/N"]?.integer
            }
        }
        switch (family, bytesPerPixel) {
        case ("/DeviceGray", 1), ("/CalGray", 1): return .gray
        case ("/DeviceRGB", 3), ("/CalRGB", 3): return .rgb
        case ("/ICCBased", 1) where components == 1: return .gray
        case ("/ICCBased", 3) where components == 3: return .rgb
        default: return .other
        }
    }
}
