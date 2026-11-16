import CoreGraphics

/// The content stream operators that decide where things land on a page and
/// how much of them shows.
enum ContentOperation: Sendable {
    /// `q`
    case save
    /// `Q`
    case restore
    /// `cm`
    case concatenate(CGAffineTransform)
    /// `Do`
    case paint(String)
    /// `gs`
    case applyState(String)
    /// `W` or `W*` taking effect, with the bounds of the clipping path in
    /// user space.
    case clip(CGRect)
    /// A filled path or an inline image, with its bounds in user space.
    case fill(CGRect)
    /// Painting whose extent is not measured: strokes, text and shadings.
    case paintAnywhere
}
