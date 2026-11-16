import Foundation

/// The caller's side of a compression in progress: it hears how far the
/// work is and can call it off.
final class CompressionMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let inherited: (@Sendable () -> Bool)?
    private let onProgress: (@Sendable (Double) -> Void)?

    init(onProgress: (@Sendable (Double) -> Void)? = nil) {
        self.inherited = nil
        self.onProgress = onProgress
    }

    private init(inherited: @escaping @Sendable () -> Bool, onProgress: @escaping @Sendable (Double) -> Void) {
        self.inherited = inherited
        self.onProgress = onProgress
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled || inherited?() == true
    }

    /// The work stops at its next step and the compression throws
    /// `CompressionError.cancelled`.
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    /// Passes on the share of the work done, from 0 to 1. Reports from
    /// several threads may arrive out of order.
    func report(_ fraction: Double) {
        onProgress?(fraction)
    }

    /// A monitor for one stage of the job. It is cancelled together with
    /// this one, and what it reports lands inside `range` of the whole.
    func stage(_ range: ClosedRange<Double>) -> CompressionMonitor {
        CompressionMonitor(inherited: { self.isCancelled }, onProgress: { fraction in
            self.report(range.lowerBound + fraction * (range.upperBound - range.lowerBound))
        })
    }
}
