import CoreGraphics
import Foundation

/// Walks every page, form XObject and soft mask group, tracking the current
/// transformation matrix to find how large each image is drawn.
final class ImageUsageScanner {
    private let store: PDFObjectStore
    private let files: StreamFiles
    private var usage = ImageUsage()
    private var programs: [Int: [ContentOperation]] = [:]
    private var scannedHolders: Set<Int> = []
    private var remainingSteps = 20_000_000

    init(store: PDFObjectStore, files: StreamFiles) {
        self.store = store
        self.files = files
    }

    func scan() -> ImageUsage {
        if store.pages.isEmpty { usage.isComplete = false }
        for page in store.pages {
            scanPage(page)
        }
        collectUnaccountedImages()
        return usage
    }

    // MARK: Pages and forms

    private func scanPage(_ page: Int) {
        guard let dictionary = store.dictionary(page) else {
            usage.isComplete = false
            return
        }
        scannedHolders.insert(page)

        var resources = store.resolveDictionary(dictionary["/Resources"])
        var ancestor = dictionary["/Parent"]?.reference
        var hops = 0
        while resources == nil, let node = ancestor, hops < 64 {
            let parent = store.dictionary(node)
            resources = store.resolveDictionary(parent?["/Resources"])
            if resources != nil { scannedHolders.insert(node) }
            ancestor = parent?["/Parent"]?.reference
            hops += 1
        }
        let userUnit = dictionary["/UserUnit"]?.number ?? 1

        var streams: [Int] = []
        if let single = dictionary["/Contents"]?.reference {
            streams = store.streamDictionary(single) != nil
                ? [single]
                : store.resolve(dictionary["/Contents"])?.array?.compactMap(\.reference) ?? []
        } else {
            streams = dictionary["/Contents"]?.array?.compactMap(\.reference) ?? []
        }

        var content = Data()
        for stream in streams {
            guard let data = files.decodedData(stream) else {
                usage.isComplete = false
                return
            }
            content.append(data)
            content.append(0x0A)
        }
        let parsed = ContentParser.parse(content)
        if !parsed.isComplete { usage.isComplete = false }
        execute(parsed.operations, resources: resources, transform: .identity, userUnit: userUnit, forms: [])
    }

    private func execute(_ operations: [ContentOperation], resources: JSONObject?,
                         transform initial: CGAffineTransform, userUnit: Double, forms: Set<Int>) {
        var transform = initial
        var saved: [CGAffineTransform] = []
        for operation in operations {
            remainingSteps -= 1
            guard remainingSteps > 0 else {
                usage.isComplete = false
                return
            }
            switch operation {
            case .save:
                saved.append(transform)
            case .restore:
                if let previous = saved.popLast() { transform = previous }
            case .concatenate(let matrix):
                transform = matrix.concatenating(transform)
            case .paint(let name):
                paintXObject(named: name, resources: resources, transform: transform, userUnit: userUnit, forms: forms)
            case .applyState(let name):
                applySoftMask(named: name, resources: resources, transform: transform, userUnit: userUnit, forms: forms)
            }
        }
    }

    private func paintXObject(named name: String, resources: JSONObject?, transform: CGAffineTransform,
                              userUnit: Double, forms: Set<Int>) {
        guard let resources,
              let xObjects = store.resolveDictionary(store.entry("/XObject", in: resources)),
              let number = store.entry(name, in: xObjects)?.reference,
              let dictionary = store.streamDictionary(number) else { return }
        switch dictionary["/Subtype"]?.name {
        case "/Image":
            recordImage(number, dictionary: dictionary, transform: transform, userUnit: userUnit)
        case "/Form":
            runForm(number, dictionary: dictionary, inherited: resources, transform: transform,
                    userUnit: userUnit, forms: forms)
        default:
            break
        }
    }

    private func applySoftMask(named name: String, resources: JSONObject?, transform: CGAffineTransform,
                               userUnit: Double, forms: Set<Int>) {
        guard let resources,
              let states = store.resolveDictionary(store.entry("/ExtGState", in: resources)),
              let state = store.resolveDictionary(store.entry(name, in: states)),
              let softMask = store.resolveDictionary(state["/SMask"]),
              let group = softMask["/G"]?.reference,
              let dictionary = store.streamDictionary(group) else { return }
        runForm(group, dictionary: dictionary, inherited: resources, transform: transform,
                userUnit: userUnit, forms: forms)
    }

    private func runForm(_ number: Int, dictionary: JSONObject, inherited: JSONObject?,
                         transform: CGAffineTransform, userUnit: Double, forms: Set<Int>) {
        guard !forms.contains(number) else { return }
        guard let operations = program(for: number) else {
            usage.isComplete = false
            return
        }
        scannedHolders.insert(number)
        let matrix = Self.matrix(dictionary["/Matrix"]) ?? .identity
        let resources = store.resolveDictionary(dictionary["/Resources"]) ?? inherited
        execute(operations, resources: resources, transform: matrix.concatenating(transform),
                userUnit: userUnit, forms: forms.union([number]))
    }

