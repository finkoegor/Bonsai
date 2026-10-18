import Foundation

/// Reading PDF values in qpdf's JSON encoding: names are strings starting
/// with `/`, indirect references are strings such as `12 0 R`.
extension JSONValue {
    var object: JSONObject? {
        if case .object(let object) = self { return object }
        return nil
    }

    var array: [JSONValue]? {
        if case .array(let array) = self { return array }
        return nil
    }

    var name: String? {
        if case .string(let string) = self, string.hasPrefix("/") { return string }
        return nil
    }

    /// The object number of an indirect reference.
    var reference: Int? {
        guard case .string(let string) = self, string.hasSuffix(" R") else { return nil }
        let parts = string.split(separator: " ")
        guard parts.count == 3, let number = Int(parts[0]), Int(parts[1]) != nil else { return nil }
        return number
    }

    var number: Double? {
        if case .number(let literal) = self { return Double(literal) }
        return nil
    }

    var integer: Int? {
        guard let number, number.rounded() == number, abs(number) < 1e12 else { return nil }
        return Int(number)
    }

    var boolean: Bool? {
        if case .bool(let flag) = self { return flag }
        return nil
    }

    /// Filter names of a /Filter entry, which may be a name or an array.
    var filterNames: [String] {
        if let name { return [name] }
        return array?.compactMap(\.name) ?? []
    }

    static func name(_ name: String) -> JSONValue { .string(name) }

    static func integer(_ value: Int) -> JSONValue { .number(String(value)) }

    static func reference(_ number: Int, generation: Int) -> JSONValue {
        .string("\(number) \(generation) R")
    }
}
