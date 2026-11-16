import Foundation

/// The size of a page as it is shown, in points: its crop box after rotation
/// and user units.
struct PageFormat: Hashable, Sendable {
    let width: Double
    let height: Double
}
