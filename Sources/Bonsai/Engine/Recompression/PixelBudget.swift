import Foundation

/// Caps the pixels held in memory at one time. Images are processed in
/// parallel, and several very large ones decoded together would take
/// gigabytes.
final class PixelBudget: @unchecked Sendable {
    private let capacity: Int
    private var available: Int
    private let condition = NSCondition()

    init(capacity: Int) {
        self.capacity = capacity
        self.available = capacity
    }

    /// Runs `work` once `pixels` fit into the budget. A request larger than
    /// the whole budget runs alone.
    func reserving<Result>(_ pixels: Int, _ work: () -> Result) -> Result {
        let share = min(max(pixels, 0), capacity)
        condition.lock()
        while available < share { condition.wait() }
        available -= share
        condition.unlock()
        defer {
            condition.lock()
            available += share
            condition.broadcast()
            condition.unlock()
        }
        return work()
    }
}
