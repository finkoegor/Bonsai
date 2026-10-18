import AppKit
import Observation
import PDFKit
import SwiftUI

@Observable @MainActor
final class AppState {
    static let shared = AppState()

    var items: [PDFItem] = []
    var preset: Preset = .recommended {
        didSet {
            UserDefaults.standard.set(preset.rawValue, forKey: "preset")
            if lastRun != nil {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { lastRun = nil }
            }
        }
    }
    var saveMode: SaveMode = .copy {
        didSet { UserDefaults.standard.set(saveMode.rawValue, forKey: "saveMode") }
    }
    var isCompressing = false
    var completedCount = 0
    var runTotal = 0
    var lastRun: RunSummary?
    var isDropTargeted = false

    /// Two files at a time: one large image-heavy PDF can take hundreds of
    /// megabytes while it is decoded.
    @ObservationIgnored private let gate = AsyncSemaphore(limit: 2)

    private init() {
        if let raw = UserDefaults.standard.string(forKey: "preset"), let stored = Preset(rawValue: raw) {
            preset = stored
        }
        if let raw = UserDefaults.standard.string(forKey: "saveMode"), let stored = SaveMode(rawValue: raw) {
            saveMode = stored
        }
    }

    // MARK: List

    func addURLs(_ urls: [URL]) {
        let existing = Set(items.map { $0.url.standardizedFileURL.path })
        let fresh = urls
            .filter { $0.pathExtension.lowercased() == "pdf" }
            .filter { !existing.contains($0.standardizedFileURL.path) }
        guard !fresh.isEmpty else { return }
        lastRun = nil
        for url in fresh {
            let item = PDFItem(url: url)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { items.append(item) }
            read(item)
        }
    }

    func remove(_ item: PDFItem) {
        guard !isCompressing else { return }
        item.readTask?.cancel()
        let directory = item.tempDir
        Task.detached(priority: .background) { try? FileManager.default.removeItem(at: directory) }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            items.removeAll { $0.id == item.id }
        }
    }

    func clearAll() {
        guard !isCompressing else { return }
        let directories = items.map(\.tempDir)
        items.forEach { $0.readTask?.cancel() }
        Task.detached(priority: .background) {
            for directory in directories { try? FileManager.default.removeItem(at: directory) }
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            items.removeAll()
            lastRun = nil
        }
    }

    /// Takes a snapshot of the file, its page count and a thumbnail.
    private func read(_ item: PDFItem) {
        let url = item.url
        let snapshot = item.tempDir.appendingPathComponent("source.pdf")
        item.readTask = Task { [weak item] in
            let metadata: (pages: Int, thumbnail: NSImage?, snapshotted: Bool, error: String?) =
                await Task.detached(priority: .userInitiated) {
                    do {
                        let document = try Compressor.validate(url)
                        let thumbnail = document.page(at: 0)?.thumbnail(of: CGSize(width: 240, height: 240), for: .mediaBox)
                        let snapshotted = (try? FileManager.default.createDirectory(
                            at: snapshot.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil
                            && (try? FileManager.default.copyItem(at: url, to: snapshot)) != nil
                        return (document.pageCount, thumbnail, snapshotted, nil)
                    } catch {
                        return (0, nil, false, error.localizedDescription)
                    }
                }.value

            guard let item, !Task.isCancelled else { return }
            item.pageCount = metadata.pages
            if metadata.snapshotted { item.sourceURL = snapshot }
            withAnimation(.easeOut(duration: 0.25)) { item.thumbnail = metadata.thumbnail }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                item.status = metadata.error.map { .failed($0) } ?? .ready
            }
        }
    }

    // MARK: Compression

    var listBytes: Int64 { items.reduce(0) { $0 + $1.inputBytes } }

    /// Readable items not yet saved with the selected preset.
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

    func compressAll() {
        guard canCompress else { return }
        var folder: URL?
        if saveMode == .copy {
            guard let chosen = chooseFolder() else { return }
            folder = chosen
        }

        let targets = pendingItems
        let preset = preset
        let mode = saveMode
        isCompressing = true
        lastRun = nil
        completedCount = 0
        runTotal = targets.count
        targets.forEach { item in withAnimation { item.status = .compressing } }

        Task {
            var summary = RunSummary()
            await withTaskGroup(of: CompressionResult?.self) { group in
                for item in targets {
                    group.addTask { @MainActor in
                        await self.process(item, preset: preset, mode: mode, folder: folder)
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

    /// Asks once per batch where "Save a copy" puts its files, starting in
    /// the first file's folder. Nil when the user cancels.
    private func chooseFolder() -> URL? {
        #if DEBUG
        if let scripted = ProcessInfo.processInfo.environment["BONSAI_OUTDIR"] {
            return URL(fileURLWithPath: scripted, isDirectory: true)
        }
        #endif
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Choose where to save the compressed PDFs"
        panel.directoryURL = pendingItems.first?.url.deletingLastPathComponent()
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func process(_ item: PDFItem, preset: Preset, mode: SaveMode, folder: URL?) async -> CompressionResult? {
        let source = item.sourceURL
        let directory = item.tempDir
        await gate.wait()
        let result = await Task.detached(priority: .userInitiated) {
            Result { try Compressor.compress(source, preset: preset, workDir: directory) }
        }.value
        await gate.signal()

        guard items.contains(where: { $0.id == item.id }) else { return nil }
        let compressed: CompressionResult
        switch result {
        case .success(let value):
            compressed = value
        case .failure(let error):
            withAnimation { item.status = .failed(error.localizedDescription) }
            return nil
        }

        let original = item.url
        do {
            let saved = try await Task.detached(priority: .userInitiated) {
                try FileDelivery.deliver(compressed, original: original, mode: mode, preset: preset, folder: folder)
            }.value
            item.savedURL = saved
            item.result = compressed
            item.resultPreset = preset
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { item.status = .done }
            return compressed
        } catch {
            withAnimation { item.status = .failed("Couldn't save: \(error.localizedDescription)") }
            return nil
        }
    }

    func revealSaved() {
        let urls = items.compactMap(\.savedURL)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