    private func program(for stream: Int) -> [ContentOperation]? {
        if let cached = programs[stream] { return cached }
        guard let data = files.decodedData(stream) else { return nil }
        let parsed = ContentParser.parse(data)
        if !parsed.isComplete { usage.isComplete = false }
        programs[stream] = parsed.operations
        return parsed.operations
    }

    // MARK: Images

    private func recordImage(_ number: Int, dictionary: JSONObject, transform: CGAffineTransform, userUnit: Double) {
        record(number, dictionary: dictionary, transform: transform, userUnit: userUnit)
        for key in ["/SMask", "/Mask"] {
            if let mask = dictionary[key]?.reference, let maskDictionary = store.streamDictionary(mask) {
                record(mask, dictionary: maskDictionary, transform: transform, userUnit: userUnit)
            }
        }
    }

    /// An image fills the unit square of the current matrix, so its pixels
    /// spread over the lengths of the transformed unit vectors.
    private func record(_ number: Int, dictionary: JSONObject, transform: CGAffineTransform, userUnit: Double) {
        guard let width = dictionary["/Width"]?.integer, let height = dictionary["/Height"]?.integer else { return }
        let horizontal = Double(hypot(transform.a, transform.b)) * userUnit
        let vertical = Double(hypot(transform.c, transform.d)) * userUnit
        guard horizontal > 0.001, vertical > 0.001 else { return }
        let density = min(Double(width) * 72 / horizontal, Double(height) * 72 / vertical)
        usage.minimumDensity[number] = min(usage.minimumDensity[number] ?? .infinity, density)
    }

    // MARK: Places the scan does not follow

    /// Every image reachable from the resources of something the scan did not
    /// execute (patterns, Type 3 fonts, annotation appearances, forms never
    /// painted) may be drawn at a size the scan never saw.
    private func collectUnaccountedImages() {
        var visited: Set<Int> = []
        for number in store.bodies.keys.sorted() where !scannedHolders.contains(number) {
            guard let dictionary = store.dictionary(number) else { continue }
            for key in ["/Resources", "/DR"] {
                if let resources = dictionary[key] { collectImages(in: resources, visited: &visited) }
            }
            if dictionary["/Resources"] == nil, drawsWithInheritedResources(number, dictionary: dictionary) {
                usage.isComplete = false
            }
        }
    }

    private func collectImages(in value: JSONValue, visited: inout Set<Int>) {
        switch value {
        case .object(let object):
            for (key, member) in object.members where key != "/Parent" {
                collectImages(in: member, visited: &visited)
            }
        case .array(let array):
            for element in array { collectImages(in: element, visited: &visited) }
        case .string:
            guard let number = value.reference, visited.insert(number).inserted,
                  let dictionary = store.dictionary(number) else { return }
            if let type = dictionary["/Type"]?.name, ["/Page", "/Pages", "/Catalog"].contains(type) { return }
            if store.streamDictionary(number) != nil, dictionary["/Subtype"]?.name == "/Image" {
                usage.unaccounted.insert(number)
            }
            if case .value(let body)? = store.bodies[number] {
                collectImages(in: body, visited: &visited)
            } else {
                collectImages(in: .object(dictionary), visited: &visited)
            }
        default:
            break
        }
    }

    /// Tiling patterns and Type 3 fonts without their own resources borrow
    /// the resources of whatever uses them. When such content paints
    /// XObjects, the scan cannot tell at what size.
    private func drawsWithInheritedResources(_ number: Int, dictionary: JSONObject) -> Bool {
        var streams: [Int] = []
        if dictionary["/PatternType"]?.integer == 1 {
            streams = [number]
        } else if dictionary["/Subtype"]?.name == "/Type3",
                  let glyphs = store.resolveDictionary(dictionary["/CharProcs"]) {
            streams = glyphs.members.compactMap(\.value.reference)
        }
        for stream in streams {
            guard let data = files.decodedData(stream) else { return true }
            let parsed = ContentParser.parse(data)
            if !parsed.isComplete { return true }
            if parsed.operations.contains(where: {
                if case .paint = $0 { return true }
                return false
            }) { return true }
        }
        return false
    }

    private static func matrix(_ value: JSONValue?) -> CGAffineTransform? {
        guard let numbers = value?.array?.compactMap(\.number), numbers.count == 6 else { return nil }
        return CGAffineTransform(a: numbers[0], b: numbers[1], c: numbers[2],
                                 d: numbers[3], tx: numbers[4], ty: numbers[5])
    }
}
