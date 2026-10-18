import CryptoKit
import Foundation

/// Finds image XObjects that are exact copies of each other. Design tools
/// often write the same bitmap once per page it appears on.
struct DuplicateImageFinder {
    let store: PDFObjectStore
    let files: StreamFiles

    /// Maps every duplicate to the copy that stays, the lowest object number.
    /// Masks are matched first, so images that differ only in which copy of a
    /// mask they point at are matched too.
    func duplicates() -> [Int: Int] {
        let images = store.bodies.keys.sorted().filter {
            store.streamDictionary($0)?["/Subtype"]?.name == "/Image"
        }
        var replacements: [Int: Int] = [:]
        let unmasked = images.filter { store.streamDictionary($0)?["/SMask"]?.reference == nil }
        let masked = images.filter { store.streamDictionary($0)?["/SMask"]?.reference != nil }
        for group in [unmasked, masked] {
            var keeper: [String: Int] = [:]
            let rewriter = ReferenceRewriter(replacements: replacements, generations: store.generations)
            for number in group {
                guard let dictionary = store.streamDictionary(number),
                      let fingerprint = fingerprint(of: number, dictionary: rewriter.rewrite(dictionary)) else { continue }
                if let original = keeper[fingerprint] {
                    replacements[number] = original
                } else {
                    keeper[fingerprint] = number
                }
            }
        }
        return replacements
    }

    private func fingerprint(of number: Int, dictionary: JSONObject) -> String? {
        guard let entry = files.entries[number],
              let handle = try? FileHandle(forReadingFrom: entry.url) else { return nil }
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        var shape = dictionary
        shape["/Length"] = nil
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return JSONValue.object(shape).serialized + entry.remainingFilters.joined() + digest
    }
}
