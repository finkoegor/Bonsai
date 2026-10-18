import Foundation

/// Moves a compressed temporary file to where the user asked for it.
enum FileDelivery {
    static func deliver(_ result: CompressionResult, original: URL, mode: SaveMode,
                        preset: Preset, folder: URL?) throws -> URL {
        switch mode {
        case .replace: try replace(original, with: result.outputURL)
        case .copy: try copy(result.outputURL, nextTo: original, in: folder, preset: preset)
        }
    }

    /// Stages the new file next to the original first, so a failure at any
    /// step leaves the original where it was: the staged copy proves there is
    /// space, the original goes to the Trash, and a same-volume rename puts
    /// the new file in its place.
    private static func replace(_ original: URL, with compressed: URL) throws -> URL {
        let fileManager = FileManager.default
        let staging = original.deletingLastPathComponent().appendingPathComponent(".bonsai-\(UUID().uuidString).pdf")
        try fileManager.copyItem(at: compressed, to: staging)
        var trashed: NSURL?
        do {
            try fileManager.trashItem(at: original, resultingItemURL: &trashed)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        do {
            try fileManager.moveItem(at: staging, to: original)
        } catch {
            if let trashed = trashed as URL? { try? fileManager.moveItem(at: trashed, to: original) }
            try? fileManager.removeItem(at: staging)
            throw error
        }
        return original
    }

    /// Names the copy after the original and the preset, so versions made
    /// with different presets can sit side by side.
    private static func copy(_ compressed: URL, nextTo original: URL, in folder: URL?, preset: Preset) throws -> URL {
        let fileManager = FileManager.default
        let directory = folder ?? original.deletingLastPathComponent()
        let base = "\(original.deletingPathExtension().lastPathComponent)-compressed-\(preset.rawValue)"
        var destination = directory.appendingPathComponent("\(base).pdf")
        var counter = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(base) \(counter).pdf")
            counter += 1
        }
        try fileManager.copyItem(at: compressed, to: destination)
        return destination
    }
}
