import Foundation

/// A JSON value as emitted by `qpdf --json`. Numbers keep their literal text,
/// so values handed back to qpdf carry exactly what it wrote.
enum JSONValue: Equatable, Sendable {
    case object(JSONObject)
    case array([JSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null
}
