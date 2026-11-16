import CoreGraphics
import Foundation

/// Makes a PDF smaller without changing what it shows. Images are cut down
/// to their visible part, downsampled and re-encoded. Content streams get
/// shorter numbers and tighter compression. Every object keeps its place in
/// the document: text, vector art, fonts, transparency groups, blend modes,
/// annotations, links, forms and outlines are the same objects as before.
struct DocumentOptimizer {
    let tools: Toolchain
    let profile: EncodingProfile
    /// An empty directory the optimizer may fill with temporary files.
    let workspace: URL
    var monitor: CompressionMonitor?

    /// Where the stages end on the way from 0 to 1. What is left after
    /// writing goes to checking the result.
    private static let afterReading = 0.1
    private static let afterImages = 0.8
    private static let afterWriting = 0.9

    func optimize(_ source: URL, into output: URL) -> Bool {
        let streams = workspace.appendingPathComponent("streams", isDirectory: true)
        let encoded = workspace.appendingPathComponent("encoded", isDirectory: true)
        let scratch = workspace.appendingPathComponent("scratch", isDirectory: true)
        for directory in [streams, encoded, scratch] {
            guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil
            else { return false }
        }

        // Two views of the same objects: one with streams as they sit in the
        // file, one with general purpose filters removed and the contents
        // written out.
        let structureFile = workspace.appendingPathComponent("structure.json")
        let contentsFile = workspace.appendingPathComponent("contents.json")
        guard qpdf(["--json=2", "--json-key=qpdf", "--json-key=pages", "--json-stream-data=none",
                    "--decode-level=none", source.path, structureFile.path]),
              qpdf(["--json=2", "--json-key=qpdf", "--json-stream-data=file",
                    "--json-stream-prefix=\(streams.path)/s", "--decode-level=generalized",
                    source.path, contentsFile.path]),
              let structure = try? JSONParser.parse(Data(contentsOf: structureFile)),
              let contents = try? JSONParser.parse(Data(contentsOf: contentsFile)),
              let store = try? PDFObjectStore(json: structure), monitor?.isCancelled != true else { return false }
        let files = StreamFiles(json: contents)
        monitor?.report(Self.afterReading)

        let duplicates = DuplicateImageFinder(store: store, files: files).duplicates()
        let usage = ImageUsageScanner(store: store, files: files).scan().merging(duplicates)
        let catalog = ImageCatalog(store: store, files: files, duplicates: duplicates)
        let codec = JPEGCodec(encoder: tools.jpegEncoder, decoder: tools.jpegDecoder,
                              transformer: tools.jpegTransformer, scratch: scratch)
        let images = ImageRecompressor(catalog: catalog, usage: usage, profile: profile,
                                       codec: codec, output: encoded,
                                       monitor: monitor?.stage(Self.afterReading...Self.afterImages)).run()
        guard monitor?.isCancelled != true else { return false }
        let settled = Set(duplicates.keys).union(images.replacements.keys).union(images.relocations.keys)
        let repacked = StreamRepacker(store: store, files: files, output: encoded).run(skipping: settled)

        var update = DocumentUpdate()
        let rewriter = ReferenceRewriter(replacements: duplicates, generations: store.generations)
        var highestObjectID = store.maxObjectID
        for (number, body) in store.bodies where duplicates[number] == nil {
            if let relocation = images.relocations[number], let data = relocation.image.data {
                // The cut image becomes a new object; a form XObject in the
                // old place paints it where the kept part used to be.
                highestObjectID += 1
                update.replaceStream(highestObjectID, dictionary: rewriter.rewrite(relocation.image.dictionary),
                                     data: data)
                guard let frame = frameStream(number, painting: highestObjectID, in: relocation.frame,
                                              directory: encoded) else { return false }
                update.replaceStream(number, dictionary: frame.dictionary, data: frame.data)
                continue
            }
            if let replacement = images.replacements[number] ?? repacked[number] {
                let dictionary = rewriter.rewrite(replacement.dictionary)
                if let data = replacement.data {
                    update.replaceStream(number, dictionary: dictionary, data: data)
                } else {
                    update.replaceDictionary(ofStream: number, with: dictionary)
                }
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
            guard (try? update.json(maxObjectID: highestObjectID, generations: store.generations)
                .write(to: updateFile)) != nil else { return false }
            arguments.append("--update-from-json=\(updateFile.path)")
        }
        arguments += ["--object-streams=generate", "--compress-streams=y", "--compression-level=9"]
        if isLinearized(source) {
            arguments.append("--linearize")
        }
        arguments.append(output.path)
        guard monitor?.isCancelled != true, qpdf(arguments) else { return false }
        monitor?.report(Self.afterWriting)
        return true
    }

    /// A form XObject that paints `image` into `frame`, a rectangle of the
    /// unit square, and so looks like the whole image did before it was cut.
    private func frameStream(_ number: Int, painting image: Int, in frame: CGRect,
                             directory: URL) -> (dictionary: JSONObject, data: URL)? {
        func text(_ value: CGFloat) -> String { String(format: "%.9f", Double(value)) }
        let content = "\(text(frame.width)) 0 0 \(text(frame.height)) \(text(frame.minX)) \(text(frame.minY)) cm /Im Do\n"
        let file = directory.appendingPathComponent("\(number)-frame.bin")
        guard (try? Data(content.utf8).write(to: file)) != nil else { return nil }
        let dictionary = JSONObject([
            ("/Type", .name("/XObject")),
            ("/Subtype", .name("/Form")),
            ("/BBox", .array([.integer(0), .integer(0), .integer(1), .integer(1)])),
            ("/Resources", .object(JSONObject([
                ("/XObject", .object(JSONObject([("/Im", .reference(image, generation: 0))]))),
            ]))),
        ])
        return (dictionary, file)
    }

    /// Linearized ("fast web view") files stay linearized. Exporters often
    /// write slightly inaccurate hint tables, which qpdf reports as warnings.
    private func isLinearized(_ file: URL) -> Bool {
        let report = workspace.appendingPathComponent("linearization.txt")
        guard let status = tools.qpdf.run(["--check-linearization", file.path], output: report),
              status == 0 || status == 3,
              let text = try? String(contentsOf: report, encoding: .utf8) else { return false }
        return !text.contains("is not linearized")
    }

    /// qpdf exits with 3 when it repaired something and still wrote a valid file.
    private func qpdf(_ arguments: [String]) -> Bool {
        guard let status = tools.qpdf.run(arguments) else { return false }
        return status == 0 || status == 3
    }
}
