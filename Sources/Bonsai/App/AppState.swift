import AppKit
import Observation
import PDFKit
import SwiftUI

@Observable @MainActor
final class AppState {
    static let shared = AppState()

    var items: [PDFItem] = []
    var preset: Preset = .recommended {
        didSet { UserDefaults.standard.set(preset.rawValue, forKey: "preset") }
    }
    var saveMode: SaveMode = .copy {
        didSet { UserDefaults.standard.set(saveMode.rawValue, forKey: "saveMode") }
    }
    var isCompressing = false
    /// True from a press of Stop until the files in work have let go.
    var isStopping = false
    var completedCount = 0
    var runTotal = 0
    var isDropTargeted = false
    /// True while a card of the list is being dragged out of the window.
    private(set) var isDraggingOut = false
    /// False until qpdf and mozjpeg are installed; checked again whenever
    /// the app comes to the front.
    var toolsAvailable = Compressor.isAvailable

    /// Two files at a time: one large image-heavy PDF can take hundreds of
    /// megabytes while it is decoded.
    @ObservationIgnored private let gate = AsyncSemaphore(limit: 2)
    /// The files in work, by item.
    @ObservationIgnored private var monitors: [UUID: CompressionMonitor] = [:]

    private init() {
        if let raw = UserDefaults.standard.string(forKey: "preset"), let stored = Preset(rawValue: raw) {
            preset = stored
        }
        if let raw = UserDefaults.standard.string(forKey: "saveMode"), let stored = SaveMode(rawValue: raw) {
            saveMode = stored
        }
    }

    // MARK: List

    /// Adds PDFs and the PDFs inside folders. A file that failed before is
    /// tried again; files already in the list and the list's own results
    /// are passed over.
    func addURLs(_ urls: [URL]) {
        let candidates = Self.pdfs(in: urls)
        let paths = Set(candidates.map { $0.standardizedFileURL.path })
        for item in items where item.status.isFailure && paths.contains(item.url.standardizedFileURL.path) {
            discard(item)
        }
        var known = Set(items.map { $0.url.standardizedFileURL.path })
        known.formUnion(items.flatMap(\.versions).map { $0.url.standardizedFileURL.path })
        var fresh: [URL] = []
        for url in candidates where known.insert(url.standardizedFileURL.path).inserted {
            fresh.append(url)
        }
        for url in fresh {
            let item = PDFItem(url: url)
            animate(.spring(response: 0.35, dampingFraction: 0.8)) { items.append(item) }
            read(item)
        }
    }

    /// PDFs among `urls`, with folders replaced by the PDFs they hold at any
    /// depth, in the order Finder lists them.
    private static func pdfs(in urls: [URL]) -> [URL] {
        var found: [URL] = []
        for url in urls {
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if !isFolder {
                if url.pathExtension.lowercased() == "pdf" { found.append(url) }
                continue
            }
            let contents = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            let inside = (contents?.allObjects as? [URL] ?? [])
                .filter { $0.pathExtension.lowercased() == "pdf" }
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            found.append(contentsOf: inside)
        }
        return found
    }

    /// Keeps the list from offering itself as a place to drop one of its
    /// own cards. A drag has no end to hear about when it finishes in
    /// another app, so the mouse button is watched instead.
    func beginDragOut() {
        guard !isDraggingOut else { return }
        isDraggingOut = true
        isDropTargeted = false
        Task {
            while NSEvent.pressedMouseButtons & 1 != 0 {
                try? await Task.sleep(for: .milliseconds(100))
            }
            isDraggingOut = false
        }
    }

    /// Reads a failed file again in the place it holds in the list.
    func retry(_ item: PDFItem) {
        guard item.status.isFailure, let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let fresh = PDFItem(url: item.url)
        discardFiles(of: item)
        animate(.spring(response: 0.35, dampingFraction: 0.8)) { items[index] = fresh }
        read(fresh)
    }

    func remove(_ item: PDFItem) {
        guard !isCompressing else { return }
        discard(item)
    }

    private func discard(_ item: PDFItem) {
        discardFiles(of: item)
        animate(.spring(response: 0.3, dampingFraction: 0.85)) {
            items.removeAll { $0.id == item.id }
        }
    }

    private func discardFiles(of item: PDFItem) {
        item.readTask?.cancel()
        let directory = item.tempDir
        Task.detached(priority: .background) { try? FileManager.default.removeItem(at: directory) }
    }

