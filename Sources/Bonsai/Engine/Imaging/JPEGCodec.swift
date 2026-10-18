import Foundation

/// mozjpeg's cjpeg and djpeg, driven through files in a scratch directory.
/// Output is always baseline (sequential) JPEG with 8-bit tables, the most
/// widely supported form of DCTDecode. Trellis quantization is tuned for SSIM,
/// which keeps film grain and fine texture at a lower cost than the default.
struct JPEGCodec: Sendable {
    let encoder: ExternalTool
    let decoder: ExternalTool
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

    func encode(_ image: PixelBuffer, quality: Int, chroma: ChromaSubsampling) -> Data? {
        let input = temporaryFile("pnm")
        let output = temporaryFile("jpg")
        defer { remove(input, output) }
        var arguments = ["-quality", "\(quality)", "-baseline", "-quant-baseline", "-optimize", "-tune-ssim"]
        if image.channels == 3 {
            arguments += ["-sample", chroma.samplingFactors]
        }
        guard (try? PNM.encode(image).write(to: input)) != nil,
              encoder.run(arguments + [input.path], output: output) == 0,
              let data = try? Data(contentsOf: output), !data.isEmpty else { return nil }
        return data
    }

    private func temporaryFile(_ suffix: String) -> URL {
        scratch.appendingPathComponent("\(UUID().uuidString).\(suffix)")
    }

    private func remove(_ urls: URL...) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }
}
