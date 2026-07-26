//
//  IntentProgressReporter.swift
//  Luna
//
//  Stage-anchored progress for the capture intents. Ungated (plain Foundation),
//  so the intent bodies report stages without knowing whether an extended
//  runtime is actually consuming them.
//

import Foundation

/// Feeds the `progress` an extended-runtime intent must keep moving.
///
/// `LongRunningIntent` REVOKES the runtime extension if progress goes stale
/// ("If you don't update this property regularly, the system can cancel the
/// background runtime extension and end your task prematurely"), and most of
/// what these intents do reports nothing: a 12 s ingest race, a keyless post
/// search, a resolve step. So real stage transitions snap the value forward and
/// a heartbeat creeps it through the current stage's band in between.
///
/// It is deliberately an ESTIMATE. The apparently-honest alternative — an
/// indeterminate `Progress` that never moves — is precisely what the system
/// cancels.
final class IntentProgressReporter: @unchecked Sendable {

    enum Stage {
        /// Screen read, post/page search, save + ingest.
        case saving
        /// An awaited media download.
        case downloading
        /// Post-save handoff (export, foregrounding).
        case finishing

        /// Where this stage sits in the overall 0…1 range.
        ///
        /// The save is deliberately a sliver. It is fast — a classify plus, at
        /// worst, one metadata fetch — and the bytes are the only part with a
        /// real, honest measure, so the bar belongs almost entirely to the
        /// transfer. Giving the save half the bar (as this once did) made a
        /// failed save look like it died halfway through a download.
        var band: ClosedRange<Double> {
            switch self {
            case .saving: return 0.0...0.02
            case .downloading: return 0.02...0.99
            case .finishing: return 0.99...1.0
            }
        }
    }

    private let lock = NSLock()
    private var stage: Stage = .saving
    private var value: Double = 0
    private var expectedBytes: Int64?
    private var receivedBytes: Int64 = 0

    /// A real transition: jump to the floor of the new stage (never backward).
    func enter(_ stage: Stage) {
        lock.lock()
        defer { lock.unlock() }
        self.stage = stage
        value = max(value, stage.band.lowerBound)
    }

    /// One heartbeat: close some of the remaining distance to the end of the
    /// current band. Asymptotic on purpose — the bar always moves, but it can't
    /// claim a stage finished while it's still running.
    func tick() {
        lock.lock()
        defer { lock.unlock() }
        let ceiling = stage.band.upperBound
        value = min(ceiling, value + (ceiling - value) * 0.12)
    }

    /// The transfer's measured size, once the engine knows it. Switches the
    /// intent's `Progress` from an estimate to a byte count, which is what makes
    /// the system UI read "1.2 MB of 4.4 MB" instead of a bare percentage.
    func setExpectedBytes(_ bytes: Int64?) {
        lock.lock()
        defer { lock.unlock() }
        guard let bytes, bytes > 0 else { return }
        expectedBytes = bytes
    }

    /// Real bytes on disk. Also keeps `fraction` honest for the estimate path, so
    /// a transfer whose size never resolved still advances.
    func setReceivedBytes(_ bytes: Int64) {
        lock.lock()
        defer { lock.unlock() }
        receivedBytes = max(receivedBytes, bytes)
        guard let expectedBytes, expectedBytes > 0 else { return }
        let band = Stage.downloading.band
        let completed = min(1, Double(receivedBytes) / Double(expectedBytes))
        value = max(value, band.lowerBound + (band.upperBound - band.lowerBound) * completed)
    }

    /// Non-nil once the transfer's size is known — the caller reports byte counts
    /// rather than a fraction while this holds.
    var byteCounts: (received: Int64, expected: Int64)? {
        lock.lock()
        defer { lock.unlock() }
        guard let expectedBytes, expectedBytes > 0 else { return nil }
        return (min(receivedBytes, expectedBytes), expectedBytes)
    }

    var fraction: Double {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
