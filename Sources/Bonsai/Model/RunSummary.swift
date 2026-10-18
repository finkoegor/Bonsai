import Foundation

/// The outcome of one press of the compress button.
struct RunSummary {
    var files = 0
    var inputBytes: Int64 = 0
    var outputBytes: Int64 = 0

    var savedBytes: Int64 { max(0, inputBytes - outputBytes) }
    var savedFraction: Double { inputBytes > 0 ? Double(savedBytes) / Double(inputBytes) : 0 }
}
