import Foundation
import SwiftUI
import PDFKit
import Observation

// MARK: - Item

@Observable
final class PDFItem: Identifiable {
    enum Status: Equatable {
        case reading             // just dropped, reading metadata
        case ready               // waiting for the big button
        case compressing
        case done                // saved
        case failed(String)      // unreadable / locked / broken / couldn't save
    }

    let id = UUID()
    let url: URL
    let name: String
    let inputBytes: Int64

    var pageCount: Int = 0
    var thumbnail: NSImage?
    var status: Status = .reading
    var savedURL: URL?
    /// What was actually written to disk: the card's badge and the "after"
    /// side of the preview.
    var result: CompressionResult?
    /// Which preset produced it. Picking another preset afterwards makes the
    /// item pending again, so several versions of one file can be compared.
    var resultPreset: Preset?
    /// Snapshot of the original bytes in our temp dir (APFS clone, ~free).
    /// Compression reads from here, so "Replace original" or external edits
    /// can never corrupt a later run.
    var sourceURL: URL

    @ObservationIgnored var readTask: Task<Void, Never>?
    /// Scratch dir holding this item's snapshot and compressed files.
    var tempDir: URL { Compressor.itemWorkDir(id) }

    init(url: URL) {
        self.url = url
        self.sourceURL = url   // swapped for the temp snapshot once it's made
        self.name = url.deletingPathExtension().lastPathComponent
        self.inputBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .flatMap(Int64.init) ?? 0
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

/// Outcome of one press of the big button, drives the success panel.
struct RunSummary {
    var files = 0
    var inputBytes: Int64 = 0
    var outputBytes: Int64 = 0
    var savedBytes: Int64 { max(0, inputBytes - outputBytes) }
    var savedFraction: Double { inputBytes > 0 ? Double(savedBytes) / Double(inputBytes) : 0 }
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
            // and compare" flow: bring back the big button.
            if lastRun != nil {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { lastRun = nil }
            }
        }
    }
    var saveMode: SaveMode = .copy {
        didSet { UserDefaults.standard.set(saveMode.rawValue, forKey: "saveMode") }
    }
    var isCompressing = false
    /// Progress of the current run, for the button label and the bar.
    var completedCount = 0
    var runTotal = 0
    var lastRun: RunSummary?
    var isDropTargeted = false

    /// Two files at a time, not more: a single 100 MB image-heavy PDF peaks
    /// near 600 MB RSS in PDFKit.
    @ObservationIgnored private let gate = AsyncSemaphore(limit: 2)

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
            startReading(item)
        }
    }

    func remove(_ item: PDFItem) {
        guard !isCompressing else { return }   // UI disables this too; stay airtight
        item.readTask?.cancel()
        let dir = item.tempDir
        Task.detached(priority: .background) { try? FileManager.default.removeItem(at: dir) }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            items.removeAll { $0.id == item.id }
        }
    }

    func clearAll() {
        guard !isCompressing else { return }
        let dirs = items.map(\.tempDir)
        items.forEach { $0.readTask?.cancel() }
        Task.detached(priority: .background) {
            for dir in dirs { try? FileManager.default.removeItem(at: dir) }
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            items.removeAll()
            lastRun = nil
        }
    }

    // MARK: Reading (snapshot, page count, thumbnail)

    private func startReading(_ item: PDFItem) {
        let url = item.url
        let snapshotURL = item.tempDir.appendingPathComponent("source.pdf")
        item.readTask = Task { [weak item] in
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
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                item.status = meta.error.map { .failed($0) } ?? .ready
            }
        }
    }

    // MARK: What the big button will do

    /// Everything the list holds, drives the "N files, X MB" header.
    var listBytes: Int64 { items.reduce(0) { $0 + $1.inputBytes } }

    /// Items the big button will process: readable, and not already saved
    /// *with the currently selected preset*. An item delivered as Recommended
    /// becomes pending again when the user switches to Low, that's how "save
    /// another version and compare" works.
    var pendingItems: [PDFItem] {
        items.filter {
            switch $0.status {
            case .failed, .reading: false
            case .done: $0.resultPreset != preset
            case .ready, .compressing: true
            }
        }
    }

    var isReading: Bool { items.contains { $0.status == .reading } }

    var canCompress: Bool { !isCompressing && !isReading && !pendingItems.isEmpty }

    // MARK: The big button

    func compressAll() {
        guard canCompress else { return }

        // "Save a copy": pick the destination folder up front, once per batch.
        // The panel opens in the first file's folder, so "same place" is one Enter away.
        var chosenDir: URL?
        if saveMode == .copy {
            if let scripted = ProcessInfo.processInfo.environment["BONSAI_OUTDIR"] {
                chosenDir = URL(fileURLWithPath: scripted, isDirectory: true)
            } else {
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
        }

        let targets = pendingItems
        let selected = preset
        let mode = saveMode
        let destDir = chosenDir
        isCompressing = true
        lastRun = nil
        completedCount = 0
        runTotal = targets.count
        targets.forEach { item in
            withAnimation { item.status = .compressing }
        }

        Task {
            var summary = RunSummary()
            await withTaskGroup(of: CompressionResult?.self) { group in
                for item in targets {
                    group.addTask { @MainActor in
                        await self.process(item, preset: selected, mode: mode, destDir: destDir)
                    }
                }
                for await delivered in group {
                    completedCount += 1
                    guard let delivered else { continue }
                    summary.files += 1
                    summary.inputBytes += delivered.inputBytes
                    summary.outputBytes += delivered.outputBytes
                }
            }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                isCompressing = false
                if summary.files > 0 && !items.isEmpty { lastRun = summary }
            }
        }
    }

    /// Compresses one item under the memory gate and moves the result to its
    /// final home. Returns nil when the item failed or was removed meanwhile.
    private func process(_ item: PDFItem, preset: Preset, mode: SaveMode, destDir: URL?) async -> CompressionResult? {
        let source = item.sourceURL   // snapshot: valid even after Replace
        let dir = item.tempDir
        await gate.wait()
        let result = await Task.detached(priority: .userInitiated) {
            try? Compressor.compress(source, preset: preset, workDir: dir)
        }.value
        await gate.signal()

        // Never touch files the user excluded while others were processing.
        guard items.contains(where: { $0.id == item.id }) else { return nil }
        guard let result else {
            withAnimation { item.status = .failed(CompressionError.writeFailed.errorDescription!) }
            return nil
        }
        let originalURL = item.url
        do {
            // File I/O can be seconds for huge PDFs, keep it off the main actor.
            let dest = try await Task.detached(priority: .userInitiated) {
                try Self.deliver(result: result, original: originalURL, mode: mode,
                                 preset: preset, destDir: destDir)
            }.value
            item.savedURL = dest
            item.result = result
            item.resultPreset = preset
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { item.status = .done }
            return result
        } catch {
            withAnimation { item.status = .failed("Couldn't save: \(error.localizedDescription)") }
            return nil
        }
    }

    /// Move the compressed temp file to its final home.
    nonisolated private static func deliver(result: CompressionResult, original: URL,
                                            mode: SaveMode, preset: Preset, destDir: URL?) throws -> URL {
        let fm = FileManager.default
        switch mode {
        case .replace:
            // Stage-first so a failure can never strand the user's file:
            // 1. copy the result next to the original under a hidden name,
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
