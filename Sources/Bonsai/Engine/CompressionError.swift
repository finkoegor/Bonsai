import Foundation

enum CompressionError: LocalizedError {
    case unreadable
    case passwordProtected
    case emptyDocument
    case toolsMissing
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .unreadable: "Can't read this PDF"
        case .passwordProtected: "Password-protected"
        case .emptyDocument: "Document has no pages"
        case .toolsMissing: "Needs qpdf and mozjpeg"
        case .writeFailed: "Compression failed"
        }
    }
}
