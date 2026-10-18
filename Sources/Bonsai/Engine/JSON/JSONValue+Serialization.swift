import Foundation

extension JSONValue {
    var serialized: String {
        var text = ""
        write(into: &text)
        return text
    }

    func write(into text: inout String) {
        switch self {
        case .object(let object):
            text += "{"
            for (offset, member) in object.members.enumerated() {
                if offset > 0 { text += "," }
                Self.writeString(member.key, into: &text)
                text += ":"
                member.value.write(into: &text)
            }
            text += "}"
        case .array(let array):
            text += "["
            for (offset, element) in array.enumerated() {
                if offset > 0 { text += "," }
                element.write(into: &text)
            }
            text += "]"
        case .string(let string):
            Self.writeString(string, into: &text)
        case .number(let literal):
            text += literal
        case .bool(let flag):
            text += flag ? "true" : "false"
        case .null:
            text += "null"
        }
    }

    private static func writeString(_ string: String, into text: inout String) {
        text += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": text += "\\\""
            case "\\": text += "\\\\"
            case "\n": text += "\\n"
            case "\r": text += "\\r"
            case "\t": text += "\\t"
            default:
                if scalar.value < 0x20 {
                    text += String(format: "\\u%04x", scalar.value)
                } else {
                    text.unicodeScalars.append(scalar)
                }
            }
        }
        text += "\""
    }
}
