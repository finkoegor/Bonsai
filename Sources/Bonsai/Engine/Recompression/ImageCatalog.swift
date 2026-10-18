import Foundation

/// The image XObjects of a document that Bonsai can re-encode, and which of
/// them serve as soft masks.
struct ImageCatalog: Sendable {
    let sources: [Int: ImageSource]
    /// Soft mask object number to the images it masks.
    let maskOwners: [Int: [Int]]

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
    }
}

private extension ImageCatalog {
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
                           hasMatte: dictionary["/Matte"] != nil)
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
