import Foundation

/// Recompresses the streams that are not images. Page content and form
/// XObjects first get their numbers shortened; every stream is then deflated
/// at the highest level and replaced when that makes it smaller.
struct StreamRepacker: Sendable {
    let store: PDFObjectStore
    let files: StreamFiles
    /// Directory for the new stream contents.
    let output: URL

    /// Streams shorter than this are left alone: a Flate header and
    /// checksum would eat the gain.
    private static let smallestWorthwhileLength = 64

    /// `settled` lists streams decided elsewhere, such as images and their
    /// duplicates.
    func run(skipping settled: Set<Int>) -> [Int: StreamReplacement] {
        let content = contentStreams()
        let candidates = store.bodies.keys.sorted().filter { number in
            // A stream with /F keeps its data in another file.
            guard !settled.contains(number), let dictionary = store.streamDictionary(number),
                  dictionary["/Subtype"]?.name != "/Image", dictionary["/F"] == nil,
                  !["/Metadata", "/XRef", "/ObjStm"].contains(dictionary["/Type"]?.name ?? ""),
                  let length = store.encodedLength(number), length >= Self.smallestWorthwhileLength
            else { return false }
            return true
        }

        let lock = NSLock()
        var replacements: [Int: StreamReplacement] = [:]
        DispatchQueue.concurrentPerform(iterations: candidates.count) { index in
            let number = candidates[index]
            guard let replacement = repack(number, isContent: content.contains(number)) else { return }
            lock.lock()
            replacements[number] = replacement
            lock.unlock()
        }
        return replacements
    }

    private func repack(_ number: Int, isContent: Bool) -> StreamReplacement? {
        guard let dictionary = store.streamDictionary(number),
              let length = store.encodedLength(number),
              let decoded = files.decodedData(number) else { return nil }
        let data = isContent ? ContentNumberShortener.shorten(decoded) ?? decoded : decoded
        guard let deflated = Flate.compress(data), deflated.count < length else { return nil }

        var rewritten = dictionary
        for key in ["/Length", "/Filter", "/DecodeParms", "/DL"] { rewritten[key] = nil }
        rewritten["/Filter"] = .name("/FlateDecode")
        let file = output.appendingPathComponent("\(number).bin")
        guard (try? deflated.write(to: file)) != nil else { return nil }
        return StreamReplacement(dictionary: rewritten, data: file)
    }

    /// The streams made of drawing operators that stand on their own: form
    /// XObjects and the content of pages that keep it in one stream. Content
    /// split over several streams is left as written, since an inline image
    /// or an array may run from one stream into the next.
    private func contentStreams() -> Set<Int> {
        var streams: Set<Int> = []
        for page in store.pages {
            guard let contents = store.dictionary(page)?["/Contents"] else { continue }
            if let single = contents.reference, store.streamDictionary(single) != nil {
                streams.insert(single)
            } else if let parts = store.resolve(contents)?.array?.compactMap(\.reference), parts.count == 1 {
                streams.insert(parts[0])
            }
        }
        for (number, body) in store.bodies {
            if case .stream(let dictionary) = body, dictionary["/Subtype"]?.name == "/Form" {
                streams.insert(number)
            }
        }
        return streams
    }
}
