import Foundation
import SwiftUI
import PDFKit
import Observation

// MARK: - Item

@Observable
final class PDFItem: Identifiable {
    enum Status: Equatable {
        case validating          // just dropped, reading metadata
        case estimating          // background compression estimates running
        case ready               // estimates done, waiting for the big button
        case failed(String)      // unreadable / locked / broken
        case compressing         // final save in progress
        case done                // saved
    }

    let id = UUID()
    let url: URL
    let name: String
    let inputBytes: Int64

    var pageCount: Int = 0
    var thumbnail: NSImage?
    var status: Status = .validating
    /// Real (not guessed) compressed sizes per preset — produced by actually compressing
    /// into a temp file, so "Save" is instant and the numbers are exact.
    var estimates: [Preset: CompressionResult] = [:]
    var savedURL: URL?
    /// What was actually written to disk — the card's badge for .done items,
    /// stable even when the user flips presets afterwards.
    var deliveredResult: CompressionResult?
    /// Which preset produced the delivered file. Lets the user re-compress the
    /// same item with a different preset to compare versions.
    var deliveredPreset: Preset?
    /// Snapshot of the original bytes in our temp dir (APFS clone, ~free).
    /// All compression reads from here, so "Replace original" or external
    /// edits can never corrupt a later re-compression.
    var sourceURL: URL

    @ObservationIgnored var estimateTask: Task<Void, Never>?
    /// Scratch dir holding this item's estimate temp files.
    var tempDir: URL { Compressor.itemWorkDir(id) }

    init(url: URL) {
        self.url = url
        self.sourceURL = url   // swapped for the temp snapshot once it's made
        self.name = url.deletingPathExtension().lastPathComponent
        self.inputBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .flatMap(Int64.init) ?? 0
    }

    func estimate(for preset: Preset) -> CompressionResult? { estimates[preset] }

    var isBusy: Bool {
        status == .validating || status == .estimating || status == .compressing
    }
}

// MARK: - Save behavior

enum SaveMode: String, CaseIterable, Identifiable {
    case copy      // asks for a destination folder, suggests the original's one
    case replace   // original goes to Trash, compressed takes its place
    var id: String { rawValue }
    var title: String { self == .copy ? "Save a copy" : "Replace original" }
    var help: String {
        switch self {
        case .copy: "Asks where to save; the original's folder is suggested"
        case .replace: "Moves the original to the Trash and puts the compressed file in its place"
        }
    }
}

// MARK: - App state

@Observable @MainActor
final class AppState {
    static let shared = AppState()

    var items: [PDFItem] = []
    var preset: Preset = .recommended {
        didSet {
            UserDefaults.standard.set(preset.rawValue, forKey: "preset")
            // Picking another preset after a run is the "save one more version
            // and compare" flow: bring back the summary and the big button.
            if lastRun != nil {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { lastRun = nil }
            }
        }
    }
    var saveMode: SaveMode = .copy {
        didSet { UserDefaults.standard.set(saveMode.rawValue, forKey: "saveMode") }
    }
    var isCompressing = false
    /// Set after a successful run — drives the success panel.
    var lastRun: (files: Int, savedBytes: Int64)?
    var isDropTargeted = false

    /// Limits concurrent estimate jobs so a 20-file drop doesn't melt the machine.
    /// (2, not more: a single 100MB image-heavy file peaks near 600MB RSS in PDFKit.)
    @ObservationIgnored private let estimateGate = AsyncSemaphore(limit: 2)

    private init() {
        if let raw = UserDefaults.standard.string(forKey: "preset"),
           let p = Preset(rawValue: raw) { preset = p }
        if let raw = UserDefaults.standard.string(forKey: "saveMode"),
           let m = SaveMode(rawValue: raw) { saveMode = m }
    }

    // MARK: Adding files

