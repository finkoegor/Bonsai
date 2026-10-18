import Foundation
import PDFKit

/// Renders every page of the compressed file next to the original. Pages
/// that drift visibly are copied back from the original with qpdf, which
/// transfers pages without touching their content.
struct VisualSafetyNet {
    let qpdf: ExternalTool

    /// Tile averages move by a few levels when images are re-encoded, even
    /// at Extreme. A page that fails to draw or loses an image moves far more.
    private static let largestAcceptedDistance = 24.0

    /// Returns false when the candidate cannot be trusted even after repair.
    func confirm(_ candidate: URL, original document: PDFDocument, at originalURL: URL,
                 workspace: URL) -> Bool {
        guard let compressed = PDFDocument(url: candidate),
              let broken = brokenPages(of: compressed, against: document) else { return false }
        guard !broken.isEmpty else { return true }
        guard broken.count < document.pageCount,
              splice(broken, from: originalURL, into: candidate, pageCount: document.pageCount,
                     workspace: workspace),
              let repaired = PDFDocument(url: candidate),
              let remaining = brokenPages(of: repaired, against: document) else { return false }
        return remaining.isEmpty
    }

    private func brokenPages(of candidate: PDFDocument, against original: PDFDocument) -> Set<Int>? {
        guard candidate.pageCount == original.pageCount else { return nil }
        var broken: Set<Int> = []
        for index in 0..<original.pageCount {
            guard let before = original.page(at: index).flatMap({ PageSignature($0) }) else { continue }
            let after = candidate.page(at: index).flatMap { PageSignature($0) }
            if after.map({ before.distance(to: $0) > Self.largestAcceptedDistance }) ?? true {
                broken.insert(index)
            }
        }
        return broken
    }

    /// `qpdf candidate --pages candidate 1-3 original 4 candidate 5-9 -- out`
    private func splice(_ pages: Set<Int>, from original: URL, into candidate: URL, pageCount: Int,
                        workspace: URL) -> Bool {
        var arguments = [candidate.path, "--pages"]
        var start = 0
        while start < pageCount {
            let fromOriginal = pages.contains(start)
            var end = start
            while end + 1 < pageCount, pages.contains(end + 1) == fromOriginal { end += 1 }
            arguments.append((fromOriginal ? original : candidate).path)
            arguments.append(start == end ? "\(start + 1)" : "\(start + 1)-\(end + 1)")
            start = end + 1
        }
        let spliced = workspace.appendingPathComponent("spliced.pdf")
        arguments += ["--", spliced.path]
        guard let status = qpdf.run(arguments), status == 0 || status == 3,
              (try? FileManager.default.replaceItemAt(candidate, withItemAt: spliced)) != nil else { return false }
        return true
    }
}
