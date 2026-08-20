import Foundation
import PDFKit
import Quartz

/// Compression presets. Numbers tuned on real files (Tools/bench.swift, bench2.swift).
/// `low` targets visually-lossless photos; text and vectors are never rasterized
/// on any preset, and annotations, links, forms and outlines survive.
enum Preset: String, CaseIterable, Identifiable, Codable {
    case low, recommended, extreme
    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: "Low compression"
        case .recommended: "Recommended"
        case .extreme: "Extreme compression"
        }
    }
    var subtitle: String {
        switch self {
        case .low: "Highest quality, lighter file"
        case .recommended: "Great quality, great compression"
        case .extreme: "Smallest file, reduced quality"
        }
    }
    var icon: String {
        switch self {
        case .low: "gem"
        case .recommended: "balance-scale"
        case .extreme: "bolt"
        }
    }

    /// Color image target DPI, gray/mask DPI, Distiller QFactor (lower = better
    /// quality), JPEG quality for the native path (0-1), max image dimension for
    /// the native path. Calibrated on real files against the popular web compressors:
    /// on a 67 MB design export this ladder gives -43% / -73% / -84%.
    var params: (dpi: Int, maskDPI: Int, qfactor: Double, quality: Double, sizeMax: Int) {
        switch self {
        case .low: (200, 144, 0.40, 0.85, 6000)
        case .recommended: (120, 96, 1.10, 0.65, 3200)
        case .extreme: (72, 72, 1.30, 0.35, 1800)
        }
    }
}

enum CompressionError: LocalizedError {
    case unreadable
    case passwordProtected
    case emptyDocument
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .unreadable: "Can't read this PDF"
        case .passwordProtected: "Password-protected"
        case .emptyDocument: "Document has no pages"
        case .writeFailed: "Compression failed"
        }
    }
}

struct CompressionResult: Sendable {
    let outputURL: URL       // temp file with the compressed result
    let inputBytes: Int64
    let outputBytes: Int64
    /// True when compression won nothing and the output is a byte-for-byte copy of the input.
    let keptOriginal: Bool

    var savedBytes: Int64 { max(0, inputBytes - outputBytes) }
    var savedFraction: Double { inputBytes > 0 ? Double(savedBytes) / Double(inputBytes) : 0 }
}

/// Dual-backend PDF compressor.
/// Primary: Ghostscript (if installed) - handles every image class including
/// JPEG+alpha pairs that Apple's APIs refuse to recompress.
/// Fallback: native PDFKit + Quartz filter, best-of two strategies.
/// Both paths end behind the same guarantee: the output is a valid PDF with the
/// same page count, or the caller gets the original bytes back.
enum Compressor {

    // MARK: - Backends

