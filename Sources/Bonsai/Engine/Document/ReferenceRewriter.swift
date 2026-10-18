import Foundation

/// Points indirect references at other objects.
struct ReferenceRewriter {
    let replacements: [Int: Int]
    let generations: [Int: Int]

    func rewrite(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let object):
            return .object(rewrite(object))
        case .array(let array):
            return .array(array.map(rewrite))
        case .string:
            guard let number = value.reference, let target = replacements[number] else { return value }
            return .reference(target, generation: generations[target] ?? 0)
        default:
            return value
        }
    }

    func rewrite(_ object: JSONObject) -> JSONObject {
        var result = JSONObject()
        for (key, value) in object.members { result[key] = rewrite(value) }
        return result
    }
}
