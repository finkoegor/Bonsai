import Foundation

/// Stream contents written to disk by `qpdf --json-stream-data=file` with
/// general purpose filters (Flate, LZW, ASCII) already removed.
struct StreamFiles: Sendable {
    struct Entry: Sendable {
        let url: URL
        /// Filters still applied to the bytes in `url`, outermost first.
        let remainingFilters: [String]
    }

    let entries: [Int: Entry]

    init(json: JSONValue) {
        var entries: [Int: Entry] = [:]
        let objects = json.object?["qpdf"]?.array?.last?.object
        for (key, entry) in objects?.members ?? [] where key.hasPrefix("obj:") {
            guard let number = Int(key.dropFirst(4).split(separator: " ").first ?? ""),
                  let stream = entry.object?["stream"]?.object,
                  case .string(let path)? = stream["datafile"] else { continue }
            let filters = stream["dict"]?.object?["/Filter"]?.filterNames ?? []
            entries[number] = Entry(url: URL(fileURLWithPath: path), remainingFilters: filters)
        }
        self.entries = entries
    }

    /// Fully decoded bytes, or nil when a filter could not be removed.
    func decodedData(_ number: Int) -> Data? {
        guard let entry = entries[number], entry.remainingFilters.isEmpty else { return nil }
        return try? Data(contentsOf: entry.url)
    }
}
