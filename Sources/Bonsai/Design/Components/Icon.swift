import AppKit
import SwiftUI

/// A bundled Unicons SVG drawn as a template image, tinted by `foregroundStyle`.
struct Icon: View {
    let name: String
    var size: CGFloat = 16

    private static var cache: [String: NSImage] = [:]
    private static let lock = NSLock()

    /// SwiftPM's `Bundle.module` only looks next to the app and in the build
    /// directory baked in at compile time, so a moved app would not find it.
    /// build.sh copies the bundle into Contents/Resources.
    private static let resources: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Bonsai_Bonsai.bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }()

    static func image(_ name: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[name] { return cached }
        guard let url = resources.url(forResource: name, withExtension: "svg", subdirectory: "Icons"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        cache[name] = image
        return image
    }

    var body: some View {
        if let image = Self.image(name) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "questionmark.circle")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        }
    }
}
