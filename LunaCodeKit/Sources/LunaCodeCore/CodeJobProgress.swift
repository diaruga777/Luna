import Foundation

/// Stage boundaries are measured; movement within a stage is a bounded estimate.
/// Optional on CodeJob so jobs from older companions and persisted logs still decode.
public struct CodeJobProgress: Codable, Equatable, Sendable {
    public var stage: String
    public var start: Double
    public var end: Double
    public var startedAt: Date
    public var estimatedSeconds: Double
    public var stoppedAt: Date?

    public init(stage: String, start: Double, end: Double, estimatedSeconds: Double, startedAt: Date = Date()) {
        self.stage = stage; self.start = start; self.end = end
        self.estimatedSeconds = estimatedSeconds; self.startedAt = startedAt
    }
    public func fraction(at date: Date = Date()) -> Double {
        let elapsed = max(0, (stoppedAt ?? date).timeIntervalSince(startedAt))
        let movement = 0.9 * (1 - exp(-elapsed / max(1, estimatedSeconds)))
        return min(0.99, max(0, start + (end - start) * movement))
    }
}

extension CodeJob {
    public func progressFraction(at date: Date = Date()) -> Double {
        if state == .succeeded { return 1 }
        // Older companions have no stage data. Never claim completion from a timer.
        return progress?.fraction(at: date) ?? 0.05
    }
    public var progressStage: String { progress?.stage ?? "Starting on your Mac…" }
}
