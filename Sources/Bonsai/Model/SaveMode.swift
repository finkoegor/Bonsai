import Foundation

enum SaveMode: String, CaseIterable, Identifiable {
    case copy
    case replace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .copy: "Save a copy"
        case .replace: "Replace original"
        }
    }

    var help: String {
        switch self {
        case .copy: "Asks where to save; the original's folder is suggested"
        case .replace: "Moves the original to the Trash and puts the compressed file in its place"
        }
    }
}
