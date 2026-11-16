import Foundation

/// Rewrites the real numbers of a content stream with fewer digits. Design
/// tools write every coordinate with six decimals, a precision of a
/// millionth of a point that no screen or printer resolves. Numbers keep six
/// decimals below 1, five below 10 and four from there on, so nothing moves
/// by more than 0.00005 units and scale factors keep their relative
/// precision. Every other byte of the stream is copied as it is.
enum ContentNumberShortener {
    /// Returns nil when nothing gets shorter, or when the stream holds an
    /// inline image, whose binary data cannot be told from operators with
    /// certainty.
    static func shorten(_ content: Data) -> Data? {
        let input = [UInt8](content)
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        var index = 0
        /// Nesting of arrays and dictionaries, whose numbers stay as written.
        var depth = 0

        while index < input.count {
            let byte = input[index]
            switch byte {
            case UInt8(ascii: "%"):
                while index < input.count, input[index] != 0x0A, input[index] != 0x0D {
                    output.append(input[index])
                    index += 1
                }
            case UInt8(ascii: "("):
                var nesting = 0
                while index < input.count {
                    let character = input[index]
                    output.append(character)
                    index += 1
                    if character == UInt8(ascii: "\\"), index < input.count {
                        output.append(input[index])
                        index += 1
                    } else if character == UInt8(ascii: "(") {
                        nesting += 1
                    } else if character == UInt8(ascii: ")") {
                        nesting -= 1
                        if nesting == 0 { break }
                    }
                }
            case UInt8(ascii: "<"):
                if index + 1 < input.count, input[index + 1] == UInt8(ascii: "<") {
                    depth += 1
                    output.append(contentsOf: [byte, byte])
                    index += 2
                } else {
                    while index < input.count {
                        output.append(input[index])
                        index += 1
                        if input[index - 1] == UInt8(ascii: ">") { break }
                    }
                }
            case UInt8(ascii: ">"):
                if index + 1 < input.count, input[index + 1] == UInt8(ascii: ">") {
                    depth = max(0, depth - 1)
                    output.append(contentsOf: [byte, byte])
                    index += 2
                } else {
                    output.append(byte)
                    index += 1
                }
            case UInt8(ascii: "["):
                depth += 1
                output.append(byte)
                index += 1
            case UInt8(ascii: "]"):
                depth = max(0, depth - 1)
                output.append(byte)
                index += 1
            case UInt8(ascii: "/"):
                output.append(byte)
                index += 1
                while index < input.count, isRegular(input[index]) {
                    output.append(input[index])
                    index += 1
                }
            default:
                guard isRegular(byte) else {
                    output.append(byte)
                    index += 1
                    continue
                }
                let start = index
                while index < input.count, isRegular(input[index]) { index += 1 }
                let token = input[start..<index]
                if depth == 0, token.elementsEqual([UInt8(ascii: "B"), UInt8(ascii: "I")]) { return nil }
                if depth == 0, let shorter = shortened(token) {
                    output.append(contentsOf: shorter)
                } else {
                    output.append(contentsOf: token)
                }
            }
        }
        return output.count < input.count ? Data(output) : nil
    }

    /// A shorter spelling of a real number, nil when the token is not one or
    /// is already as short as it gets.
    private static func shortened(_ token: ArraySlice<UInt8>) -> [UInt8]? {
        var digits = token
        var isNegative = false
        if let sign = digits.first, sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") {
            isNegative = sign == UInt8(ascii: "-")
            digits = digits.dropFirst()
        }
        guard let point = digits.firstIndex(of: UInt8(ascii: ".")) else { return nil }
        var whole = Array(digits[digits.startIndex..<point].drop { $0 == UInt8(ascii: "0") })
        var fraction = Array(digits[(point + 1)...])
        guard digits.count > 1, (whole + fraction).allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) })
        else { return nil }

        let decimals = whole.isEmpty ? 6 : whole.count == 1 ? 5 : 4
        if fraction.count > decimals {
            let roundsUp = fraction[decimals] >= UInt8(ascii: "5")
            fraction.removeSubrange(decimals...)
            if roundsUp {
                var all = whole + fraction
                var position = all.count - 1
                while position >= 0 {
                    if all[position] == UInt8(ascii: "9") {
                        all[position] = UInt8(ascii: "0")
                        position -= 1
                    } else {
                        all[position] += 1
                        break
                    }
                }
                if position < 0 { all.insert(UInt8(ascii: "1"), at: 0) }
                whole = Array(all.dropLast(decimals))
                fraction = Array(all.suffix(decimals))
            }
        }
        while fraction.last == UInt8(ascii: "0") { fraction.removeLast() }

        var result: [UInt8] = []
        if isNegative, !(whole.isEmpty && fraction.isEmpty) { result.append(UInt8(ascii: "-")) }
        result.append(contentsOf: whole.isEmpty ? [UInt8(ascii: "0")] : whole)
        if !fraction.isEmpty {
            result.append(UInt8(ascii: "."))
            result.append(contentsOf: fraction)
        }
        return result.count < token.count ? result : nil
    }

    /// True for bytes that make up numbers, operators and names: everything
    /// except whitespace and delimiters.
    private static func isRegular(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x00, 0x09, 0x0A, 0x0C, 0x0D, 0x20,
             UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "<"), UInt8(ascii: ">"),
             UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: "{"), UInt8(ascii: "}"),
             UInt8(ascii: "/"), UInt8(ascii: "%"):
            return false
        default:
            return true
        }
    }
}
