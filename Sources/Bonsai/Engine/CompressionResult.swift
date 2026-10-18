import Foundation

struct CompressionResult: Sendable {
    /// A temporary file holding the compressed document.
    let outputURL: URL
    let inputBytes: Int64
    let outputBytes: Int64
    /// True when compression gained too little and the output is a copy of the input.
    let keptOriginal: Bool

    var savedBytes: Int64 { max(0, inputBytes - outputBytes) }
    var savedFraction: Double { inputBytes > 0 ? Double(savedBytes) / Double(inputBytes) : 0 }
}