    /// Ghostscript binary, looked up once: bundled copy first, then Homebrew.
    static let ghostscriptURL: URL? = {
        var candidates = [
            URL(fileURLWithPath: "/opt/homebrew/bin/gs"),
            URL(fileURLWithPath: "/usr/local/bin/gs"),
        ]
        if let res = Bundle.main.resourceURL {
            candidates.insert(res.appendingPathComponent("gs/gs"), at: 0)
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }()

    static var usesGhostscript: Bool { ghostscriptURL != nil }

    /// qpdf splices pages between files byte-exactly (no content rewriting) —
    /// used to swap visually-broken pages back to the original without
    /// PDFKit's re-serialization, which converts JPEGs to flate and inflates
    /// files several-fold.
    static let qpdfURL: URL? = {
        var candidates = [
            URL(fileURLWithPath: "/opt/homebrew/bin/qpdf"),
            URL(fileURLWithPath: "/usr/local/bin/qpdf"),
        ]
        if let res = Bundle.main.resourceURL {
            candidates.insert(res.appendingPathComponent("qpdf/qpdf"), at: 0)
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }()

    // MARK: - Temp layout

    private static let tempRoot: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bonsai", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Per-item scratch dir so removing an item from the list can free its
    /// estimate files immediately (not only on app quit).
    static func itemWorkDir(_ id: UUID) -> URL {
        tempRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// One .qfilter per preset for the native fallback, generated once.
    private static let filterURLs: [Preset: URL] = {
        var map: [Preset: URL] = [:]
        for preset in Preset.allCases {
            let p = preset.params
            let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
              <key>Domains</key><dict><key>Applications</key><true/></dict>
              <key>FilterData</key>
              <dict>
                <key>ColorSettings</key>
                <dict>
                  <key>ImageSettings</key>
                  <dict>
                    <key>Compression Quality</key><real>\(p.quality)</real>
                    <key>ImageCompression</key><string>ImageJPEGCompress</string>
                    <key>ImageScaleSettings</key>
                    <dict>
                      <key>ImageResolution</key><integer>\(p.dpi)</integer>
                      <key>ImageScaleInterpolate</key><true/>
                      <key>ImageSizeMax</key><integer>\(p.sizeMax)</integer>
                      <key>ImageSizeMin</key><integer>0</integer>
                    </dict>
                  </dict>
                </dict>
              </dict>
              <key>FilterType</key><integer>1</integer>
              <key>Name</key><string>Bonsai \(preset.rawValue)</string>
            </dict>
            </plist>
            """
            let url = tempRoot.appendingPathComponent("\(preset.rawValue).qfilter")
            try? xml.data(using: .utf8)!.write(to: url)
            map[preset] = url
        }
        return map
    }()

    // MARK: - Public API

    /// Validate that a file is a compressible PDF. Throws a user-facing error otherwise.
    static func validate(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw CompressionError.unreadable }
        if doc.isLocked { throw CompressionError.passwordProtected }
        guard doc.pageCount > 0 else { throw CompressionError.emptyDocument }
        return doc
    }

    /// Compress `url` with `preset` into a fresh temp file inside `workDir`
    /// (defaults to the shared temp root). Slow (seconds for big files),
    /// call off the main thread.
    static func compress(_ url: URL, preset: Preset, workDir: URL? = nil) throws -> CompressionResult {
        let inputBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap(Int64.init) ?? 0
        let doc = try validate(url)
        let pages = doc.pageCount

        let dir = workDir ?? tempRoot
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var best: URL?
        var bestSize = Int64.max

        func consider(_ candidate: URL?) {
            guard let candidate,
                  let size = (try? candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap(Int64.init)
            else { return }
            if size < bestSize, isValidPDF(candidate, expectedPages: pages) {
                if let old = best { try? FileManager.default.removeItem(at: old) }
                best = candidate
                bestSize = size
            } else {
                try? FileManager.default.removeItem(at: candidate)
            }
        }

        // 1. Ghostscript: the strong path. Its output is checked page-by-page
        //    against the original with Apple's renderer: pdfwrite re-serializes
        //    soft-masked vector shadings (mesh gradients from design tools) in a
        //    form Ghostscript itself renders fine but Preview/PDFKit renders as
        //    flat or black fills. Visually broken pages are reverted to the
        //    original page bytes; they are vector-heavy and cost almost nothing.
        if let gs = ghostscriptURL {
            if let out = runGhostscript(gs, input: url, preset: preset, dir: dir) {
                // pdfwrite emits `h` (closepath) with no current point. Apple's
                // renderer shrugs; spec-strict ones (poppler, Telegram's viewer)
                // abort the whole page and show it blank. Strip the no-op.
                repairDegenerateClosepaths(out, dir: dir)
                if revertVisuallyBrokenPages(original: doc, originalURL: url, outputURL: out, dir: dir) {
                    consider(out)
                } else {
                    try? FileManager.default.removeItem(at: out)
                }
            }
        }

        // 2. Native path, only if Ghostscript is absent or lost badly.
        //    (On JPEG+alpha files the Quartz filter can inflate 6x; the size
        //    comparison in consider() quietly discards such results.)
        if best == nil || bestSize >= Int64(Double(inputBytes) * 0.90) {
            consider(nativeQuartzFilter(doc, preset: preset, dir: dir))
        }
        if best == nil || bestSize >= Int64(Double(inputBytes) * 0.90) {
            consider(nativePDFKitOptions(doc, dir: dir))
        }

        // Never inflate, never deliver a dubious file: if nothing beat the
        // original by at least 2%, ship the original bytes back.
        if best == nil || bestSize >= Int64(Double(inputBytes) * 0.98) {
            if let b = best { try? FileManager.default.removeItem(at: b) }
            let copy = dir.appendingPathComponent(UUID().uuidString + ".pdf")
            try FileManager.default.copyItem(at: url, to: copy)
            return CompressionResult(outputURL: copy, inputBytes: inputBytes,
                                     outputBytes: inputBytes, keptOriginal: true)
        }

        return CompressionResult(outputURL: best!, inputBytes: inputBytes,
                                 outputBytes: bestSize, keptOriginal: false)
    }

    /// Remove everything we ever wrote to the temp dir (called on quit).
    static func cleanupTemp() {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - Backend: Ghostscript

    private static func runGhostscript(_ gs: URL, input: URL, preset: Preset, dir: URL) -> URL? {
        let p = preset.params
        let out = dir.appendingPathComponent(UUID().uuidString + ".pdf")
        let monoDPI = max(300, p.dpi * 3)

        // QFactor drives DCT quality (lower = better). AutoFilter off so our
        // settings actually apply; PassThroughJPEGImages off so existing JPEGs
        // (including alpha pairs) are re-encoded instead of copied through.
        let distiller = """
        << /ColorACSImageDict << /QFactor \(p.qfactor) /Blend 1 /HSamples [2 1 1 2] /VSamples [2 1 1 2] >> \
        /ColorImageDict << /QFactor \(p.qfactor) /Blend 1 /HSamples [2 1 1 2] /VSamples [2 1 1 2] >> \
        /GrayACSImageDict << /QFactor \(p.qfactor) /Blend 1 /HSamples [2 1 1 2] /VSamples [2 1 1 2] >> \
        /GrayImageDict << /QFactor \(p.qfactor) /Blend 1 /HSamples [2 1 1 2] /VSamples [2 1 1 2] >> >> setdistillerparams
        """

        let proc = Process()
        proc.executableURL = gs
        proc.arguments = [
            "-sDEVICE=pdfwrite",
            "-dCompatibilityLevel=1.7",
            "-dNOPAUSE", "-dBATCH", "-dQUIET",
            "-dAutoRotatePages=/None",
            "-dDetectDuplicateImages=true",
            "-dCompressFonts=true", "-dSubsetFonts=true",
            "-dPassThroughJPEGImages=false",
            "-dAutoFilterColorImages=false", "-dAutoFilterGrayImages=false",
            "-dColorImageFilter=/DCTEncode", "-dGrayImageFilter=/DCTEncode",
            "-dDownsampleColorImages=true",
            "-dColorImageDownsampleType=/Bicubic",
            "-dColorImageResolution=\(p.dpi)",
            "-dColorImageDownsampleThreshold=1.0",
            "-dDownsampleGrayImages=true",
            "-dGrayImageDownsampleType=/Bicubic",
            "-dGrayImageResolution=\(p.maskDPI)",
            "-dGrayImageDownsampleThreshold=1.0",
            "-dDownsampleMonoImages=true",
            "-dMonoImageDownsampleType=/Subsample",
            "-dMonoImageResolution=\(monoDPI)",
            "-o", out.path,
            "-c", distiller,
            "-f", input.path,
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            return nil
        }
        // Watchdog: a wedged Ghostscript must not hang the queue forever.
        let watchdog = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 600, execute: watchdog)
        proc.waitUntilExit()
        watchdog.cancel()

        guard proc.terminationStatus == 0,
              FileManager.default.fileExists(atPath: out.path) else {
            try? FileManager.default.removeItem(at: out)
            return nil
        }
        return out
    }

    // MARK: - Backend: native fallbacks

    private static func nativeQuartzFilter(_ doc: PDFDocument, preset: Preset, dir: URL) -> URL? {
        guard let filterURL = filterURLs[preset], let filter = QuartzFilter(url: filterURL) else { return nil }
        let out = dir.appendingPathComponent(UUID().uuidString + ".pdf")
        let opts = [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter] as [PDFDocumentWriteOption: Any]
        guard doc.write(to: out, withOptions: opts) else {
            try? FileManager.default.removeItem(at: out)
            return nil
        }
        return out
    }

    private static func nativePDFKitOptions(_ doc: PDFDocument, dir: URL) -> URL? {
        let out = dir.appendingPathComponent(UUID().uuidString + ".pdf")
        let opts: [PDFDocumentWriteOption: Any] = [
            .saveImagesAsJPEGOption: true,
            .optimizeImagesForScreenOption: true,
        ]
        guard doc.write(to: out, withOptions: opts) else {
            try? FileManager.default.removeItem(at: out)
            return nil
        }
        return out
    }

    // MARK: - Validation

    private static func isValidPDF(_ url: URL, expectedPages: Int) -> Bool {
        guard let doc = PDFDocument(url: url) else { return false }
        return doc.pageCount == expectedPages
    }

    // MARK: - Content-stream repair

    /// Ghostscript's pdfwrite writes `h` (closepath) between a painting op and
    /// the next `m` — an operator that is illegal without a current point.
    /// Removing it changes nothing semantically (closing an empty path), but
    /// keeps strict renderers from dropping the page. Needs qpdf: the file is
    /// unpacked to QDF, single `h` tokens with no open subpath are blanked
    /// byte-for-byte (stream lengths stay valid), then repacked.
    private static func repairDegenerateClosepaths(_ pdf: URL, dir: URL) {
        guard let qpdf = qpdfURL else { return }
        let qdf = dir.appendingPathComponent(UUID().uuidString + "-qdf.pdf")
        let packed = dir.appendingPathComponent(UUID().uuidString + "-fixed.pdf")
        defer {
            try? FileManager.default.removeItem(at: qdf)
            try? FileManager.default.removeItem(at: packed)
        }

        guard runQpdf(qpdf, ["--qdf", "--object-streams=disable", pdf.path, qdf.path]),
              var bytes = try? [UInt8](Data(contentsOf: qdf)) else { return }

        var fixed = 0
        var searchFrom = 0
        let streamMark = [UInt8]("stream".utf8), endMark = [UInt8]("endstream".utf8)
        while let start = find(streamMark, in: bytes, from: searchFrom) {
            var bodyStart = start + streamMark.count
            if bodyStart < bytes.count, bytes[bodyStart] == 0x0D { bodyStart += 1 }
            if bodyStart < bytes.count, bytes[bodyStart] == 0x0A { bodyStart += 1 }
            guard let end = find(endMark, in: bytes, from: bodyStart) else { break }
            searchFrom = end + endMark.count
            fixed += stripBareClosepaths(&bytes, from: bodyStart, to: end)
        }
        guard fixed > 0 else { return }

        guard (try? Data(bytes).write(to: qdf)) != nil,
              runQpdf(qpdf, ["--object-streams=generate", "--compress-streams=y",
                             "--recompress-flate", qdf.path, packed.path]),
              FileManager.default.fileExists(atPath: packed.path) else { return }
        _ = try? FileManager.default.replaceItemAt(pdf, withItemAt: packed)
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8], from: Int) -> Int? {
        guard !needle.isEmpty, from + needle.count <= hay.count else { return nil }
        var i = from
        let limit = hay.count - needle.count
        while i <= limit {
            if hay[i] == needle[0] {
                var j = 1
                while j < needle.count, hay[i + j] == needle[j] { j += 1 }
                if j == needle.count { return i }
            }
            i += 1
        }
        return nil
    }

    /// Lexes one stream body (only if it looks like ASCII operators), tracking
    /// whether a subpath is open; a lone `h` with no current point is blanked.
    /// Strings, hex strings, comments and inline images are skipped verbatim.
    private static func stripBareClosepaths(_ bytes: inout [UInt8], from: Int, to end: Int) -> Int {
        // content streams are overwhelmingly printable; image data is not
        let sampleEnd = min(from + 4096, end)
        guard sampleEnd > from else { return 0 }
        var printable = 0
        for i in from..<sampleEnd {
            let b = bytes[i]
            if (32..<127).contains(b) || b == 9 || b == 10 || b == 13 { printable += 1 }
        }
        guard Double(printable) / Double(sampleEnd - from) >= 0.9 else { return 0 }

        func isDelim(_ b: UInt8) -> Bool {
            switch b {
            case 0, 9, 10, 12, 13, 32, 0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D,
                 0x7B, 0x7D, 0x2F, 0x25: return true
            default: return false
            }
        }

        var i = from
        var hasPoint = false
        var fixed = 0
        while i < end {
            let b = bytes[i]
            if b == 0x25 {                       // % comment
                while i < end, bytes[i] != 0x0A, bytes[i] != 0x0D { i += 1 }
                continue
            }
            if b == 0x28 {                       // ( literal string
                var depth = 1
                i += 1
                while i < end, depth > 0 {
                    let c = bytes[i]
                    if c == 0x5C { i += 2; continue }
                    if c == 0x28 { depth += 1 } else if c == 0x29 { depth -= 1 }
                    i += 1
                }
                continue
            }
            if b == 0x3C {                       // <hex> or << dict
                if i + 1 < end, bytes[i + 1] == 0x3C { i += 2; continue }
                while i < end, bytes[i] != 0x3E { i += 1 }
                i += 1
                continue
            }
            if isDelim(b) { i += 1; continue }

            let tokStart = i
            while i < end, !isDelim(bytes[i]) { i += 1 }
            let len = i - tokStart

            if len == 2, bytes[tokStart] == 0x42, bytes[tokStart + 1] == 0x49 {
                // BI ... ID <binary> EI — skip the whole inline image
                while i < end {
                    if bytes[i] == 0x45, i + 1 < end, bytes[i + 1] == 0x49,
                       isDelim(bytes[i - 1]), i + 2 >= end || isDelim(bytes[i + 2]) {
                        i += 2
                        break
                    }
                    i += 1
                }
                continue
            }

            if len == 1 {
                switch bytes[tokStart] {
                case 0x6D, 0x6C, 0x63, 0x76, 0x79:        // m l c v y
                    hasPoint = true
                case 0x66, 0x46, 0x53, 0x73, 0x6E, 0x62, 0x42:  // f F S s n b B
                    hasPoint = false
                case 0x68:                                 // h
                    if !hasPoint {
                        bytes[tokStart] = 0x20
                        fixed += 1
                    }
                default: break
                }
            } else if len == 2 {
                let a = bytes[tokStart], c = bytes[tokStart + 1]
                if a == 0x72, c == 0x65 { hasPoint = true }             // re
                else if c == 0x2A, a == 0x66 || a == 0x42 || a == 0x62 { // f* B* b*
                    hasPoint = false
                }
            }
        }
        return fixed
    }

    private static func runQpdf(_ qpdf: URL, _ args: [String]) -> Bool {
        let proc = Process()
        proc.executableURL = qpdf
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return false }
        let watchdog = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 300, execute: watchdog)
        proc.waitUntilExit()
        watchdog.cancel()
        // qpdf exits 3 on warnings but still writes valid output
        return proc.terminationStatus == 0 || proc.terminationStatus == 3
    }

    // MARK: - Visual safety net

    /// Compares every page of the compressed output against the original using
    /// the same renderer the user's Mac uses (PDFKit). Pages whose 5x5 tile
    /// color means shift beyond `tileDeltaThreshold` are structurally broken
    /// (calibrated: legit compression stays under 10 even at Extreme, a broken
    /// gradient scores 120+) and get replaced with the original page.
    /// Returns false when the output can't be repaired; caller discards it.
    private static let tileDeltaThreshold = 48.0

    private static func revertVisuallyBrokenPages(original: PDFDocument, originalURL: URL,
                                                  outputURL: URL, dir: URL) -> Bool {
        guard let out = PDFDocument(url: outputURL),
              out.pageCount == original.pageCount else { return false }

        func brokenPages(_ candidate: PDFDocument) -> [Int]? {
            var broken: [Int] = []
            for i in 0..<original.pageCount {
                guard let a = original.page(at: i), let b = candidate.page(at: i) else { return nil }
                if maxTileDelta(a, b) > tileDeltaThreshold { broken.append(i) }
            }
            return broken
        }

        guard let broken = brokenPages(out) else { return false }
        if broken.isEmpty { return true }

        // Preferred: splice with qpdf — byte-exact page copies, no inflation.
        if let qpdf = qpdfURL,
           spliceWithQpdf(qpdf, compressed: outputURL, original: originalURL,
                          brokenPages: Set(broken), pageCount: original.pageCount, dir: dir) {
            // fallthrough to re-verification below
        } else {
            // Fallback: PDFKit page swap. Correct, but its re-serialization can
            // inflate the file badly — consider() will then pick a better candidate.
            for i in broken {
                guard let copy = original.page(at: i)?.copy() as? PDFPage else { return false }
                out.removePage(at: i)
                out.insert(copy, at: i)
            }
            guard out.write(to: outputURL) else { return false }
        }

        // Re-verify the patched file end-to-end: nothing may remain (or become) broken.
        guard let final = PDFDocument(url: outputURL),
              final.pageCount == original.pageCount,
              let stillBroken = brokenPages(final) else { return false }
        return stillBroken.isEmpty
    }

    /// qpdf <compressed> --pages <compressed> goodRun <original> brokenRun ... -- out
    /// Builds interleaved page runs so document order is preserved.
    private static func spliceWithQpdf(_ qpdf: URL, compressed: URL, original: URL,
                                       brokenPages: Set<Int>, pageCount: Int, dir: URL) -> Bool {
        var args = [compressed.path, "--pages"]
        var i = 0
        while i < pageCount {
            let fromOriginal = brokenPages.contains(i)
            var j = i
            while j + 1 < pageCount && brokenPages.contains(j + 1) == fromOriginal { j += 1 }
            let range = i == j ? "\(i + 1)" : "\(i + 1)-\(j + 1)"
            args.append((fromOriginal ? original : compressed).path)
            args.append(range)
            i = j + 1
        }
        let spliced = dir.appendingPathComponent(UUID().uuidString + ".pdf")
        args.append(contentsOf: ["--", spliced.path])

        let proc = Process()
        proc.executableURL = qpdf
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return false }
        let watchdog = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 300, execute: watchdog)
        proc.waitUntilExit()
        watchdog.cancel()

        guard proc.terminationStatus == 0,
              FileManager.default.fileExists(atPath: spliced.path) else {
            try? FileManager.default.removeItem(at: spliced)
            return false
        }
        do {
            _ = try FileManager.default.replaceItemAt(compressed, withItemAt: spliced)
            return true
        } catch {
            try? FileManager.default.removeItem(at: spliced)
            return false
        }
    }

    /// Max absolute difference between 5x5 tile color means of two page renders.
    private static func maxTileDelta(_ a: PDFPage, _ b: PDFPage) -> Double {
        guard let ta = tileMeans(a), let tb = tileMeans(b), ta.count == tb.count else {
            return .infinity   // unrenderable page: treat as broken
        }
        var m = 0.0
        for i in 0..<ta.count { m = max(m, abs(ta[i] - tb[i])) }
        return m
    }

    private static func tileMeans(_ page: PDFPage, width: Int = 160, grid: Int = 5) -> [Double]? {
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let h = max(grid, Int(CGFloat(width) * bounds.height / bounds.width))
        var buf = [UInt8](repeating: 255, count: width * h * 4)
        guard let ctx = CGContext(data: &buf, width: width, height: h, bitsPerComponent: 8,
                                  bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: h))
        ctx.scaleBy(x: CGFloat(width) / bounds.width, y: CGFloat(h) / bounds.height)
        ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .cropBox, to: ctx)
        var out = [Double]()
        out.reserveCapacity(grid * grid * 3)
        for ty in 0..<grid {
            for tx in 0..<grid {
                let x0 = tx * width / grid, x1 = max(x0 + 1, (tx + 1) * width / grid)
                let y0 = ty * h / grid, y1 = max(y0 + 1, (ty + 1) * h / grid)
                var r = 0.0, g = 0.0, bl = 0.0, n = 0.0
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        let i = (y * width + x) * 4
                        r += Double(buf[i]); g += Double(buf[i + 1]); bl += Double(buf[i + 2]); n += 1
                    }
                }
                out.append(r / n); out.append(g / n); out.append(bl / n)
            }
        }
        return out
    }
}
