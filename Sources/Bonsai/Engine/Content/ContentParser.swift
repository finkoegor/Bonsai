import CoreGraphics
import Foundation

/// Tokenizes a content stream and keeps the operators listed in
/// `ContentOperation`. Strings, arrays, dictionaries and inline image data
/// are skipped without being interpreted.
struct ContentParser {
    struct Result: Sendable {
        let operations: [ContentOperation]
        /// False when the stream could not be followed to its end, for
        /// example an inline image without a recognizable end.
        let isComplete: Bool
    }

    private enum Operand {
        case number(Double)
        case name(String)
        case keyword(String)
        case other
    }

    private let bytes: [UInt8]
    private var index = 0
    private var operands: [Operand] = []
    private var operations: [ContentOperation] = []
    private var isComplete = true

    static func parse(_ data: Data) -> Result {
        var parser = ContentParser(bytes: [UInt8](data))
        parser.run()
        return Result(operations: parser.operations, isComplete: parser.isComplete)
    }

    private init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    private mutating func run() {
        while index < bytes.count {
            guard let operand = nextOperandOrOperator() else { continue }
            if case .keyword(let word) = operand, !["true", "false", "null"].contains(word) {
                apply(word)
                operands.removeAll(keepingCapacity: true)
            } else {
                operands.append(operand)
            }
        }
    }

    /// Reads one token. Returns nil for whitespace and comments.
    private mutating func nextOperandOrOperator() -> Operand? {
        let byte = bytes[index]
        if Self.isWhitespace(byte) {
            index += 1
            return nil
        }
        switch byte {
        case UInt8(ascii: "%"):
            while index < bytes.count, bytes[index] != 0x0A, bytes[index] != 0x0D { index += 1 }
            return nil
        case UInt8(ascii: "("):
            skipLiteralString()
            return .other
        case UInt8(ascii: "<"):
            if index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "<") {
                skipDictionary()
            } else {
                while index < bytes.count, bytes[index] != UInt8(ascii: ">") { index += 1 }
                index += 1
            }
            return .other
        case UInt8(ascii: "["):
            skipArray()
            return .other
        case UInt8(ascii: "/"):
            index += 1
            return .name("/" + readRegular())
        case UInt8(ascii: ")"), UInt8(ascii: ">"), UInt8(ascii: "]"), UInt8(ascii: "{"), UInt8(ascii: "}"):
            index += 1
            return nil
        default:
            let token = readRegular()
            if token.isEmpty {
                index += 1
                return nil
            }
            if let first = token.utf8.first,
               first == UInt8(ascii: "+") || first == UInt8(ascii: "-") || first == UInt8(ascii: ".")
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(first) {
                return Double(token).map { .number($0) } ?? .other
            }
            return .keyword(token)
        }
    }

    private mutating func apply(_ word: String) {
        switch word {
        case "q":
            operations.append(.save)
        case "Q":
            operations.append(.restore)
        case "cm":
            let numbers = operands.suffix(6).compactMap { operand -> CGFloat? in
                if case .number(let value) = operand { return CGFloat(value) }
                return nil
            }
            if numbers.count == 6 {
                operations.append(.concatenate(CGAffineTransform(a: numbers[0], b: numbers[1], c: numbers[2],
                                                                 d: numbers[3], tx: numbers[4], ty: numbers[5])))
            }
        case "Do":
            if case .name(let name)? = operands.last { operations.append(.paint(name)) }
        case "gs":
            if case .name(let name)? = operands.last { operations.append(.applyState(name)) }
        case "BI":
            skipInlineImage()
        default:
            break
        }
    }

    // MARK: Skipping

    private mutating func readRegular() -> String {
        let start = index
        while index < bytes.count, !Self.isWhitespace(bytes[index]), !Self.isDelimiter(bytes[index]) {
            index += 1
        }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    private mutating func skipLiteralString() {
        var depth = 0
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: "\\"): index += 1
            case UInt8(ascii: "("): depth += 1
            case UInt8(ascii: ")"):
                depth -= 1
                if depth == 0 { index += 1; return }
            default: break
            }
            index += 1
        }
    }

    private mutating func skipArray() {
        index += 1
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "]") { index += 1; return }
            _ = nextOperandOrOperator()
        }
    }

    private mutating func skipDictionary() {
        index += 2
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: ">"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: ">") {
                index += 2
                return
            }
            _ = nextOperandOrOperator()
        }
    }

    /// `BI <entries> ID <data> EI`. The data length is computed when the
    /// image is unfiltered; otherwise the data ends at the first `EI`
    /// standing between whitespace.
    private mutating func skipInlineImage() {
        var entries: [Operand] = []
        while index < bytes.count {
            guard let operand = nextOperandOrOperator() else { continue }
            if case .keyword("ID") = operand { break }
            entries.append(operand)
        }
        guard index < bytes.count else {
            isComplete = false
            return
        }
        if Self.isWhitespace(bytes[index]) { index += 1 }
        let dataStart = index

        if let length = Self.unfilteredLength(of: entries) {
            var end = dataStart + length
            while end < bytes.count, Self.isWhitespace(bytes[end]) { end += 1 }
            if end + 1 < bytes.count, bytes[end] == UInt8(ascii: "E"), bytes[end + 1] == UInt8(ascii: "I"),
               end + 2 == bytes.count || Self.isWhitespace(bytes[end + 2]) || Self.isDelimiter(bytes[end + 2]) {
                index = end + 2
                return
            }
        }

        var cursor = dataStart
        while cursor + 1 < bytes.count {
            if bytes[cursor] == UInt8(ascii: "E"), bytes[cursor + 1] == UInt8(ascii: "I"),
               cursor == dataStart || Self.isWhitespace(bytes[cursor - 1]),
               cursor + 2 == bytes.count || Self.isWhitespace(bytes[cursor + 2]) || Self.isDelimiter(bytes[cursor + 2]) {
                index = cursor + 2
                return
            }
            cursor += 1
        }
        isComplete = false
        index = bytes.count
    }

    private static func unfilteredLength(of entries: [Operand]) -> Int? {
        var values: [String: Operand] = [:]
        var position = 0
        while position + 1 < entries.count {
            if case .name(let key) = entries[position] { values[key] = entries[position + 1] }
            position += 2
        }
        if values["/F"] != nil || values["/Filter"] != nil { return nil }

        func number(_ keys: String...) -> Int? {
            for key in keys {
                if case .number(let value)? = values[key] { return Int(value) }
            }
            return nil
        }
        guard let width = number("/W", "/Width"), let height = number("/H", "/Height") else { return nil }

        var components = 0
        var bits = number("/BPC", "/BitsPerComponent") ?? 0
        if case .keyword("true")? = values["/IM"] ?? values["/ImageMask"] {
            components = 1
            bits = 1
        } else if case .name(let space)? = values["/CS"] ?? values["/ColorSpace"] {
            switch space {
            case "/G", "/DeviceGray", "/I", "/Indexed": components = 1
            case "/RGB", "/DeviceRGB": components = 3
            case "/CMYK", "/DeviceCMYK": components = 4
            default: return nil
            }
        }
        guard components > 0, bits > 0 else { return nil }
        return height * ((width * components * bits + 7) / 8)
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 || byte == 0x0C || byte == 0x00
    }

    private static func isDelimiter(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "<"), UInt8(ascii: ">"),
             UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: "{"), UInt8(ascii: "}"),
             UInt8(ascii: "/"), UInt8(ascii: "%"):
            return true
        default:
            return false
        }
    }
}
