//
//  AutosaveScheduling.swift
//  LunaWriterEditor
//

import Foundation

/// Something waiting for the autosave deadline.
public protocol AutosaveScheduled: AnyObject {
    func autosaveDeadlineReached()
}

/// Counts out the pause after the last keystroke.
public protocol AutosaveScheduling: AnyObject {
    func schedule(after delay: TimeInterval, for target: AutosaveScheduled)
    func cancel()
}

/// The production witness: a one-shot timer, restarted on every edit.
public final class TimerAutosaveScheduler: AutosaveScheduling {

    private var timer: Timer?
    private weak var target: AutosaveScheduled?

    public init() {}

    deinit { timer?.invalidate() }

    public func schedule(after delay: TimeInterval, for target: AutosaveScheduled) {
        self.target = target
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.target?.autosaveDeadlineReached()
        }
    }

    public func cancel() {
        timer?.invalidate()
        timer = nil
    }
}
