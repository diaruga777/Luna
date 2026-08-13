//
//  ReadingListSweepDriver.swift
//  LunaStorage
//

import Foundation
import UIKit

/// The debounced `.readingListChanged` sweep scaffolding shared by
/// `AudioScriptPipeline` (LunaAudioPlayback), `URLRescueCoordinator`
/// (LunaReadingList), and the Spotlight indexer (`Luna/ArticleSpotlightIndexWiring`):
/// a burst of `.readingListChanged` posts coalesces into one sweep after
/// `debounceInterval`, on a dedicated utility queue.
///
/// This type owns only the SCHEDULING. Each consumer supplies its own sweep
/// body (`runSweep`) and, where it wants one, its own reentrancy guard — not
/// every consumer needs one; the Spotlight indexer's sweep is fully
/// synchronous and never overlaps itself.
public final class ReadingListSweepDriver {
    private let debounceInterval: TimeInterval
    private let workQueue: DispatchQueue
    private let runSweep: () -> Void
    /// Nil (the default) installs no foreground/background observers at all —
    /// the Spotlight indexer sweeps regardless of app state. Non-nil is told
    /// `true` on `didBecomeActiveNotification` and `false` on
    /// `didEnterBackgroundNotification`, BEFORE the driver's own
    /// foreground-transition sweep runs.
    private let onForegroundChange: ((Bool) -> Void)?

    private var installed = false
    private var notificationObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    private var debounceWorkItem: DispatchWorkItem?

    /// - Parameters:
    ///   - queueLabel: the utility `DispatchQueue`'s label — each consumer's
    ///     own, so Instruments/backtraces show which sweep is running.
    ///   - debounceInterval: seconds to coalesce a burst of
    ///     `.readingListChanged` into one sweep. Every current consumer uses
    ///     the default.
    ///   - onForegroundChange: see the property doc above.
    ///   - runSweep: the consumer's sweep body, called on `queueLabel`'s queue.
    public init(
        queueLabel: String, debounceInterval: TimeInterval = 1.5,
        onForegroundChange: ((Bool) -> Void)? = nil,
        runSweep: @escaping () -> Void
    ) {
        self.debounceInterval = debounceInterval
        self.workQueue = DispatchQueue(label: queueLabel, qos: .utility)
        self.onForegroundChange = onForegroundChange
        self.runSweep = runSweep
    }

    deinit {
        [notificationObserver, foregroundObserver, backgroundObserver]
            .compactMap { $0 }
            .forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Idempotent. Observes debounced `.readingListChanged`, plus
    /// foreground/background when `onForegroundChange` was given, and runs
    /// one launch sweep — `immediateLaunchSweep` true (the default) schedules
    /// it at once; false schedules it debounced, exactly like an ordinary
    /// burst (the Spotlight indexer's launch sweep waits the same interval).
    public func install(immediateLaunchSweep: Bool = true) {
        guard !installed else { return }
        installed = true
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .readingListChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.scheduleSweep(debounced: true) }
        if onForegroundChange != nil {
            foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.onForegroundChange?(true)
                self?.scheduleSweep(debounced: false)
            }
            backgroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.onForegroundChange?(false) }
        }
        scheduleSweep(debounced: !immediateLaunchSweep)
    }

    /// Cancels any pending sweep and schedules a new one — immediately
    /// (`debounced: false`) or after `debounceInterval`.
    public func scheduleSweep(debounced: Bool) {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [runSweep] in runSweep() }
        debounceWorkItem = work
        workQueue.asyncAfter(deadline: .now() + (debounced ? debounceInterval : 0), execute: work)
    }
}
