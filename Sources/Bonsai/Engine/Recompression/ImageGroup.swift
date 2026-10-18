import Foundation

/// Images that must change together: base images and the soft masks they
/// share. Resizing one without the other would misalign transparency.
struct ImageGroup: Sendable {
    var bases: [Int]
    var masks: [Int]
    /// False when a member cannot be decoded to pixels, a mask carries
    /// /Matte, or a mask and its image differ in size.
    var allowsResizing: Bool

    var members: [Int] { masks + bases }

    /// Splits a catalog into groups linked by /SMask references.
    static func groups(in catalog: ImageCatalog) -> [ImageGroup] {
        var parent: [Int: Int] = [:]
        func root(_ number: Int) -> Int {
            var current = number
            while let next = parent[current], next != current { current = next }
            return current
        }
        for number in catalog.sources.keys { parent[number] = number }
        for source in catalog.sources.values {
            if let mask = source.softMask, parent[mask] != nil {
                parent[root(source.number)] = root(mask)
            }
        }

        var members: [Int: [Int]] = [:]
        for number in catalog.sources.keys.sorted() { members[root(number), default: []].append(number) }

        return members.values.map { numbers in
            let masks = numbers.filter { catalog.maskOwners[$0] != nil }
            let bases = numbers.filter { catalog.maskOwners[$0] == nil }
            let resizable = numbers.allSatisfy { catalog.sources[$0]?.isResampleable == true }
                && masks.allSatisfy { mask in
                    catalog.maskOwners[mask, default: []].allSatisfy { catalog.sources[$0] != nil }
                }
                && bases.allSatisfy { number in
                    guard let base = catalog.sources[number], let mask = base.softMask else { return true }
                    guard let maskSource = catalog.sources[mask] else { return false }
                    return maskSource.width == base.width && maskSource.height == base.height
                }
            return ImageGroup(bases: bases, masks: masks, allowsResizing: resizable)
        }
    }
}
