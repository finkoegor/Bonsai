import Foundation

/// mozjpeg's cjpeg, djpeg and jpegtran, driven through files in a scratch
/// directory.
/// Output is always baseline (sequential) JPEG with 8-bit tables, the most
/// widely supported form of DCTDecode. Trellis quantization is tuned for SSIM,
/// which keeps film grain and fine texture at a lower cost than the default.
struct JPEGCodec: Sendable {
    let encoder: ExternalTool
    let decoder: ExternalTool
    let transformer: ExternalTool
    let scratch: URL

    func decode(_ jpeg: Data) -> PixelBuffer? {
        let input = temporaryFile("jpg")
        let output = temporaryFile("pnm")
        defer { remove(input, output) }
        guard (try? jpeg.write(to: input)) != nil,
              decoder.run(["-pnm", input.path], output: output) == 0,
              let data = try? Data(contentsOf: output) else { return nil }
        return PNM.decode(data)
    }

    /// An image written out for cjpeg to read.
    struct Input {
        fileprivate let file: URL
        fileprivate let hasColor: Bool
    }

    func encode(_ image: PixelBuffer, quality: Int, chroma: ChromaSubsampling) -> Data? {
        withInput(image) { encode($0, quality: quality, chroma: chroma) } ?? nil
    }

    /// Writes `image` out once for any number of encodes within `body`.
    /// Returns nil when the image could not be written.
    func withInput<Result>(_ image: PixelBuffer, _ body: (Input) -> Result) -> Result? {
        let file = temporaryFile("pnm")
        defer { remove(file) }
        guard (try? PNM.encode(image).write(to: file)) != nil else { return nil }
        return body(Input(file: file, hasColor: image.channels == 3))
    }

    func encode(_ input: Input, quality: Int, chroma: ChromaSubsampling) -> Data? {
        let output = temporaryFile("jpg")
        defer { remove(output) }
        var arguments = ["-quality", "\(quality)", "-baseline", "-quant-baseline", "-optimize", "-tune-ssim"]
        if input.hasColor {
            arguments += ["-sample", chroma.samplingFactors]
        }
        guard encoder.run(arguments + [input.file.path], output: output) == 0,
              let data = try? Data(contentsOf: output), !data.isEmpty else { return nil }
        return data
    }

    /// The largest block a JPEG is coded in, in pixels. A lossless crop can
    /// only start on a multiple of it.
    static let blockSize = 16

    /// Cuts `rect` out of a JPEG without decoding it. The quantized
    /// coefficients are copied, so the pixels inside stay exactly as they
    /// were. `rect` must start on a multiple of `blockSize` in both
    /// directions.
    func crop(_ jpeg: Data, to rect: PixelRect) -> Data? {
        guard rect.x % Self.blockSize == 0, rect.y % Self.blockSize == 0 else { return nil }
        let input = temporaryFile("jpg")
        let output = temporaryFile("jpg")
        defer { remove(input, output) }
        let region = "\(rect.width)x\(rect.height)+\(rect.x)+\(rect.y)"
        guard (try? jpeg.write(to: input)) != nil,
              transformer.run(["-revert", "-copy", "none", "-optimize", "-crop", region, input.path],
                              output: output) == 0,
              let data = try? Data(contentsOf: output),
              let header = JPEGHeader(data), header.isReencodable, !header.isProgressive,
              header.width == rect.width, header.height == rect.height else { return nil }
        return data
    }

    private func temporaryFile(_ suffix: String) -> URL {
        scratch.appendingPathComponent("\(UUID().uuidString).\(suffix)")
    }

    private func remove(_ urls: URL...) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }
}
