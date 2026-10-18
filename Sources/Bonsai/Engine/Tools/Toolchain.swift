import Foundation

/// The Homebrew programs the engine depends on: qpdf rewrites the PDF
/// container, mozjpeg encodes and decodes JPEG.
struct Toolchain: Sendable {
    let qpdf: ExternalTool
    let jpegEncoder: ExternalTool
    let jpegDecoder: ExternalTool

    static let installCommand = "brew install qpdf mozjpeg"

    /// Nil when a tool is missing or qpdf predates JSON updates (qpdf 11).
    static let shared: Toolchain? = locate()

    private static func locate() -> Toolchain? {
        let fileManager = FileManager.default
        let prefixes = ["/opt/homebrew", "/usr/local"]

        let qpdf = prefixes
            .map { URL(fileURLWithPath: "\($0)/bin/qpdf") }
            .first { fileManager.isExecutableFile(atPath: $0.path) }
        let mozjpeg = prefixes
            .map { URL(fileURLWithPath: "\($0)/opt/mozjpeg/bin") }
            .first {
                fileManager.isExecutableFile(atPath: $0.appendingPathComponent("cjpeg").path)
                    && fileManager.isExecutableFile(atPath: $0.appendingPathComponent("djpeg").path)
            }
        guard let qpdf, let mozjpeg else { return nil }

        let tool = ExternalTool(url: qpdf)
        guard let banner = tool.output(["--version"]).map({ String(decoding: $0, as: UTF8.self) }),
              let version = banner.split(whereSeparator: \.isWhitespace).first(where: { $0.first?.isNumber == true }),
              let major = version.split(separator: ".").first.flatMap({ Int($0) }),
              major >= 11 else { return nil }

        return Toolchain(qpdf: tool,
                         jpegEncoder: ExternalTool(url: mozjpeg.appendingPathComponent("cjpeg")),
                         jpegDecoder: ExternalTool(url: mozjpeg.appendingPathComponent("djpeg")))
    }
}
