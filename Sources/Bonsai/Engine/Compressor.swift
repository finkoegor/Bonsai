import Foundation
import CryptoKit
import PDFKit
import Quartz
import ImageIO
import UniformTypeIdentifiers

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
        func elog(_ s: String) {
            guard let path = ProcessInfo.processInfo.environment["BONSAI_ENGINE_LOG"] else { return }
            let line = "[\(preset.rawValue)] \(s)\n"
            if let h = FileHandle(forWritingAtPath: path) {
                h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
            } else {
                try? line.write(toFile: path, atomically: false, encoding: .utf8)
            }
        }

        // Transparency-heavy sources: never let Ghostscript rewrite the page
        // structure (renders fine on macOS, blanks out on iOS viewers).
        // Surgically recompress only the image bytes instead.
        let transparent = hasTransparency(doc)
        if transparent {
            if let surgical = surgicalCompress(url, preset: preset, dir: dir) {
                var surgicalReverted = 0
                if revertVisuallyBrokenPages(original: doc, originalURL: url, outputURL: surgical,
                                             dir: dir, revertedCount: &surgicalReverted) {
                    elog("surgical ok, reverted \(surgicalReverted)/\(pages)")
                    consider(surgical)
                } else {
                    elog("surgical net FAILED")
                    try? FileManager.default.removeItem(at: surgical)
                }
            } else {
                elog("surgical returned nil")
            }
        }

        // Transparency files never take the gs paths at all: the structural
        // rewrite blanks pages on iOS, and flattening rasterizes text. If the
        // surgical pass produced nothing, the never-inflate guard below ships
        // the original bytes back - an honest "nothing to win here".

        if let gs = ghostscriptURL, !transparent {
            var revertedPages = 0
            if let out = runGhostscript(gs, input: url, preset: preset, dir: dir) {
                // pdfwrite emits `h` (closepath) with no current point. Apple's
                // renderer shrugs; spec-strict ones (poppler, Telegram's viewer)
                // abort the whole page and show it blank. Strip the no-op.
                repairDegenerateClosepaths(out, dir: dir)
                if revertVisuallyBrokenPages(original: doc, originalURL: url, outputURL: out,
                                             dir: dir, revertedCount: &revertedPages) {
                    elog("normal gs ok, reverted \(revertedPages)/\(pages)")
                    consider(out)
                } else {
                    revertedPages = pages   // unusable output: treat as fully broken
                    elog("normal gs net FAILED")
                    try? FileManager.default.removeItem(at: out)
                }
            } else {
                elog("normal gs returned nil")
            }

            // Rescue tier for transparency-heavy design exports: when pdfwrite's
            // normal output breaks Apple's renderer on most pages, the safety net
            // reverts them and no real compression happens. Flattening (PDF 1.3)
            // rasterizes the transparent composites at the preset's DPI while
            // text outside transparency groups stays vector, and the result
            // renders identically in every viewer, including mobile ones.
            // Flatten when the source leans on transparency (soft-masked images,
            // transparency groups): pdfwrite's rewrite of those constructs renders
            // fine in macOS Preview yet blanks out on iOS renderers (Telegram and
            // friends), which we cannot detect locally. Flattened output is plain
            // raster + vector text and renders identically everywhere; consider()
            // still picks the smaller valid candidate.
            if transparent || revertedPages * 2 > pages {
                elog("rescue: flattening")
                if let flat = runGhostscript(gs, input: url, preset: preset, dir: dir, flatten: true) {
                    repairDegenerateClosepaths(flat, dir: dir)
                    var flatReverted = 0
                    if revertVisuallyBrokenPages(original: doc, originalURL: url, outputURL: flat,
                                                 dir: dir, revertedCount: &flatReverted) {
                        let sz = (try? flat.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
                        elog("rescue ok, reverted \(flatReverted)/\(pages), size \(sz)")
                        consider(flat)
                    } else {
                        elog("rescue net FAILED")
                        try? FileManager.default.removeItem(at: flat)
                    }
                } else {
                    elog("rescue gs returned nil")
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

    private static func runGhostscript(_ gs: URL, input: URL, preset: Preset,
                                       dir: URL, flatten: Bool = false) -> URL? {
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
        // Flatten mode targets PDF 1.3: no transparency allowed, so gs
        // rasterizes transparent composites at -r DPI. Text outside
        // transparency groups stays vector.
        var args = [
            "-sDEVICE=pdfwrite",
            flatten ? "-dCompatibilityLevel=1.3" : "-dCompatibilityLevel=1.7",
        ]
        if flatten { args.append("-r\(p.dpi)") }
        proc.arguments = args + [
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

    // MARK: - Surgical image-only compression
    // For transparency-heavy sources (Figma/Sketch/Keynote exports) any
    // Ghostscript rewrite of the page structure renders fine on macOS but
    // blanks out on iOS viewers (Telegram and friends). So for those files we
    // never let gs touch the structure at all: the file is unpacked to QDF,
    // oversized DCT (JPEG) image streams are decoded, downsampled and
    // re-encoded in place, fix-qdf recomputes offsets/lengths, and qpdf packs
    // the result. Everything else - vectors, text, transparency, structure -
    // stays byte-identical, so it renders exactly like the original everywhere.

    /// Knobs of the surgical path (JPEG qualities on the libjpeg 0-100 scale).
    /// Low/Recommended never resize: pixel dimensions stay as exported (like
    /// the web compressors do) and the win comes purely from re-encoding with
    /// mozjpeg. Only Extreme trades resolution for size.
    ///
    /// Soft masks are the other half of a design export: smooth alpha ramps
    /// stored as Flate, often bigger than the photos they belong to, and JPEG
    /// encodes them almost losslessly. `maskTolerance` is the largest alpha
    /// deviation (out of 255) a re-encoded mask may show at any pixel; hard
    /// edged cutouts ring far beyond it and keep their original bytes.
    private struct SurgicalParams {
        var maxDim: Int
        var quality: Int
        var maskQuality: Int
        var maskTolerance: Int
    }

    private static func surgicalParams(_ preset: Preset) -> SurgicalParams {
        switch preset {
        case .low: SurgicalParams(maxDim: 8192, quality: 82, maskQuality: 95, maskTolerance: 4)
        case .recommended: SurgicalParams(maxDim: 8192, quality: 70, maskQuality: 85, maskTolerance: 8)
        case .extreme: SurgicalParams(maxDim: 2800, quality: 55, maskQuality: 75, maskTolerance: 8)
        }
    }

    /// mozjpeg tools (brew install mozjpeg): dramatically better JPEG encoding
    /// than ImageIO. Optional; the ImageIO path remains as fallback.
    private static let mozjpegBin: URL? = {
        for p in ["/opt/homebrew/opt/mozjpeg/bin", "/usr/local/opt/mozjpeg/bin"] {
            let url = URL(fileURLWithPath: p)
            if FileManager.default.isExecutableFile(atPath: url.appendingPathComponent("cjpeg").path),
               FileManager.default.isExecutableFile(atPath: url.appendingPathComponent("djpeg").path) {
                return url
            }
        }
        return nil
    }()

    private static func surgicalCompress(_ url: URL, preset: Preset, dir: URL) -> URL? {
        guard let qpdf = qpdfURL else { return nil }
        let fixQdf = qpdf.deletingLastPathComponent().appendingPathComponent("fix-qdf")
        guard FileManager.default.isExecutableFile(atPath: fixQdf.path) else { return nil }

        let qdf = dir.appendingPathComponent(UUID().uuidString + "-sq.pdf")
        let edited = dir.appendingPathComponent(UUID().uuidString + "-se.pdf")
        let fixed = dir.appendingPathComponent(UUID().uuidString + "-sf.pdf")
        let out = dir.appendingPathComponent(UUID().uuidString + ".pdf")
        defer {
            for f in [qdf, edited, fixed] { try? FileManager.default.removeItem(at: f) }
        }

        guard runQpdf(qpdf, ["--qdf", "--object-streams=disable", url.path, qdf.path]),
              let data = try? Data(contentsOf: qdf) else { return nil }

        // Duplicates first, so the image pass never spends time on copies
        // that qpdf drops anyway. Dedupe only touches references, which keeps
        // the QDF /Length objects truthful for the image pass that follows.
        var working = data
        var touched = false
        var orphans = Set<Int>()
        if let deduped = dedupeImages(working) {
            working = deduped.data
            orphans = deduped.orphans
            touched = true
        }
        if let rewritten = rewriteImages(working, params: surgicalParams(preset), skipping: orphans) {
            working = rewritten
            touched = true
        }
        guard touched else {
            // Nothing worth re-encoding (images already tight). The container
            // pass alone still helps: qpdf drops unreferenced export junk and
            // packs object streams; page content stays byte-identical.
            return runQpdf(qpdf, ["--object-streams=generate", "--compress-streams=y",
                                  url.path, out.path]) ? out : nil
        }
        guard (try? working.write(to: edited)) != nil else { return nil }

        // fix-qdf reads the edited file and regenerates xref offsets and the
        // indirect /Length objects our replacements invalidated.
        let proc = Process()
        proc.executableURL = fixQdf
        proc.arguments = [edited.path]
        FileManager.default.createFile(atPath: fixed.path, contents: nil)
        guard let outHandle = try? FileHandle(forWritingTo: fixed) else { return nil }
        proc.standardOutput = outHandle
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        try? outHandle.close()
        guard proc.terminationStatus == 0 else { return nil }

        guard runQpdf(qpdf, ["--object-streams=generate", "--compress-streams=y", fixed.path, out.path]),
              FileManager.default.fileExists(atPath: out.path) else { return nil }
        return out
    }

    /// One `N 0 obj` of a QDF buffer: where its dictionary text sits and, for
    /// streams, the exact payload bytes (`/Length` long).
    private struct QdfObject {
        var number: Int
        var dictRange: Range<Int>
        var payloadRange: Range<Int>?
    }

    /// Walks the objects of a QDF buffer in file order. Stream payloads are
    /// skipped wholesale, so binary data is never mistaken for syntax.
    private static func qdfObjects(_ bytes: [UInt8]) -> [QdfObject] {
        var objects: [QdfObject] = []
        let objMark = [UInt8](" 0 obj".utf8)
        let streamKw = [UInt8]("stream".utf8)
        let endobjKw = [UInt8]("endobj".utf8)
        var cursor = 0
        while let objAt = find(objMark, in: bytes, from: cursor) {
            cursor = objAt + objMark.count
            var digits = objAt
            while digits > 0, (0x30...0x39).contains(bytes[digits - 1]) { digits -= 1 }
            guard digits < objAt, digits == 0 || bytes[digits - 1] == 0x0A,
                  let number = Int(String(decoding: bytes[digits..<objAt], as: UTF8.self)),
                  let endobjAt = find(endobjKw, in: bytes, from: cursor) else { continue }
            guard let streamAt = find(streamKw, in: bytes, from: cursor, before: endobjAt) else {
                objects.append(QdfObject(number: number, dictRange: cursor..<endobjAt, payloadRange: nil))
                cursor = endobjAt + endobjKw.count
                continue
            }
            var payloadStart = streamAt + streamKw.count
            if payloadStart < bytes.count, bytes[payloadStart] == 0x0D { payloadStart += 1 }
            if payloadStart < bytes.count, bytes[payloadStart] == 0x0A { payloadStart += 1 }
            let dictRange = cursor..<streamAt
            guard let dict = String(bytes: bytes[dictRange], encoding: .isoLatin1),
                  let lengthRef = intValue(after: "/Length ", in: dict),
                  let length = resolveIndirectLength(dict: dict, ref: lengthRef, in: bytes, near: payloadStart),
                  payloadStart + length <= bytes.count else {
                cursor = endobjAt + endobjKw.count
                continue
            }
            objects.append(QdfObject(number: number, dictRange: dictRange,
                                     payloadRange: payloadStart..<(payloadStart + length)))
            cursor = payloadStart + length
        }
        return objects
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8], from: Int, before end: Int) -> Int? {
        let limit = min(end, hay.count) - needle.count
        guard !needle.isEmpty, from <= limit else { return nil }
        var i = from
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

    private static let softMaskRef = try! NSRegularExpression(pattern: "/SMask ([0-9]+) 0 R")
    private static let anyRef = try! NSRegularExpression(pattern: "(?<![0-9])([0-9]+) 0 R")

    /// Object numbers used as somebody's /SMask.
    private static func softMaskNumbers(_ objects: [QdfObject], in bytes: [UInt8]) -> Set<Int> {
        var numbers = Set<Int>()
        for obj in objects {
            guard let dict = String(bytes: bytes[obj.dictRange], encoding: .isoLatin1),
                  dict.contains("/SMask ") else { continue }
            let ns = dict as NSString
            for m in softMaskRef.matches(in: dict, range: NSRange(location: 0, length: ns.length)) {
                if let n = Int(ns.substring(with: m.range(at: 1))) { numbers.insert(n) }
            }
        }
        return numbers
    }

    /// Design tools export the same bitmap once per page it appears on, as
    /// separate objects. Identical image streams (same dictionary, same bytes)
    /// collapse onto their first copy by rewriting references; qpdf drops the
    /// now unreferenced copies when it packs the file. Masks collapse in the
    /// first round, the images that pointed at them in the next.
    /// Returns nil when there were no duplicates.
    private static func dedupeImages(_ data: Data) -> (data: Data, orphans: Set<Int>)? {
        var working = data
        var orphans = Set<Int>()
        for _ in 0..<3 {
            let bytes = [UInt8](working)
            let objects = qdfObjects(bytes)
            var canonical: [String: Int] = [:]
            var alias: [Int: Int] = [:]
            for obj in objects {
                guard let payloadRange = obj.payloadRange, !orphans.contains(obj.number),
                      let dict = String(bytes: bytes[obj.dictRange], encoding: .isoLatin1),
                      dict.contains("/Subtype /Image") else { continue }
                let key = imageIdentity(dict: dict, payload: bytes[payloadRange])
                if let first = canonical[key] {
                    alias[obj.number] = first
                } else {
                    canonical[key] = obj.number
                }
            }
            guard !alias.isEmpty else { break }
            working = rewriteReferences(working, objects: objects, alias: alias)
            orphans.formUnion(alias.keys)
        }
        return orphans.isEmpty ? nil : (working, orphans)
    }

    /// Dictionary without its (per-object) /Length entry plus a digest of the bytes.
    private static func imageIdentity(dict: String, payload: ArraySlice<UInt8>) -> String {
        let shape = dict.split(separator: "\n").filter { !$0.hasPrefix("  /Length ") }.joined(separator: "\n")
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        return shape + digest
    }

    private static func rewriteReferences(_ data: Data, objects: [QdfObject], alias: [Int: Int]) -> Data {
        var result = Data(capacity: data.count)
        var pos = 0
        for obj in objects {
            guard let dict = String(data: data.subdata(in: obj.dictRange), encoding: .isoLatin1),
                  dict.contains(" 0 R") else { continue }
            let ns = dict as NSString
            var patched = ""
            var last = 0
            for m in anyRef.matches(in: dict, range: NSRange(location: 0, length: ns.length)) {
                guard let n = Int(ns.substring(with: m.range(at: 1))), let to = alias[n] else { continue }
                patched += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                patched += "\(to) 0 R"
                last = m.range.location + m.range.length
            }
            guard last > 0 else { continue }
            patched += ns.substring(from: last)
            result.append(data.subdata(in: pos..<obj.dictRange.lowerBound))
            result.append(patched.data(using: .isoLatin1)!)
            pos = obj.dictRange.upperBound
        }
        result.append(data.subdata(in: pos..<data.count))
        return result
    }

    /// Re-encodes image streams of a QDF buffer in place: JPEG payloads at the
    /// preset's quality (resized only above the cap), soft masks as JPEG when
    /// the round trip stays within the preset's alpha tolerance. Everything
    /// else in the file is copied byte for byte. Returns nil when nothing
    /// changed.
    private static func rewriteImages(_ data: Data, params p: SurgicalParams, skipping orphans: Set<Int>) -> Data? {
        let bytes = [UInt8](data)
        let objects = qdfObjects(bytes)
        let maskNumbers = softMaskNumbers(objects, in: bytes)
        var result = Data(capacity: data.count)
        var pos = 0
        var replaced = 0

        for obj in objects {
            guard let payloadRange = obj.payloadRange, !orphans.contains(obj.number),
                  payloadRange.count >= 50_000,   // not worth a re-encode round trip
                  let dict = String(bytes: bytes[obj.dictRange], encoding: .isoLatin1),
                  dict.contains("/Subtype /Image"),
                  !dict.contains("/ImageMask true"),
                  let w = intValue(after: "/Width ", in: dict),
                  let h = intValue(after: "/Height ", in: dict) else { continue }
            let length = payloadRange.count
            let payload = data.subdata(in: payloadRange)
            let isMask = maskNumbers.contains(obj.number)
            var newDict = dict
            let smaller: Data

            if dict.contains("/DCTDecode"), !dict.contains("/FlateDecode") {
                // Pure JPEG payload (DCT alone, as a name or a one-element
                // array). Never upscale; resize only above the cap. Keep the
                // replacement only when it wins meaningfully, so already
                // tight JPEGs survive.
                let target = min(p.maxDim, max(w, h))
                guard let r = reencodeJPEG(payload, srcMax: max(w, h), maxDim: target,
                                           quality: isMask ? p.maskQuality : p.quality,
                                           tolerance: isMask ? p.maskTolerance : nil),
                      r.jpeg.count < Int(Double(length) * 0.92) else { continue }
                newDict = newDict.replacingOccurrences(of: "/Width \(w)", with: "/Width \(r.width)")
                newDict = newDict.replacingOccurrences(of: "/Height \(h)", with: "/Height \(r.height)")
                smaller = r.jpeg
            } else if isMask, !dict.contains("/Filter"), !dict.contains("/DecodeParms"),
                      dict.contains("/DeviceGray"), dict.contains("/BitsPerComponent 8"),
                      length == w * h {
                // A Flate mask, inflated by qpdf to raw pixels. Its real cost
                // is the deflated size, so that is what the JPEG must beat.
                guard let moz = mozjpegBin,
                      let deflated = try? (payload as NSData).compressed(using: .zlib),
                      let jpeg = encodeGray(moz, pixels: payload, width: w, height: h,
                                            quality: p.maskQuality, tolerance: p.maskTolerance),
                      jpeg.count < Int(Double(deflated.count) * 0.92),
                      let close = newDict.range(of: ">>", options: .backwards) else { continue }
                newDict.insert(contentsOf: "  /Filter /DCTDecode\n", at: close.lowerBound)
                smaller = jpeg
            } else {
                continue
            }

            // copy everything up to the object dict, then the patched object
            result.append(data.subdata(in: pos..<obj.dictRange.lowerBound))
            result.append(newDict.data(using: .isoLatin1)!)
            result.append(Data("stream\n".utf8))
            result.append(smaller)
            pos = payloadRange.upperBound
            replaced += 1
        }
        guard replaced > 0 else { return nil }
        result.append(data.subdata(in: pos..<data.count))
        return result
    }

    private static func intValue(after key: String, in dict: String) -> Int? {
        guard let r = dict.range(of: key) else { return nil }
        let tail = dict[r.upperBound...]
        let digits = tail.prefix { $0.isNumber }
        return Int(digits)
    }

    /// QDF stores stream lengths as indirect objects: `/Length N 0 R` with
    /// `N 0 obj <int> endobj` right after the stream, which is where `near`
    /// points. Returns the int, or the ref itself when the length happened to
    /// be direct.
    private static func resolveIndirectLength(dict: String, ref: Int, in bytes: [UInt8], near: Int) -> Int? {
        guard dict.contains("/Length \(ref) 0 R") else { return ref }   // direct length
        let marker = [UInt8]("\n\(ref) 0 obj".utf8)
        guard let at = find(marker, in: bytes, from: near) ?? find(marker, in: bytes, from: 0) else { return nil }
        var i = at + marker.count
        while i < bytes.count, bytes[i] == 0x0A || bytes[i] == 0x0D || bytes[i] == 0x20 { i += 1 }
        var value = 0
        var any = false
        while i < bytes.count, (0x30...0x39).contains(bytes[i]) {
            value = value * 10 + Int(bytes[i] - 0x30)
            any = true
            i += 1
        }
        return any ? value : nil
    }

    private struct Reencoded {
        var jpeg: Data
        var width: Int
        var height: Int
    }

    /// Re-encode a JPEG payload with mozjpeg when available (far better
    /// rate/quality than ImageIO), falling back to the ImageIO path. With a
    /// `tolerance` the result must stay within that many levels of its source
    /// at every pixel (soft masks); that check needs mozjpeg's decoder.
    private static func reencodeJPEG(_ payload: Data, srcMax: Int, maxDim: Int,
                                     quality: Int, tolerance: Int?) -> Reencoded? {
        if let moz = mozjpegBin {
            return mozjpegReencode(moz, payload, srcMax: srcMax, maxDim: maxDim,
                                   quality: quality, tolerance: tolerance)
        }
        guard tolerance == nil,
              let (data, w, h) = downsampledJPEG(payload, maxDim: maxDim, quality: CGFloat(quality) / 100.0)
        else { return nil }
        return Reencoded(jpeg: data, width: w, height: h)
    }

    /// djpeg [-scale n/8] -pnm | cjpeg -quality q -optimize
    private static func mozjpegReencode(_ bin: URL, _ payload: Data, srcMax: Int, maxDim: Int,
                                        quality: Int, tolerance: Int?) -> Reencoded? {
        let fm = FileManager.default
        let tmp = tempRoot.appendingPathComponent("moz-\(UUID().uuidString)")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let inJpg = tmp.appendingPathComponent("in.jpg")
        let pnm = tmp.appendingPathComponent("raw.pnm")
        let outJpg = tmp.appendingPathComponent("out.jpg")
        guard (try? payload.write(to: inJpg)) != nil else { return nil }

        var dargs = ["-pnm"]
        if srcMax > maxDim {
            // djpeg scales in eighths during decode: pick the largest n/8 <= cap
            let n = max(1, min(8, (maxDim * 8) / srcMax))
            dargs += ["-scale", "\(n)/8"]
        }
        guard runTool(bin.appendingPathComponent("djpeg"), dargs + [inJpg.path], stdout: pnm),
              runTool(bin.appendingPathComponent("cjpeg"),
                      ["-quality", "\(quality)", "-optimize", pnm.path], stdout: outJpg),
              let out = try? Data(contentsOf: outJpg), !out.isEmpty,
              let header = try? FileHandle(forReadingFrom: pnm).read(upToCount: 64)
        else { return nil }
        // PNM header: P5|P6 <w> <h> <max>
        let parts = String(decoding: header, as: UTF8.self)
            .split(whereSeparator: { $0.isWhitespace }).prefix(3)
        guard parts.count == 3, let nw = Int(parts[1]), let nh = Int(parts[2]) else { return nil }
        if let tolerance {
            guard let source = try? Data(contentsOf: pnm),
                  roundTrip(of: outJpg, stays: tolerance, from: source, bin: bin, dir: tmp) else { return nil }
        }
        return Reencoded(jpeg: out, width: nw, height: nh)
    }

    /// cjpeg over raw 8-bit gray pixels; nil unless the round trip stays
    /// within `tolerance` at every pixel.
    private static func encodeGray(_ bin: URL, pixels: Data, width: Int, height: Int,
                                   quality: Int, tolerance: Int) -> Data? {
        let fm = FileManager.default
        let tmp = tempRoot.appendingPathComponent("moz-\(UUID().uuidString)")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let pnm = tmp.appendingPathComponent("raw.pnm")
        let outJpg = tmp.appendingPathComponent("out.jpg")
        var source = Data("P5\n\(width) \(height)\n255\n".utf8)
        source.append(pixels)
        guard (try? source.write(to: pnm)) != nil,
              runTool(bin.appendingPathComponent("cjpeg"),
                      ["-quality", "\(quality)", "-optimize", "-grayscale", pnm.path], stdout: outJpg),
              let out = try? Data(contentsOf: outJpg), !out.isEmpty,
              roundTrip(of: outJpg, stays: tolerance, from: source, bin: bin, dir: tmp) else { return nil }
        return out
    }

    /// Decodes `jpeg` again and compares it pixel by pixel with the PNM it
    /// was encoded from.
    private static func roundTrip(of jpeg: URL, stays tolerance: Int, from source: Data,
                                  bin: URL, dir: URL) -> Bool {
        let back = dir.appendingPathComponent("back.pnm")
        guard runTool(bin.appendingPathComponent("djpeg"), ["-pnm", jpeg.path], stdout: back),
              let decoded = try? Data(contentsOf: back),
              let a = pnmPixelOffset(source), let b = pnmPixelOffset(decoded),
              source.count - a == decoded.count - b else { return false }
        let n = source.count - a
        return source.withUnsafeBytes { ps in
            decoded.withUnsafeBytes { pd in
                let x = ps.bindMemory(to: UInt8.self)
                let y = pd.bindMemory(to: UInt8.self)
                var i = 0
                while i < n {
                    if abs(Int(x[a + i]) - Int(y[b + i])) > tolerance { return false }
                    i += 1
                }
                return true
            }
        }
    }

    /// Offset of the pixel bytes in a binary PNM: magic, width, height,
    /// maxval, then exactly one whitespace byte.
    private static func pnmPixelOffset(_ data: Data) -> Int? {
        let head = [UInt8](data.prefix(64))
        func space(_ b: UInt8) -> Bool { b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 }
        var i = 0
        for _ in 0..<4 {
            while i < head.count, space(head[i]) { i += 1 }
            guard i < head.count else { return nil }
            while i < head.count, !space(head[i]) { i += 1 }
        }
        guard i < head.count, space(head[i]) else { return nil }
        return i + 1
    }

    private static func runTool(_ tool: URL, _ args: [String], stdout: URL) -> Bool {
        FileManager.default.createFile(atPath: stdout.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: stdout) else { return false }
        let proc = Process()
        proc.executableURL = tool
        proc.arguments = args
        proc.standardOutput = h
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return false }
        proc.waitUntilExit()
        try? h.close()
        return proc.terminationStatus == 0
    }

    /// Decode a JPEG payload, downsample so the longest side is `maxDim`,
    /// re-encode. Returns the bytes plus the actual pixel size, or nil for
    /// anything unusual (CMYK, undecodable).
    private static func downsampledJPEG(_ payload: Data, maxDim: Int,
                                        quality: CGFloat) -> (Data, Int, Int)? {
        guard let src = CGImageSourceCreateWithData(payload as CFData, nil),
              CGImageSourceGetCount(src) >= 1 else { return nil }
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let model = props[kCGImagePropertyColorModel] as? String,
           model == (kCGImagePropertyColorModelCMYK as String) {
            return nil
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDim,
            kCGImageSourceCreateThumbnailWithTransform: false,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let outData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(outData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (outData as Data, img.width, img.height)
    }

    /// True when any of the first pages carries a transparency group or a
    /// soft-masked image — the constructs whose pdfwrite rewrite breaks
    /// iOS renderers.
    private static func hasTransparency(_ doc: PDFDocument) -> Bool {
        guard let cg = doc.documentRef else { return false }
        let pageLimit = min(cg.numberOfPages, 20)
        guard pageLimit >= 1 else { return false }
        for i in 1...pageLimit {
            guard let page = cg.page(at: i), let dict = page.dictionary else { continue }
            var group: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(dict, "Group", &group) { return true }
            var res: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(dict, "Resources", &res), let res,
               resourcesHaveTransparency(res, depth: 0) {
                return true
            }
        }
        return false
    }

    private static func resourcesHaveTransparency(_ res: CGPDFDictionaryRef, depth: Int) -> Bool {
        guard depth < 4 else { return false }
        var xobj: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(res, "XObject", &xobj), let xobj else { return false }
        final class Ctx { var found = false; var depth = 0 }
        let ctx = Ctx()
        ctx.depth = depth
        CGPDFDictionaryApplyBlock(xobj, { _, value, info in
            let ctx = Unmanaged<Ctx>.fromOpaque(info!).takeUnretainedValue()
            if ctx.found { return false }
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(value, .stream, &stream), let stream,
                  let sdict = CGPDFStreamGetDictionary(stream) else { return true }
            var smask: CGPDFStreamRef?
            if CGPDFDictionaryGetStream(sdict, "SMask", &smask) { ctx.found = true; return false }
            var group: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(sdict, "Group", &group) { ctx.found = true; return false }
            var inner: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(sdict, "Resources", &inner), let inner,
               resourcesHaveTransparency(inner, depth: ctx.depth + 1) {
                ctx.found = true
                return false
            }
            return true
        }, Unmanaged.passUnretained(ctx).toOpaque())
        return ctx.found
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
                                                  outputURL: URL, dir: URL,
                                                  revertedCount: inout Int) -> Bool {
        revertedCount = 0
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
        revertedCount = broken.count
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
