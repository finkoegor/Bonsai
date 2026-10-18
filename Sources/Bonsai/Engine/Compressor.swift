import Foundation
import PDFKit

enum Compressor {
    /// The share of the original size a result must come in under to be
    /// delivered; otherwise the original bytes are returned.
    private static let requiredRatio = 0.98

    static var isAvailable: Bool { Toolchain.shared != nil }

    private static let temporaryRoot: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Bonsai", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// A scratch directory per list item, so removing an item frees its files at once.
    static func itemWorkDir(_ id: UUID) -> URL {
        temporaryRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func cleanupTemp() {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    static func validate(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else { throw CompressionError.unreadable }
        if document.isLocked { throw CompressionError.passwordProtected }
        guard document.pageCount > 0 else { throw CompressionError.emptyDocument }
        return document
    }

    /// Compresses `url` into a new file inside `workDir`. Takes seconds on
    /// large documents; call it off the main thread.
    static func compress(_ url: URL, preset: Preset, workDir: URL? = nil) throws -> CompressionResult {
        let inputBytes = fileSize(url)
        let document = try validate(url)
        guard let tools = Toolchain.shared else { throw CompressionError.toolsMissing }

        let directory = workDir ?? temporaryRoot
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let workspace = directory.appendingPathComponent("work-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let candidate = directory.appendingPathComponent("\(UUID().uuidString).pdf")

        let optimizer = DocumentOptimizer(tools: tools, profile: preset.profile, workspace: workspace)
        if optimizer.optimize(url, into: candidate),
           let output = PDFDocument(url: candidate), !output.isLocked,
           output.pageCount == document.pageCount,
           VisualSafetyNet(qpdf: tools.qpdf).confirm(candidate, original: document, at: url, workspace: workspace) {
            let outputBytes = fileSize(candidate)
            if outputBytes > 0, Double(outputBytes) < Double(inputBytes) * requiredRatio {
                return CompressionResult(outputURL: candidate, inputBytes: inputBytes,
                                         outputBytes: outputBytes, keptOriginal: false)
            }
        }

        try? FileManager.default.removeItem(at: candidate)
        try FileManager.default.copyItem(at: url, to: candidate)
        return CompressionResult(outputURL: candidate, inputBytes: inputBytes,
                                 outputBytes: inputBytes, keptOriginal: true)
    }

    private static func fileSize(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap(Int64.init) ?? 0
    }
}
