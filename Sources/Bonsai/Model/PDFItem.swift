import AppKit
import Observation

@Observable
final class PDFItem: Identifiable {
    enum Status: Equatable {
        case reading
        case ready
        /// In a running batch, waiting for its turn.
        case queued
        case compressing
        case done
        case failed(String)

        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    let id = UUID()
    let url: URL
    let name: String
    let inputBytes: Int64

    var pageCount = 0
    var thumbnail: NSImage?
    var status: Status = .reading
    /// How far the compression in progress is, from 0 to 1.
    var progress = 0.0
    /// The versions on disk, oldest first, at most one per preset. Choosing
    /// a preset without a version makes the item pending again, so several
    /// versions of a file can be compared.
    var versions: [SavedVersion] = []
    /// A copy of the original in the item's scratch directory. Compression
    /// reads from it, so replacing the original cannot affect a later run.
    var sourceURL: URL

    @ObservationIgnored var readTask: Task<Void, Never>?

    var tempDir: URL { Compressor.itemWorkDir(id) }

    func version(for preset: Preset) -> SavedVersion? {
        versions.last { $0.preset == preset }
    }

    /// What the card and the preview show while `preset` is selected: its
    /// own version, or else the one made last.
    func shownVersion(for preset: Preset) -> SavedVersion? {
        version(for: preset) ?? versions.last
    }

    init(url: URL) {
        self.url = url
        self.sourceURL = url
        self.name = url.deletingPathExtension().lastPathComponent
        self.inputBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap(Int64.init) ?? 0
    }
}
