import CoreGraphics

/// The content stream operators that decide where XObjects land on a page.
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
}