    func addURLs(_ urls: [URL]) {
        let existing = Set(items.map { $0.url.standardizedFileURL.path })
        let fresh = urls
            .filter { $0.pathExtension.lowercased() == "pdf" }
            .filter { !existing.contains($0.standardizedFileURL.path) }
        guard !fresh.isEmpty else { return }
        lastRun = nil
        for url in fresh {
            let item = PDFItem(url: url)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                items.append(item)
            }
            startEstimating(item)
        }
    }

    func remove(_ item: PDFItem) {
        guard !isCompressing else { return }   // UI disables this too; stay airtight
        item.estimateTask?.cancel()
        let dir = item.tempDir
        Task.detached(priority: .background) { try? FileManager.default.removeItem(at: dir) }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            items.removeAll { $0.id == item.id }
        }
    }

    func clearAll() {
        guard !isCompressing else { return }
        let dirs = items.map(\.tempDir)
        items.forEach { $0.estimateTask?.cancel() }
        Task.detached(priority: .background) {
            for dir in dirs { try? FileManager.default.removeItem(at: dir) }
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            items.removeAll()
            lastRun = nil
        }
    }

    // MARK: Estimating (real compression into temp files, all presets)

    private func startEstimating(_ item: PDFItem) {
        let url = item.url
        let snapshotURL = item.tempDir.appendingPathComponent("source.pdf")
        item.estimateTask = Task { [weak item] in
            // Snapshot + metadata + thumbnail first — cheap (APFS clone),
            // makes the card feel instant.
            let meta: (pages: Int, thumb: NSImage?, snapshotted: Bool, error: String?) = await Task.detached(priority: .userInitiated) {
                do {
                    let doc = try Compressor.validate(url)
                    let page = doc.page(at: 0)
                    let thumb = page?.thumbnail(of: CGSize(width: 240, height: 240), for: .mediaBox)
                    var snapshotted = false
                    do {
                        try FileManager.default.createDirectory(at: snapshotURL.deletingLastPathComponent(),
                                                                withIntermediateDirectories: true)
                        try FileManager.default.copyItem(at: url, to: snapshotURL)
                        snapshotted = true
                    } catch { /* fall back to reading the original in place */ }
                    return (doc.pageCount, thumb, snapshotted, nil)
                } catch {
                    return (0, nil, false, error.localizedDescription)
                }
            }.value

            guard let item, !Task.isCancelled else { return }
            item.pageCount = meta.pages
            if meta.snapshotted { item.sourceURL = snapshotURL }
            withAnimation(.easeOut(duration: 0.25)) { item.thumbnail = meta.thumb }
            if let error = meta.error {
                withAnimation { item.status = .failed(error) }
                return
            }
            withAnimation { item.status = .estimating }

            // Selected preset first so the totals become real ASAP, then the others.
            var order = Preset.allCases
            if let i = order.firstIndex(of: preset) { order.swapAt(0, i) }

            for p in order {
                if Task.isCancelled { return }
                await estimateGate.wait()
                let dir = item.tempDir
                let source = item.sourceURL
                let result = await Task.detached(priority: .utility) {
                    try? Compressor.compress(source, preset: p, workDir: dir)
                }.value
                await estimateGate.signal()
                if Task.isCancelled { return }
                if let result {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        item.estimates[p] = result
                    }
                } else if item.status == .estimating {
                    // Only mark failed while still in the estimate phase — never
                    // clobber .compressing/.done set by the save flow.
                    withAnimation { item.status = .failed(CompressionError.writeFailed.errorDescription!) }
                    return
                }
            }
            if Task.isCancelled || item.status != .estimating { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { item.status = .ready }
        }
    }

    // MARK: Totals for the side panel

    /// Everything the list holds — drives the "N files · X MB" header.
    var listBytes: Int64 { items.reduce(0) { $0 + $1.inputBytes } }

    /// Items the big button will actually process: not failed, and not already
    /// saved *with the currently selected preset*. An item delivered as
    /// Recommended becomes pending again when the user switches to Low —
    /// that's how "save another version and compare" works.
    var pendingItems: [PDFItem] {
        items.filter {
            if case .failed = $0.status { return false }
            if $0.status == .done { return $0.deliveredPreset != preset }
            return true
        }
    }

    /// Total output size across all live files for a given preset — the number
    /// shown in brackets on the preset cards. nil while estimates are cooking.
    func presetTotalBytes(_ p: Preset) -> Int64? {
        let live = items.filter { if case .failed = $0.status { false } else { true } }
        guard !live.isEmpty else { return nil }
        var total: Int64 = 0
        for item in live {
            guard let e = item.estimate(for: p) else { return nil }
            total += e.outputBytes
        }
        return total
    }

    var totalInputBytes: Int64 { pendingItems.reduce(0) { $0 + $1.inputBytes } }

    /// nil while any estimate for the selected preset is still cooking.
    var totalEstimatedBytes: Int64? {
        guard !pendingItems.isEmpty else { return nil }
        var total: Int64 = 0
        for item in pendingItems {
            guard let e = item.estimate(for: preset) else { return nil }
            total += e.outputBytes
        }
        return total
    }

    var canCompress: Bool {
        // Any pending item is enough — files whose estimate isn't cached yet
        // are compressed on the spot, nobody gets silently skipped.
        !isCompressing && !pendingItems.isEmpty
    }

    // MARK: The big button

    func compressAll() {
        guard canCompress else { return }

        // "Save a copy": pick the destination folder up front, once per batch.
        // The panel opens in the first file's folder, so "same place" is one Enter away.
        var chosenDir: URL?
        if saveMode == .copy {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Save Here"
            panel.message = "Choose where to save the compressed PDFs"
            panel.directoryURL = pendingItems.first?.url.deletingLastPathComponent()
            guard panel.runModal() == .OK, let dir = panel.url else { return }
            chosenDir = dir
        }

        isCompressing = true
        lastRun = nil
        let targets = pendingItems
        let selected = preset
        let mode = saveMode
        let destDir = chosenDir
        // Estimate pipelines for other presets keep running in the background:
        // they fill the size brackets on the preset cards and make a later
        // "save another version" run instant. The shared gate keeps memory sane.
        targets.forEach { item in
            withAnimation { item.status = .compressing }
        }

        Task {
            var savedTotal: Int64 = 0
            var okCount = 0
            for item in targets {
                // The user may have removed this item while earlier files were
                // processing — never touch files the user excluded.
                guard items.contains(where: { $0.id == item.id }) else { continue }
                // Use the precomputed temp result when available (instant), else compress now.
                let result: CompressionResult?
                if let cached = item.estimate(for: selected),
                   FileManager.default.fileExists(atPath: cached.outputURL.path) {
                    result = cached
                } else {
                    let source = item.sourceURL   // snapshot: valid even after Replace
                    let dir = item.tempDir
                    await estimateGate.wait()   // same memory budget as estimates
                    result = await Task.detached(priority: .userInitiated) {
                        try? Compressor.compress(source, preset: selected, workDir: dir)
                    }.value
                    await estimateGate.signal()
                }
                guard let result else {
                    withAnimation { item.status = .failed(CompressionError.writeFailed.errorDescription!) }
                    continue
                }
                // Re-check membership after the await — removal may have landed meanwhile.
                guard items.contains(where: { $0.id == item.id }) else { continue }
                let originalURL = item.url
                do {
                    // File I/O can be seconds for huge PDFs — keep it off the main actor.
                    let dest = try await Task.detached(priority: .userInitiated) {
                        try Self.deliver(result: result, original: originalURL, mode: mode,
                                         preset: selected, destDir: destDir)
                    }.value
                    item.savedURL = dest
                    item.deliveredResult = result
                    item.deliveredPreset = selected
                    savedTotal += result.savedBytes
                    okCount += 1
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { item.status = .done }
                } catch {
                    withAnimation { item.status = .failed("Couldn't save: \(error.localizedDescription)") }
                }
            }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                isCompressing = false
                if okCount > 0 && !items.isEmpty { lastRun = (okCount, savedTotal) }
            }
        }
    }

    /// Move the compressed temp file to its final home.
    nonisolated private static func deliver(result: CompressionResult, original: URL,
                                            mode: SaveMode, preset: Preset, destDir: URL?) throws -> URL {
        let fm = FileManager.default
        switch mode {
        case .replace:
            // Stage-first so a failure can never strand the user's file:
            // 1. copy the result next to the original under a hidden name —
            //    proves space & writability while the original is untouched;
            // 2. move the original to the Trash (recoverable, as promised);
            // 3. same-volume rename of the staged file into place (no extra
            //    space needed, effectively atomic). Any failure rolls back.
            let dir = original.deletingLastPathComponent()
            let staging = dir.appendingPathComponent(".fl-\(UUID().uuidString).pdf")
            try fm.copyItem(at: result.outputURL, to: staging)
            var trashed: NSURL?
            do {
                try fm.trashItem(at: original, resultingItemURL: &trashed)
            } catch {
                try? fm.removeItem(at: staging)
                throw error
            }
            do {
                try fm.moveItem(at: staging, to: original)
            } catch {
                if let t = trashed as URL? { try? fm.moveItem(at: t, to: original) }
                try? fm.removeItem(at: staging)
                throw error
            }
            return original
        case .copy:
            // Preset in the name so several versions of one file can sit side
            // by side for comparison: "report-compressed-low.pdf" etc.
            let dir = destDir ?? original.deletingLastPathComponent()
            let base = original.deletingPathExtension().lastPathComponent
            var dest = dir.appendingPathComponent("\(base)-compressed-\(preset.rawValue).pdf")
            var n = 2
            while fm.fileExists(atPath: dest.path) {
                dest = dir.appendingPathComponent("\(base)-compressed-\(preset.rawValue) \(n).pdf")
                n += 1
            }
            try fm.copyItem(at: result.outputURL, to: dest)
            return dest
        }
    }

    func revealSaved() {
        let urls = items.compactMap(\.savedURL)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

// MARK: - Tiny async semaphore

actor AsyncSemaphore {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { available = limit }

    func wait() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            available += 1
        }
    }
}
