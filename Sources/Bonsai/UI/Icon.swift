import SwiftUI
import AppKit

/// Renders a bundled Unicons SVG as a template image tinted by `foregroundStyle`.
struct Icon: View {
    let name: String
    var size: CGFloat = 16

    private static var cache: [String: NSImage] = [:]
    private static let lock = NSLock()

    /// SwiftPM's generated Bundle.module only probes the .app ROOT and the
    /// absolute .build path baked in at compile time — so a moved or copied
    /// .app crashes at startup. Resolve the resource bundle from
    /// Contents/Resources ourselves (that's where build.sh puts it) and only
    /// fall back to Bundle.module for `swift run` during development.
    private static let resources: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Bonsai_Bonsai.bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }()

    static func image(_ name: String) -> NSImage? {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[name] { return hit }
        guard let url = resources.url(forResource: name, withExtension: "svg", subdirectory: "Icons"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true
        cache[name] = img
        return img
    }

    var body: some View {
        if let img = Self.image(name) {
            Image(nsImage: img)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            // Fallback so a missing asset never leaves a hole in the UI.
            Image(systemName: "questionmark.circle")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        }
    }
}
