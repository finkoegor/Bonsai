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
    func confirm(_ candidate: URL, original: URL, pageCount: Int, workspace: URL) -> Bool {
        guard let broken = brokenPages(of: candidate, against: original, pageCount: pageCount) else { return false }
        guard !broken.isEmpty else { return true }
        guard broken.count < pageCount,
              splice(broken, from: original, into: candidate, pageCount: pageCount, workspace: workspace),
              let remaining = brokenPages(of: candidate, against: original, pageCount: pageCount)
        else { return false }
        return remaining.isEmpty
    }

    /// Pages are rendered on several threads, each with its own copies of
    /// the two documents, since a PDFDocument must stay on one thread.
    private func brokenPages(of candidate: URL, against original: URL, pageCount: Int) -> Set<Int>? {
        let workers = max(1, min(pageCount, ProcessInfo.processInfo.activeProcessorCount))
        let lock = NSLock()
        var broken: Set<Int> = []
        var failed = false
        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            guard let before = PDFDocument(url: original), let after = PDFDocument(url: candidate),
                  before.pageCount == pageCount, after.pageCount == pageCount else {
                lock.lock()
                failed = true
                lock.unlock()
                return
            }
            for index in stride(from: worker, to: pageCount, by: workers) {
                guard let reference = before.page(at: index).flatMap({ PageSignature($0) }) else { continue }
                let rendered = after.page(at: index).flatMap { PageSignature($0) }
                if rendered.map({ reference.distance(to: $0) > Self.largestAcceptedDistance }) ?? true {
                    lock.lock()
                    broken.insert(index)
                    lock.unlock()
                }
            }
        }
        return failed ? nil : broken
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
