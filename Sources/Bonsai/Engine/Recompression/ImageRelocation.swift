import CoreGraphics
import Foundation

/// An image cut down to the part of it that shows. The cut image moves to a
/// new object, and a form XObject takes the old place and paints it where
/// that part used to be. Everything that draws the old object, on any page
/// or in any form, keeps working without a change to its content stream.
struct ImageRelocation: Sendable {
    /// The cut image. Its dictionary describes the new size.
    let image: StreamReplacement
    /// The part that was kept, as a rectangle in the unit square the image
    /// is painted into, origin at the bottom left.
    let frame: CGRect
}
