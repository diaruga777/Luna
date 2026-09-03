//
//  FocusIdleTimer.swift
//  LunaWriterEditor
//

import Foundation

public protocol FocusIdleTimerDelegate: AnyObject {
    func focusIdleTimerDidExpire(_ timer: FocusIdleTimer)
}

/// Says when the caret last moved.
///
/// Focus dims the page around the caret, which is right while somebody
/// writes and wrong while somebody reads. The timer is what tells the two
/// apart: a page nobody has typed in for `timeout` seconds stops dimming.
public final class FocusIdleTimer {

    public static let defaultTimeout: TimeInterval = 2

    public let timeout: TimeInterval
    public weak var delegate: FocusIdleTimerDelegate?

    /// True once `timeout` passed with no touch.
    public private(set) var isIdle: Bool = true

    private var timer: Timer?

    public init(timeout: TimeInterval = defaultTimeout) {
        self.timeout = timeout
    }

    deinit { timer?.invalidate() }

    /// The caret moved. Restarts the countdown.
    public func touch() {
        isIdle = false
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.isIdle = true
            self.delegate?.focusIdleTimerDidExpire(self)
        }
    }

    /// Stops the countdown and reports idle at once.
    public func stop() {
        timer?.invalidate()
        timer = nil
        isIdle = true
    }
}
