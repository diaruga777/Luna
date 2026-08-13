//
//  IntentProgressReporter.swift
//  Luna
//
//  Stage-anchored progress for SaveIntent. Ungated (plain Foundation), so the
//  intent body reports stages without knowing whether an extended runtime is
//  actually consuming them.
//

import Foundation

/// Feeds the `progress` an extended-runtime intent must keep moving.
///
/// `LongRunningIntent` revokes the runtime extension if progress goes stale.
/// Apple's docs: "If you don't update this property regularly, the system can
/// cancel the background runtime extension and end your task prematurely."
/// Most of what Save does reports nothing on its own — an ingest race, a
/// keyless post search, a resolve step — so a real stage transition snaps the
/// value forward, and a heartbeat creeps it through the current stage's band
/// in between.
///
/// This is deliberately an estimate. The seemingly honest alternative, an
/// indeterminate `Progress` that never moves, is exactly what the system
/// cancels.
final class IntentProgressReporter: @unchecked Sendable {

    enum Stage {
        /// Screen read, post/page search, save + ingest.
        case saving
        /// The product kind's alternative-seller work: refreshing day-old seller
        /// prices and building the comparison summary.
        case findingSellers
        /// An awaited media download.
        case downloading
        /// Post-save handoff (export, foregrounding).
        case finishing

        /// Where this stage sits in the overall 0-1 range.
        ///
        /// The save is deliberately a sliver. It is fast — a classify, plus at
        /// most one metadata fetch — and the bytes are the only part with a
        /// real, honest measure, so the bar belongs almost entirely to the
        /// transfer. Giving the save half the bar, as this once did, made a
        /// failed save look like it died halfway through a download.
        ///
        /// `findingSellers` and `downloading` are alternatives, never a
        /// sequence: a save is a product or it is media. They deliberately
        /// share the same wide band rather than splitting it, which would make
        /// each look only half as far along as it is.
        var band: ClosedRange<Double> {
            switch self {
            case .saving: return 0.0...0.02
            case .findingSellers, .downloading: return 0.02...0.99
            case .finishing: return 0.99...1.0
            }
        }
    }

    private let lock = NSLock()
    private var stage: Stage = .saving
    private var value: Double = 0
    private var expectedBytes: Int64?
    private var receivedBytes: Int64 = 0

    /// A real transition. Jumps to the floor of the new stage, never backward.
    func enter(_ stage: Stage) {
        lock.lock()
        defer { lock.unlock() }
        self.stage = stage
        value = max(value, stage.band.lowerBound)
    }

    /// One heartbeat: closes some of the remaining distance to the end of the
    /// current band. Asymptotic on purpose: the bar always moves, but it never
    /// claims a stage is finished while it is still running.
    func tick() {
        lock.lock()
        defer { lock.unlock() }
        let ceiling = stage.band.upperBound
        value = min(ceiling, value + (ceiling - value) * 0.12)
    }

    /// The transfer's measured size, once the engine knows it. Switches the
    /// intent's `Progress` from an estimate to a byte count, so the system UI
    /// reads "1.2 MB of 4.4 MB" instead of a bare percentage.
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

    /// Non-nil once the transfer's size is known. The caller reports byte
    /// counts rather than a fraction while this holds.
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
