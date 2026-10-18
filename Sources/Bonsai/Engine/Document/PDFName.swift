import Foundation

enum PDFName {
    /// Expands `#xx` escapes so that `/A#20B` and `/A B` compare equal.
    static func decoded(_ name: String) -> String {
        guard name.contains("#") else { return name }
        var bytes: [UInt8] = []
        var iterator = Array(name.utf8)[...]
        while let byte = iterator.popFirst() {
            if byte == UInt8(ascii: "#"), iterator.count >= 2,
               let value = UInt8(String(decoding: iterator.prefix(2), as: UTF8.self), radix: 16) {
                bytes.append(value)
                iterator = iterator.dropFirst(2)
            } else {
                bytes.append(byte)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
