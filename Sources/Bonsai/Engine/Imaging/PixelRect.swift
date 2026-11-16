import Foundation

/// A rectangle of whole pixels, origin at the top left of the image.
struct PixelRect: Equatable, Sendable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    var area: Int { max(0, width) * max(0, height) }
    var isEmpty: Bool { width <= 0 || height <= 0 }
    var maxX: Int { x + width }
    var maxY: Int { y + height }

    func union(_ other: PixelRect) -> PixelRect {
        if isEmpty { return other }
        if other.isEmpty { return self }
        let left = min(x, other.x), top = min(y, other.y)
        return PixelRect(x: left, y: top, width: max(maxX, other.maxX) - left, height: max(maxY, other.maxY) - top)
    }

    /// Empty when the rectangles do not overlap.
    func intersection(_ other: PixelRect) -> PixelRect {
        let left = max(x, other.x), top = max(y, other.y)
        return PixelRect(x: left, y: top, width: max(0, min(maxX, other.maxX) - left),
                         height: max(0, min(maxY, other.maxY) - top))
    }

    /// Grows by `margin` on every side.
    func expanded(by margin: Int) -> PixelRect {
        PixelRect(x: x - margin, y: y - margin, width: width + margin * 2, height: height + margin * 2)
    }
}
