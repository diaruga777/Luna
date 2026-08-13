//
//  PracticeDownloadRamp.swift
//  LunaShareSurface
//

import Foundation
import LunaDesignSystem

/// A rehearsed download's progress bar, driven by a clock instead of a real
/// transfer.
///
/// A practice save already has its file in hand before its screen appears —
/// the clip ships in the app bundle — so there is no real progress to
/// report. Without this ramp, the bar would sit at zero for the whole beat
/// and then the finished screen would replace it, hiding the one thing the
/// lesson needs to show: that a download happened.
///
/// Both rehearsals fill the bar from here: the media kind's own
/// `SavedNonTextualViewController` over a bundled clip, and the kind-less
/// `ShareSetupPracticeDownloadViewController` an app without the media
/// module falls back to. Sharing this class keeps the two from filling at
/// different rates.
///
/// The ramp never starts before a hosted sheet finishes revealing. The
/// onboarding surface is built and loaded detached, well before the
/// lesson's sheet slides up — that split lets a real save's fetch overlap
/// the conversation — so a ramp started at `viewDidLoad` would finish
/// before anyone saw it. `revealDate` gates the start, and `beginReveal()`
/// re-arms it on every pass. In a real extension there is no session, so
/// the ramp runs immediately.
@MainActor
public final class PracticeDownloadRamp {

    /// How long the rehearsal spends downloading. Long enough to read as a
    /// download that happened — a bar that fills in one frame reads as a
    /// screen changing its mind — and short enough that nobody waits
    /// through it twice.
    public static let duration: TimeInterval = 1.5
    /// Where the bar pauses on the way up, and how far into the beat. Two
    /// steps instead of one long animation, because the bar draws its own
    /// ease, and a single 1.5s ramp reads as a progress bar nobody is
    /// driving.
    public static let firstStop: Float = 0.62
    public static let firstStopFraction: TimeInterval = 0.55
    /// How often the gate re-checks whether the sheet has revealed.
    private static let revealPollInterval: TimeInterval = 0.05

    private let bar: MoonHorizonProgressBar
    /// Cancels the pending steps of a replaced pass. The lesson loops, and a
    /// stale step landing over a newer pass would show a finished bar while
    /// the new one is still at zero.
    private var generation = 0

    public init(bar: MoonHorizonProgressBar) {
        self.bar = bar
    }

    /// Back to zero, then filling over `duration` once the sheet has opened,
    /// then `completion`. Starting a pass abandons the one before it.
    public func start(completion: @escaping () -> Void) {
        generation += 1
        bar.setProgress(0, animated: false)
        waitForReveal(generation: generation, completion: completion)
    }

    /// Abandons the pass in flight without touching what is drawn, for a
    /// screen whose result arrived from somewhere else.
    public func cancel() {
        generation += 1
    }

    private func waitForReveal(generation: Int, completion: @escaping () -> Void) {
        guard generation == self.generation else { return }
        if let session = HostedShareSession.current, session.revealDate == nil {
            after(Self.revealPollInterval, generation: generation) { [weak self] in
                self?.waitForReveal(generation: generation, completion: completion)
            }
            return
        }
        bar.setProgress(Self.firstStop, animated: true)
        after(
            Self.duration * Self.firstStopFraction, generation: generation
        ) { [weak self] in
            self?.bar.setProgress(1, animated: true)
        }
        after(Self.duration, generation: generation, completion)
    }

    private func after(
        _ delay: TimeInterval, generation: Int, _ work: @escaping () -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == self.generation else { return }
            work()
        }
    }
}
