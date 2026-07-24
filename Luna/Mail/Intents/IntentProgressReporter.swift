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
        var band: ClosedRange<Double> {
            switch self {
            case .saving: return 0.0...0.50
            case .downloading: return 0.50...0.95
            case .finishing: return 0.95...1.0
            }
        }
    }

    private let lock = NSLock()
    private var stage: Stage = .saving
    private var value: Double = 0

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

    var fraction: Double {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
