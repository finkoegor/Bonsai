import CoreGraphics
import Foundation

/// Walks every page, form XObject and soft mask group the way a renderer
/// does, following the transformation matrix, the clip and the soft mask, to
/// find how large each image is drawn and how much of it can show.
final class ImageUsageScanner {
    /// The part of the graphics state the scan follows.
    private struct State {
        var transform: CGAffineTransform
        /// Bounds, in page space, outside which nothing shows: the page box,
        /// form boxes and clipping paths met so far.
        var clip: CGRect
        /// True while an ExtGState soft mask is in force.
        var hasSoftMask = false
        /// Bounds outside which that soft mask lets nothing through, nil
        /// when they are unknown.
        var softMaskBounds: CGRect?
        /// The constant alpha images are painted with.
        var fillOpacity = 1.0
        /// False while a blend mode other than Normal is in force.
        var blendsNormally = true

        /// Where an object that goes through the soft mask can show.
        var visible: CGRect {
            guard hasSoftMask, let softMaskBounds else { return clip }
            return clip.intersection(softMaskBounds)
        }
    }

    private struct Page {
        let format: PageFormat
        let userUnit: Double
    }

    private static let unitSquare = CGRect(x: 0, y: 0, width: 1, height: 1)

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
        usage.hasKnockoutGroups = store.bodies.keys.contains { number in
            store.resolveDictionary(store.dictionary(number)?["/Group"])?["/K"]?.boolean == true
        }
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

