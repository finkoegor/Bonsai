import Foundation

/// What `ImageRecompressor` decided for the images of a document.
struct RecompressedImages: Sendable {
    /// Streams rewritten in place, by object number.
    var replacements: [Int: StreamReplacement] = [:]
    /// Images cut down to their visible part, by the object number they had.
    var relocations: [Int: ImageRelocation] = [:]

    mutating func merge(_ other: RecompressedImages) {
        replacements.merge(other.replacements) { first, _ in first }
        relocations.merge(other.relocations) { first, _ in first }
    }
}
