import Foundation

enum Format {
    private static let bytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static func size(_ byteCount: Int64) -> String {
        bytes.string(fromByteCount: byteCount)
    }

    /// Rounds down, so 99.6% reads as 99% rather than an impossible 100%.
    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded(.down)))%"
    }
}
