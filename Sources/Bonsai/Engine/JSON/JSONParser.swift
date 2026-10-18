import Foundation

/// Parses JSON text into `JSONValue`, keeping number literals as written.
struct JSONParser {
    struct Failure: Error {
        let offset: Int
    }

    private let bytes: [UInt8]
    private var index = 0

    static func parse(_ data: Data) throws -> JSONValue {
        var parser = JSONParser(bytes: [UInt8](data))
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw Failure(offset: parser.index) }
        return value
    }

    private init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    private mutating func parseValue() throws -> JSONValue {
        skipWhitespace()
        guard index < bytes.count else { throw Failure(offset: index) }
        switch bytes[index] {
        case UInt8(ascii: "{"): return .object(try parseObject())
        case UInt8(ascii: "["): return .array(try parseArray())
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try consume("true"); return .bool(true)
        case UInt8(ascii: "f"): try consume("false"); return .bool(false)
        case UInt8(ascii: "n"): try consume("null"); return .null
        default: return .number(try parseNumber())
        }
    }

    private mutating func parseObject() throws -> JSONObject {
        index += 1
        var object = JSONObject()
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
            return object
        }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw Failure(offset: index) }
            let key = try parseString()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw Failure(offset: index) }
            index += 1
            object[key] = try parseValue()
            skipWhitespace()
            guard index < bytes.count else { throw Failure(offset: index) }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            guard bytes[index] == UInt8(ascii: "}") else { throw Failure(offset: index) }
            index += 1
            return object
        }
    }

    private mutating func parseArray() throws -> [JSONValue] {
        index += 1
        var array: [JSONValue] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
            index += 1
            return array
        }
        while true {
            array.append(try parseValue())
            skipWhitespace()
            guard index < bytes.count else { throw Failure(offset: index) }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            guard bytes[index] == UInt8(ascii: "]") else { throw Failure(offset: index) }
            index += 1
            return array
        }
    }

    private mutating func parseString() throws -> String {
        index += 1
        var utf8: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            switch byte {
            case UInt8(ascii: "\""):
                return String(decoding: utf8, as: UTF8.self)
            case UInt8(ascii: "\\"):
                guard index < bytes.count else { throw Failure(offset: index) }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): utf8.append(escape)
                case UInt8(ascii: "b"): utf8.append(0x08)
                case UInt8(ascii: "f"): utf8.append(0x0C)
                case UInt8(ascii: "n"): utf8.append(0x0A)
                case UInt8(ascii: "r"): utf8.append(0x0D)
                case UInt8(ascii: "t"): utf8.append(0x09)
                case UInt8(ascii: "u"): utf8.append(contentsOf: try parseUnicodeEscape())
                default: throw Failure(offset: index)
                }
            default:
                utf8.append(byte)
            }
        }
        throw Failure(offset: index)
    }

    /// Reads the hex digits after `\u`, joining surrogate pairs.
    private mutating func parseUnicodeEscape() throws -> [UInt8] {
        var code = try parseHexQuad()
        if (0xD800..<0xDC00).contains(code), index + 1 < bytes.count,
           bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
            index += 2
            let low = try parseHexQuad()
            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
        }
        let scalar = Unicode.Scalar(code) ?? "\u{FFFD}"
        return Array(String(Character(scalar)).utf8)
    }

    private mutating func parseHexQuad() throws -> UInt32 {
        guard index + 4 <= bytes.count,
              let value = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16)
        else { throw Failure(offset: index) }
        index += 4
        return value
    }

    private mutating func parseNumber() throws -> String {
        let start = index
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "+"),
                 UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"):
                index += 1
            default:
                guard index > start else { throw Failure(offset: index) }
                return String(decoding: bytes[start..<index], as: UTF8.self)
            }
        }
        guard index > start else { throw Failure(offset: index) }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    private mutating func consume(_ literal: String) throws {
        let expected = Array(literal.utf8)
        guard index + expected.count <= bytes.count,
              Array(bytes[index..<index + expected.count]) == expected else { throw Failure(offset: index) }
        index += expected.count
    }
}
