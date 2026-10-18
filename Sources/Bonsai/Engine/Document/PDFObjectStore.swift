import Foundation

/// The objects of one PDF, read from `qpdf --json` output taken without
/// decoding streams, so stream dictionaries describe the bytes in the file.
struct PDFObjectStore: Sendable {
    enum Body: Sendable {
        case value(JSONValue)
        case stream(JSONObject)
    }

    struct Malformed: Error {}

    let bodies: [Int: Body]
    let generations: [Int: Int]
    let maxObjectID: Int
    /// Page objects in document order.
    let pages: [Int]

    init(json: JSONValue) throws {
        guard let root = json.object,
              let sections = root["qpdf"]?.array, sections.count == 2,
              let header = sections[0].object,
              let objects = sections[1].object else { throw Malformed() }

        var bodies: [Int: Body] = [:]
        var generations: [Int: Int] = [:]
        for (key, entry) in objects.members where key.hasPrefix("obj:") {
            let parts = key.dropFirst(4).split(separator: " ")
            guard parts.count == 3, let number = Int(parts[0]), let generation = Int(parts[1]),
                  let entry = entry.object else { continue }
            if let dictionary = entry["stream"]?.object?["dict"]?.object {
                bodies[number] = .stream(dictionary)
            } else if let value = entry["value"] {
                bodies[number] = .value(value)
            }
            generations[number] = generation
        }
        self.bodies = bodies
        self.generations = generations
        self.maxObjectID = header["maxobjectid"]?.integer ?? bodies.keys.max() ?? 0
        self.pages = root["pages"]?.array?.compactMap { $0.object?["object"]?.reference } ?? []
    }

    /// The dictionary of an object: its value when that is a dictionary, or
    /// the stream dictionary.
    func dictionary(_ number: Int) -> JSONObject? {
        switch bodies[number] {
        case .value(let value): value.object
        case .stream(let dictionary): dictionary
        case nil: nil
        }
    }

    func streamDictionary(_ number: Int) -> JSONObject? {
        if case .stream(let dictionary) = bodies[number] { return dictionary }
        return nil
    }

    /// Follows indirect references. A reference to a stream resolves to its
    /// dictionary.
    func resolve(_ value: JSONValue?) -> JSONValue? {
        var current = value
        var hops = 0
        while let number = current?.reference {
            hops += 1
            guard hops < 32 else { return nil }
            switch bodies[number] {
            case .value(let next): current = next
            case .stream(let dictionary): return .object(dictionary)
            case nil: return nil
            }
        }
        return current
    }

    func resolveDictionary(_ value: JSONValue?) -> JSONObject? {
        resolve(value)?.object
    }

    /// Looks a resource name up in a dictionary, tolerating `#xx` escapes
    /// written differently in the content stream and in the dictionary.
    func entry(_ name: String, in dictionary: JSONObject) -> JSONValue? {
        if let direct = dictionary[name] { return direct }
        let wanted = PDFName.decoded(name)
        return dictionary.members.first { PDFName.decoded($0.key) == wanted }?.value
    }

    /// The stream's length in the file.
    func encodedLength(_ number: Int) -> Int? {
        guard let dictionary = streamDictionary(number) else { return nil }
        return resolve(dictionary["/Length"])?.integer
    }
}
