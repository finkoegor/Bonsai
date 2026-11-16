import Foundation

/// A compressed version of a file as it sits on disk.
struct SavedVersion {
    let preset: Preset
    let result: CompressionResult
    /// The original's own place when the original was replaced, or kept
    /// because nothing was gained.
    let url: URL
}