        guard let mediaBox = Self.rectangle(store.resolve(inherited("/MediaBox", from: dictionary))),
              !mediaBox.isEmpty else {
            usage.isComplete = false
            return
        }
        let cropBox = Self.rectangle(store.resolve(inherited("/CropBox", from: dictionary)))
        let shown = cropBox.map { $0.intersection(mediaBox) }.flatMap { $0.isEmpty ? nil : $0 } ?? mediaBox
        let userUnit = dictionary["/UserUnit"]?.number ?? 1
        let quarterTurns = (store.resolve(inherited("/Rotate", from: dictionary))?.integer ?? 0) / 90
        let isSideways = quarterTurns % 2 != 0
        let format = PageFormat(width: Double(isSideways ? shown.height : shown.width) * userUnit,
                                height: Double(isSideways ? shown.width : shown.height) * userUnit)

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
        execute(parsed.operations, resources: resources,
                state: State(transform: .identity, clip: mediaBox),
                page: Page(format: format, userUnit: userUnit), forms: [])
    }

    /// A page attribute that may be set on any ancestor in the page tree.
    private func inherited(_ key: String, from dictionary: JSONObject) -> JSONValue? {
        var current: JSONObject? = dictionary
        var hops = 0
        while let node = current, hops < 64 {
            if let value = node[key] { return value }
            current = node["/Parent"]?.reference.flatMap { store.dictionary($0) }
            hops += 1
        }
        return nil
    }

    /// Runs a content stream. Returns the bounds, in page space, of
    /// everything it painted.
    @discardableResult
    private func execute(_ operations: [ContentOperation], resources: JSONObject?,
                         state initial: State, page: Page, forms: Set<Int>) -> CGRect {
        var state = initial
        var saved: [State] = []
        var painted = CGRect.null
        for operation in operations {
            remainingSteps -= 1
            guard remainingSteps > 0 else {
                usage.isComplete = false
                return .infinite
            }
            switch operation {
            case .save:
                saved.append(state)
            case .restore:
                if let previous = saved.popLast() { state = previous }
            case .concatenate(let matrix):
                state.transform = matrix.concatenating(state.transform)
            case .clip(let bounds):
                state.clip = state.clip.intersection(bounds.applying(state.transform))
            case .fill(let bounds):
                painted = painted.union(bounds.applying(state.transform).intersection(state.visible))
            case .paintAnywhere:
                painted = painted.union(state.visible)
            case .paint(let name):
                painted = painted.union(paintXObject(named: name, resources: resources, state: state,
                                                     page: page, forms: forms))
            case .applyState(let name):
                applyState(named: name, resources: resources, state: &state, page: page, forms: forms)
            }
        }
        return painted
    }

    private func paintXObject(named name: String, resources: JSONObject?, state: State,
                              page: Page, forms: Set<Int>) -> CGRect {
        guard let resources,
              let xObjects = store.resolveDictionary(store.entry("/XObject", in: resources)),
              let number = store.entry(name, in: xObjects)?.reference,
              let dictionary = store.streamDictionary(number) else { return .null }
        switch dictionary["/Subtype"]?.name {
        case "/Image":
            return paintImage(number, dictionary: dictionary, state: state, page: page)
        case "/Form":
            return paintForm(number, dictionary: dictionary, inherited: resources, state: state,
                             page: page, forms: forms)
        default:
            return .null
        }
    }

    private func paintForm(_ number: Int, dictionary: JSONObject, inherited: JSONObject?,
                           state: State, page: Page, forms: Set<Int>) -> CGRect {
        guard !forms.contains(number) else { return .null }
        guard let operations = program(for: number) else {
            usage.isComplete = false
            return state.visible
        }
        scannedHolders.insert(number)

        var inner = state
        inner.transform = (Self.matrix(dictionary["/Matrix"]) ?? .identity).concatenating(state.transform)
        let box = Self.rectangle(store.resolve(dictionary["/BBox"]))?.applying(inner.transform) ?? .infinite
        if store.resolveDictionary(dictionary["/Group"])?["/S"]?.name == "/Transparency" {
            // A transparency group is composited as one object: the soft
            // mask outside applies to the whole group and none is in force
            // within it.
            inner.clip = state.visible.intersection(box)
            inner.hasSoftMask = false
            inner.softMaskBounds = nil
            inner.fillOpacity = 1
            inner.blendsNormally = true
        } else {
            inner.clip = state.clip.intersection(box)
        }
        let resources = store.resolveDictionary(dictionary["/Resources"]) ?? inherited
        return execute(operations, resources: resources, state: inner, page: page,
                       forms: forms.union([number]))
    }

    private func program(for stream: Int) -> [ContentOperation]? {
        if let cached = programs[stream] { return cached }
        guard let data = files.decodedData(stream) else { return nil }
        let parsed = ContentParser.parse(data)
        if !parsed.isComplete { usage.isComplete = false }
        programs[stream] = parsed.operations
        return parsed.operations
    }

    // MARK: Soft masks

    private func applyState(named name: String, resources: JSONObject?, state: inout State,
                            page: Page, forms: Set<Int>) {
        guard let resources,
              let states = store.resolveDictionary(store.entry("/ExtGState", in: resources)),
              let parameters = store.resolveDictionary(store.entry(name, in: states)) else { return }
        if let opacity = store.resolve(parameters["/ca"])?.number {
            state.fillOpacity = opacity
        }
        if let blend = store.resolve(parameters["/BM"]) {
            let mode = blend.name ?? blend.array?.first?.name
            state.blendsNormally = mode == "/Normal" || mode == "/Compatible"
        }
        guard let entry = store.resolve(parameters["/SMask"]) else { return }
        guard let softMask = entry.object else {
            state.hasSoftMask = entry.name != "/None"
            state.softMaskBounds = nil
            return
        }
        state.hasSoftMask = true
        state.softMaskBounds = nil
        guard let group = softMask["/G"]?.reference,
              let dictionary = store.streamDictionary(group) else { return }
        // The mask group is drawn in the coordinates current at this moment.
        // Running it records the images inside and measures what it paints.
        let painted = paintForm(group, dictionary: dictionary, inherited: resources,
                                state: State(transform: state.transform, clip: .infinite),
                                page: page, forms: forms)
        if isClearWhereUnpainted(softMask) {
            state.softMaskBounds = painted
        }
    }

    /// True when the mask is fully transparent wherever its group painted
    /// nothing: the backdrop is black and the transfer function maps 0 to 0.
    private func isClearWhereUnpainted(_ softMask: JSONObject) -> Bool {
        switch softMask["/S"]?.name {
        case "/Alpha":
            break
        case "/Luminosity":
            if let backdrop = store.resolve(softMask["/BC"]) {
                guard let components = backdrop.array?.map(\.number),
                      components.count == 1 || components.count == 3,
                      components.allSatisfy({ $0 == 0 }) else { return false }
            }
        default:
            return false
        }

        guard let transfer = softMask["/TR"] else { return true }
        if store.resolve(transfer)?.name == "/Identity" { return true }
        guard let function = store.resolveDictionary(transfer) else { return false }
        switch function["/FunctionType"]?.integer {
        case 2:
            let start = store.resolve(function["/C0"])?.array?.map(\.number) ?? [0]
            return start.allSatisfy { $0 == 0 }
        case 4:
            // The threshold `{ 0 gt { 1 } { 0 } ifelse }`, written by Figma.
            guard let stream = transfer.reference, let program = files.decodedData(stream) else { return false }
            let compact = String(decoding: program, as: UTF8.self).filter { !$0.isWhitespace }
            return compact == "{0gt{1}{0}ifelse}"
        default:
            return false
        }
    }

    // MARK: Images

    private func paintImage(_ number: Int, dictionary: JSONObject, state: State, page: Page) -> CGRect {
        // An image's own soft mask replaces the one in the graphics state.
        let hasOwnSoftMask = dictionary["/SMask"]?.reference != nil
        let visible = hasOwnSoftMask ? state.clip : state.visible
        let region = Self.region(visible, inImageDrawnWith: state.transform)

        var images = [(number, dictionary)]
        for key in ["/SMask", "/Mask"] {
            if let mask = dictionary[key]?.reference, let maskDictionary = store.streamDictionary(mask) {
                images.append((mask, maskDictionary))
            }
        }
        for (image, imageDictionary) in images {
            record(image, dictionary: imageDictionary, transform: state.transform, page: page)
            usage.visibleRegions[image] = (usage.visibleRegions[image] ?? .null).union(region)
        }
        usage.painted.insert(number)
        if state.hasSoftMask { usage.paintedUnderSoftMask.insert(number) }
        if state.hasSoftMask || state.fillOpacity < 1 || !state.blendsNormally {
            usage.paintedWithTransparency.insert(number)
        }
        return Self.unitSquare.applying(state.transform).intersection(visible)
    }

    /// An image fills the unit square of the current matrix, so its pixels
    /// spread over the lengths of the transformed unit vectors.
    private func record(_ number: Int, dictionary: JSONObject, transform: CGAffineTransform, page: Page) {
        guard let width = dictionary["/Width"]?.integer, let height = dictionary["/Height"]?.integer else { return }
        let horizontal = Double(hypot(transform.a, transform.b)) * page.userUnit
        let vertical = Double(hypot(transform.c, transform.d)) * page.userUnit
        guard horizontal > 0.001, vertical > 0.001 else { return }
        let density = min(Double(width) * 72 / horizontal, Double(height) * 72 / vertical)
        let known = usage.placements[number]?[page.format] ?? .infinity
        usage.placements[number, default: [:]][page.format] = min(known, density)
    }

    /// Maps bounds in page space back into the unit square of an image drawn
    /// with `transform`. The bounds of the mapped rectangle enclose it, so a
    /// rotated image keeps more than strictly needed, never less.
    private static func region(_ visible: CGRect, inImageDrawnWith transform: CGAffineTransform) -> CGRect {
        if visible.isNull || visible.isEmpty { return .null }
        let determinant = transform.a * transform.d - transform.b * transform.c
        guard visible.width < 1e9, visible.height < 1e9,
              determinant.isFinite, abs(determinant) > 1e-12 else { return unitSquare }
        return visible.applying(transform.inverted()).intersection(unitSquare)
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

    // MARK: Values

    private static func matrix(_ value: JSONValue?) -> CGAffineTransform? {
        guard let numbers = value?.array?.compactMap(\.number), numbers.count == 6 else { return nil }
        return CGAffineTransform(a: numbers[0], b: numbers[1], c: numbers[2],
                                 d: numbers[3], tx: numbers[4], ty: numbers[5])
    }

    /// A PDF rectangle, which may list its corners in any order.
    private static func rectangle(_ value: JSONValue?) -> CGRect? {
        guard let numbers = value?.array?.compactMap(\.number), numbers.count == 4 else { return nil }
        return CGRect(x: min(numbers[0], numbers[2]), y: min(numbers[1], numbers[3]),
                      width: abs(numbers[2] - numbers[0]), height: abs(numbers[3] - numbers[1]))
    }
}
