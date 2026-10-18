import Foundation

/// A JSON object that remembers the order of its keys.
struct JSONObject: Equatable, Sendable {
    private(set) var keys: [String] = []
    private var storage: [String: JSONValue] = [:]

    init() {}

    init(_ members: [(String, JSONValue)]) {
        for (key, value) in members { self[key] = value }
    }

    subscript(key: String) -> JSONValue? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    var members: [(key: String, value: JSONValue)] {
        keys.compactMap { key in storage[key].map { (key, $0) } }
    }

    var isEmpty: Bool { keys.isEmpty }
}
