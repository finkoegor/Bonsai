import Foundation

/// Rewrites the image streams of a PDF and copies every other object as it
/// is: page content, text, vector art, fonts, transparency groups, blend
/// modes, annotations, links, forms and outlines keep their exact bytes.
struct DocumentOptimizer {
    let tools: Toolchain
    let profile: EncodingProfile
    /// An empty directory the optimizer may fill with temporary files.
    let workspace: URL

    func optimize(_ source: URL, into output: URL) -> Bool {
        let streams = workspace.appendingPathComponent("streams", isDirectory: true)
        let encoded = workspace.appendingPathComponent("encoded", isDirectory: true)
        let scratch = workspace.appendingPathComponent("scratch", isDirectory: true)
        for directory in [streams, encoded, scratch] {
            guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil
            else { return false }
        }

        let structureFile = workspace.appendingPathComponent("structure.json")
        let contentsFile = workspace.appendingPathComponent("contents.json")
        guard qpdf(["--json=2", "--json-key=qpdf", "--json-key=pages", "--json-stream-data=none",
                    "--decode-level=none", source.path, structureFile.path]),
              qpdf(["--json=2", "--json-key=qpdf", "--json-stream-data=file",
                    "--json-stream-prefix=\(streams.path)/s", "--decode-level=generalized",
                    source.path, contentsFile.path]),
              let structure = try? JSONParser.parse(Data(contentsOf: structureFile)),
              let contents = try? JSONParser.parse(Data(contentsOf: contentsFile)),
              let store = try? PDFObjectStore(json: structure) else { return false }
        let files = StreamFiles(json: contents)

        let usage = ImageUsageScanner(store: store, files: files).scan()
        let duplicates = DuplicateImageFinder(store: store, files: files).duplicates()
        let catalog = ImageCatalog(store: store, files: files, duplicates: duplicates)
        let codec = JPEGCodec(encoder: tools.jpegEncoder, decoder: tools.jpegDecoder, scratch: scratch)
        let replacements = ImageRecompressor(catalog: catalog, usage: usage, profile: profile,
                                             codec: codec, output: encoded).run()

        var update = DocumentUpdate()
        let rewriter = ReferenceRewriter(replacements: duplicates, generations: store.generations)
        for (number, body) in store.bodies where duplicates[number] == nil {
            if let replacement = replacements[number] {
                update.replaceStream(number, dictionary: rewriter.rewrite(replacement.dictionary),
                                     data: replacement.data)
                continue
            }
            guard !duplicates.isEmpty else { continue }
            switch body {
            case .value(let value):
                let rewritten = rewriter.rewrite(value)
                if rewritten != value { update.replaceValue(of: number, with: rewritten) }
            case .stream(let dictionary):
                let rewritten = rewriter.rewrite(dictionary)
                if rewritten != dictionary { update.replaceDictionary(ofStream: number, with: rewritten) }
            }
        }

        var arguments = [source.path]
        if !update.isEmpty {
            let updateFile = workspace.appendingPathComponent("update.json")
            guard (try? update.json(maxObjectID: store.maxObjectID, generations: store.generations)
                .write(to: updateFile)) != nil else { return false }
            arguments.append("--update-from-json=\(updateFile.path)")
        }
        arguments += ["--object-streams=generate", "--compress-streams=y", "--recompress-flate", "--compression-level=9"]
        if tools.qpdf.run(["--is-linearized", source.path], timeout: 120) == 0 {
            arguments.append("--linearize")
        }
        arguments.append(output.path)
        return qpdf(arguments)
    }

    /// qpdf exits with 3 when it repaired something and still wrote a valid file.
    private func qpdf(_ arguments: [String]) -> Bool {
        guard let status = tools.qpdf.run(arguments) else { return false }
        return status == 0 || status == 3
    }
}