    func clearAll() {
        guard !isCompressing else { return }
        let directories = items.map(\.tempDir)
        items.forEach { $0.readTask?.cancel() }
        Task.detached(priority: .background) {
            for directory in directories { try? FileManager.default.removeItem(at: directory) }
        }
        animate(.spring(response: 0.35, dampingFraction: 0.85)) { items.removeAll() }
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
            animate(.easeOut(duration: 0.25)) { item.thumbnail = metadata.thumbnail }
            animate(.spring(response: 0.4, dampingFraction: 0.8)) {
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
            case .done: $0.version(for: preset) == nil
            case .ready, .queued, .compressing: true
            }
        }
    }

    var isReading: Bool { items.contains { $0.status == .reading } }

    var canCompress: Bool { toolsAvailable && !isCompressing && !isReading && !pendingItems.isEmpty }

    /// What the selected preset saved, once no file waits for it any more.
    var summary: ListSummary? {
        guard !isCompressing, !isReading, pendingItems.isEmpty else { return nil }
        var summary = ListSummary()
        for version in items.compactMap({ $0.version(for: preset) }) {
            summary.files += 1
            summary.inputBytes += version.result.inputBytes
            summary.outputBytes += version.result.outputBytes
        }
        return summary.files > 0 ? summary : nil
    }

    /// The share of the running batch that is done, with the files in work
    /// counted by how far they are.
    var runProgress: Double {
        let inWork = items.reduce(0.0) { $0 + ($1.status == .compressing ? $1.progress : 0) }
        return min(1, (Double(completedCount) + inWork) / Double(max(1, runTotal)))
    }

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
        isStopping = false
        completedCount = 0
        runTotal = targets.count
        targets.forEach { item in animate(.default) { item.status = .queued } }

        Task {
            await withTaskGroup(of: Void.self) { group in
                for item in targets {
                    group.addTask { @MainActor in
                        await self.process(item, preset: preset, mode: mode, folder: folder)
                    }
                }
                for await _ in group { completedCount += 1 }
            }
            animate(.spring(response: 0.45, dampingFraction: 0.8)) {
                isCompressing = false
                isStopping = false
            }
        }
    }

    /// Abandons the files in work and leaves the rest of the batch as it is.
    /// Files already saved stay saved.
    func stop() {
        guard isCompressing, !isStopping else { return }
        isStopping = true
        monitors.values.forEach { $0.cancel() }
    }

    /// Looks for the command line tools again, since they may have been
    /// installed while the app was open.
    func refreshTools() {
        toolsAvailable = Compressor.isAvailable
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

    private func process(_ item: PDFItem, preset: Preset, mode: SaveMode, folder: URL?) async {
        let source = item.sourceURL
        let directory = item.tempDir
        let id = item.id
        await gate.wait()
        if isStopping {
            await gate.signal()
            leave(item)
            return
        }
        let monitor = CompressionMonitor { fraction in
            Task { @MainActor in self.advance(id, to: fraction) }
        }
        monitors[id] = monitor
        item.progress = 0
        animate(.default) { item.status = .compressing }
        let result = await Task.detached(priority: .userInitiated) {
            Result { try Compressor.compress(source, preset: preset, workDir: directory, monitor: monitor) }
        }.value
        monitors[id] = nil
        await gate.signal()

        guard items.contains(where: { $0.id == id }) else { return }
        let compressed: CompressionResult
        switch result {
        case .success(let value):
            compressed = value
        case .failure(CompressionError.cancelled):
            leave(item)
            return
        case .failure(let error):
            animate(.default) { item.status = .failed(error.localizedDescription) }
            return
        }

        // Nothing was gained: the original stays where it is and no copy is
        // written beside it. Only when an earlier version took its place
        // does the original go back there.
        let original = item.url
        let replacedEarlier = item.versions.contains { $0.url == original && !$0.result.keptOriginal }
        if compressed.keptOriginal && !(mode == .replace && replacedEarlier) {
            record(compressed, at: original, preset: preset, for: item)
            return
        }

        do {
            let saved = try await Task.detached(priority: .userInitiated) {
                try FileDelivery.deliver(compressed, original: original, mode: mode, preset: preset, folder: folder)
            }.value
            // The version that sat in the original's place is gone.
            if saved == original { item.versions.removeAll { $0.url == original } }
            record(compressed, at: saved, preset: preset, for: item)
        } catch {
            animate(.default) { item.status = .failed("Couldn't save: \(error.localizedDescription)") }
        }
    }

    private func record(_ result: CompressionResult, at url: URL, preset: Preset, for item: PDFItem) {
        item.versions.removeAll { $0.preset == preset }
        item.versions.append(SavedVersion(preset: preset, result: result, url: url))
        animate(.spring(response: 0.4, dampingFraction: 0.75)) { item.status = .done }
    }

    /// Puts an item that was not compressed after all back as it was.
    private func leave(_ item: PDFItem) {
        animate(.default) { item.status = item.versions.isEmpty ? .ready : .done }
    }

    private func advance(_ id: UUID, to fraction: Double) {
        guard let item = items.first(where: { $0.id == id }), item.status == .compressing else { return }
        item.progress = max(item.progress, fraction)
    }

    /// Animates only while Bonsai is the active app. An animation started
    /// while another app is in front, for example right after a file is
    /// dropped from Finder, stalls until the window gets an event, and the
    /// window keeps showing its previous state.
    private func animate(_ animation: Animation, _ changes: () -> Void) {
        if NSApp.isActive {
            withAnimation(animation, changes)
        } else {
            changes()
        }
    }

    func revealSaved() {
        let urls = items.compactMap { $0.version(for: preset)?.url }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
