import Foundation

/// A rewritten stream: its new dictionary and the file holding its new
/// bytes. Without a file the bytes stay as they are and only the dictionary
/// changes.
struct StreamReplacement: Sendable {
    let dictionary: JSONObject
    let data: URL?
}
