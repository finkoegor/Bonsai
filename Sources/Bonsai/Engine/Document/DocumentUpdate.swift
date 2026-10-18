import Foundation

/// Object changes in the form `qpdf --update-from-json` applies. Objects not
/// listed are copied from the source file untouched.
struct DocumentUpdate {
    private var entries: [Int: JSONValue] = [:]

    var isEmpty: Bool { entries.isEmpty }

    mutating func replaceValue(of number: Int, with value: JSONValue) {
        entries[number] = .object(JSONObject([("value", value)]))
    }

    /// Replaces a stream dictionary and keeps the stream bytes as they are,
    /// so `dictionary` must describe the existing encoding.
    mutating func replaceDictionary(ofStream number: Int, with dictionary: JSONObject) {
        entries[number] = .object(JSONObject([("stream", .object(JSONObject([("dict", .object(dictionary))])))]))
    }

    /// Replaces a stream with the bytes in `data`, encoded as `dictionary` says.
    mutating func replaceStream(_ number: Int, dictionary: JSONObject, data: URL) {
        let stream = JSONObject([("dict", .object(dictionary)), ("datafile", .string(data.path))])
        entries[number] = .object(JSONObject([("stream", .object(stream))]))
    }

    func json(maxObjectID: Int, generations: [Int: Int]) -> Data {
        let header = JSONObject([
            ("jsonversion", .integer(2)),
            ("pushedinheritedpageresources", .bool(false)),
            ("calledgetallpages", .bool(false)),
            ("maxobjectid", .integer(maxObjectID)),
        ])
        var objects = JSONObject()
        for number in entries.keys.sorted() {
            objects["obj:\(number) \(generations[number] ?? 0) R"] = entries[number]
        }
        let root = JSONObject([("qpdf", .array([.object(header), .object(objects)]))])
        return Data(JSONValue.object(root).serialized.utf8)
    }
}
