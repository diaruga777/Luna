//
//  SavesSweepDriver.swift
//  LunaStorage
//

import Foundation
import UIKit

/// What a `SavesSweepDriver` drives: the consumer's own sweep body.
///
/// The driver holds this WEAKLY — the two instance consumers own their driver as
/// a `lazy var`, so a strong reference would be a cycle; the Spotlight indexer's
/// sweeper and driver are both `static let`s and live for the process.
public protocol SavesSweeping: AnyObject {
    /// One sweep pass, called on the driver's own utility queue. The consumer
    /// owns its reentrancy guard where it wants one — not everybody needs one;
    /// the Spotlight indexer's sweep is fully synchronous and never overlaps.
    func runSavesSweep()
}

/// A sweeper that also wants foreground/background transitions.
///
/// Conforming is what makes the driver install the two `UIApplication`
/// observers at all: a plain `SavesSweeping` gets none, which is how the
/// Spotlight indexer sweeps regardless of app state.
public protocol SavesSweepForegroundTracking: SavesSweeping {
    /// `true` on `didBecomeActiveNotification`, `false` on
    /// `didEnterBackgroundNotification`. Called BEFORE the driver's own
    /// foreground-transition sweep is scheduled.
    func savesSweepForegroundChanged(to isForeground: Bool)
}

/// The debounced `.savesChanged` sweep scaffolding shared by
/// `AudioScriptPipeline` (LunaAudioPlayback), `URLRescueCoordinator`
/// (LunaSaves), and the Spotlight indexer (`Luna/ArticleSpotlightIndexWiring`):
/// a burst of `.savesChanged` posts coalesces into one sweep after
/// `debounceInterval`, on a dedicated utility queue.
///
/// This type owns only the SCHEDULING; the sweep body belongs to the delegate.
public final class SavesSweepDriver {
    private let debounceInterval: TimeInterval
    private let workQueue: DispatchQueue
    private weak var sweeper: (any SavesSweeping)?
    /// The same object when it tracks foreground state, else nil — and nil is
    /// what suppresses the foreground/background observers entirely.
    private weak var foregroundTracker: (any SavesSweepForegroundTracking)?

    private var installed = false
    private var notificationObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    private var debounceWorkItem: DispatchWorkItem?

    /// - Parameters:
    ///   - queueLabel: the utility `DispatchQueue`'s label — each consumer's
    ///     own, so Instruments/backtraces show which sweep is running.
    ///   - debounceInterval: seconds to coalesce a burst of
    ///     `.savesChanged` into one sweep. Every current consumer uses
    ///     the default.
    ///   - sweeper: the consumer, held weakly. Conform it to
    ///     `SavesSweepForegroundTracking` to also get foreground
    ///     transitions.
    public init(
        queueLabel: String, debounceInterval: TimeInterval = 1.5,
        sweeper: any SavesSweeping
    ) {
        self.debounceInterval = debounceInterval
        self.workQueue = DispatchQueue(label: queueLabel, qos: .utility)
        self.sweeper = sweeper
        self.foregroundTracker = sweeper as? any SavesSweepForegroundTracking
    }

    deinit {
        [notificationObserver, foregroundObserver, backgroundObserver]
            .compactMap { $0 }
            .forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Idempotent. Observes debounced `.savesChanged`, plus
    /// foreground/background when the sweeper tracks it, and runs
    /// one launch sweep — `immediateLaunchSweep` true (the default) schedules
    /// it at once; false schedules it debounced, exactly like an ordinary
    /// burst (the Spotlight indexer's launch sweep waits the same interval).
    public func install(immediateLaunchSweep: Bool = true) {
        guard !installed else { return }
        installed = true
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .savesChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.scheduleSweep(debounced: true) }
        if foregroundTracker != nil {
            foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.foregroundTracker?.savesSweepForegroundChanged(to: true)
                self?.scheduleSweep(debounced: false)
            }
            backgroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.foregroundTracker?.savesSweepForegroundChanged(to: false)
            }
        }
        scheduleSweep(debounced: !immediateLaunchSweep)
    }

    /// Cancels any pending sweep and schedules a new one — immediately
    /// (`debounced: false`) or after `debounceInterval`.
    public func scheduleSweep(debounced: Bool) {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak sweeper] in sweeper?.runSavesSweep() }
        debounceWorkItem = work
        workQueue.asyncAfter(deadline: .now() + (debounced ? debounceInterval : 0), execute: work)
    }
}
