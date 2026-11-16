import Foundation

/// What one preset saved across the files of the list.
struct ListSummary {
    var files = 0
    var inputBytes: Int64 = 0
    var outputBytes: Int64 = 0

    var savedBytes: Int64 { max(0, inputBytes - outputBytes) }
    var savedFraction: Double { inputBytes > 0 ? Double(savedBytes) / Double(inputBytes) : 0 }
}
