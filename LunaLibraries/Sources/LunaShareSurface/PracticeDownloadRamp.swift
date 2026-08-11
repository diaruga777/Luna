//
//  PracticeDownloadRamp.swift
//  LunaShareSurface
//

import Foundation
import LunaDesignSystem

/// A REHEARSED download's progress bar, driven by a clock instead of by a
/// transfer.
///
/// A practice save has its file in hand before its screen is ever on screen —
/// the clip ships in the app bundle — so there is no progress to report and
/// nothing to report it. Left at that, the bar sat at zero for the whole beat
/// and then the finished screen replaced it: the lesson's one visible claim,
/// that a download HAPPENED, was the only part it never showed.
///
/// Both rehearsals fill it from here — the media kind's own
/// `SavedNonTextualViewController` over a bundled clip, and the kind-less
/// `ShareSetupPracticeDownloadViewController` an app without the media module
/// falls back to — so the two cannot drift into filling at different rates.
///
/// Nothing starts before a hosted sheet has finished revealing. The onboarding
/// surface is built and loaded DETACHED, well before the lesson's sheet slides
/// up (that split is what lets a real save's fetch overlap the conversation), so
/// a ramp started at `viewDidLoad` would be over before anyone saw it.
/// `revealDate` is the gate, and `beginReveal()` re-arms it on every pass. In a
/// real extension there is no session and the ramp runs immediately.
@MainActor
public final class PracticeDownloadRamp {

    /// How long the rehearsal spends downloading. Long enough to be a download
    /// that HAPPENED — a bar that fills in a frame reads as a screen changing
    /// its mind — and short enough that nobody waits through it twice.
    public static let duration: TimeInterval = 1.5
    /// Where the bar pauses on the way up, and how far into the beat. Two steps
    /// rather than one long animation: the bar draws its own ease, and a single
    /// 1.5s ramp reads as a progress bar nobody is driving.
    public static let firstStop: Float = 0.62
    public static let firstStopFraction: TimeInterval = 0.55
    /// How often the gate re-checks whether the sheet has revealed.
    private static let revealPollInterval: TimeInterval = 0.05

    private let bar: MoonHorizonProgressBar
    /// Cancels the pending steps of a pass that has been replaced — the lesson
    /// loops, and a stale step landing over a newer pass would put a finished bar
    /// up while the new one was still at zero.
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

    /// Abandons the pass in flight without touching what is drawn — for a screen
    /// whose result arrived from somewhere else.
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
