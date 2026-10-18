import AppKit
import Observation

@Observable
final class PDFItem: Identifiable {
    enum Status: Equatable {
        case reading
        case ready
        case compressing
        case done
        case failed(String)
    }

    let id = UUID()
    let url: URL
    let name: String
    let inputBytes: Int64

    var pageCount = 0
    var thumbnail: NSImage?
    var status: Status = .reading
    var savedURL: URL?
    /// What was written to disk: the card's badge and the "after" side of the preview.
    var result: CompressionResult?
    /// The preset behind `result`. Choosing another preset makes the item
    /// pending again, so several versions of a file can be compared.
    var resultPreset: Preset?
    /// A copy of the original in the item's scratch directory. Compression
    /// reads from it, so replacing the original cannot affect a later run.
    var sourceURL: URL

    @ObservationIgnored var readTask: Task<Void, Never>?

    var tempDir: URL { Compressor.itemWorkDir(id) }

    init(url: URL) {
        self.url = url
        self.sourceURL = url
        self.name = url.deletingPathExtension().lastPathComponent
        self.inputBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap(Int64.init) ?? 0
    }
}
