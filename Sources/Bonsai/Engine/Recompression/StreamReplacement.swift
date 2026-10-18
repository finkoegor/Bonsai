import Foundation

/// A rewritten image stream: its new dictionary and the file holding its bytes.
struct StreamReplacement: Sendable {
    let dictionary: JSONObject
    let data: URL
}
