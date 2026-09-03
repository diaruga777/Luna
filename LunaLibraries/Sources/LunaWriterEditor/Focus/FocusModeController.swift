//
//  FocusModeController.swift
//  LunaWriterEditor
//

import UIKit
import LunaWriterStorage
import LunaWriterText

public protocol FocusModeControllerDelegate: AnyObject {
    func focusModeController(_ controller: FocusModeController, didChangeFocusRange range: NSRange?)
    /// Asks the host to bring the caret line to the typewriter position.
    func focusModeControllerRequestsTypewriterScroll(_ controller: FocusModeController)
}

/// Decides which sentence or paragraph stays lit.
///
/// The lit range follows the caret. It clears when nobody has typed for the
/// idle timeout and the keyboard is down, so a reader scrolling back through
/// the sheet sees all of it.
public final class FocusModeController: FocusRangeProviding, FocusIdleTimerDelegate {

    public weak var delegate: FocusModeControllerDelegate?

    private let segmenter: SentenceSegmenter
    private let idleTimer: FocusIdleTimer
    private var candidate: NSRange?

    public var mode: FocusMode {
        didSet {
            guard mode != oldValue else { return }
            if mode == .off { candidate = nil }
            publish()
        }
    }

    public var typewriterScrolling: Bool

    /// While the keyboard is up the writer is writing, so the dim stands even
    /// after the idle timeout.
    public var isKeyboardVisible: Bool = false {
        didSet {
            guard isKeyboardVisible != oldValue else { return }
            if isKeyboardVisible { idleTimer.touch() }
            publish()
        }
    }

    public private(set) var focusRange: NSRange?

    public init(
        mode: FocusMode = .off,
        typewriterScrolling: Bool = false,
        segmenter: SentenceSegmenter = SentenceSegmenter(),
        idleTimeout: TimeInterval = FocusIdleTimer.defaultTimeout
    ) {
        self.mode = mode
        self.typewriterScrolling = typewriterScrolling
        self.segmenter = segmenter
        idleTimer = FocusIdleTimer(timeout: idleTimeout)
        idleTimer.delegate = self
    }

    /// The caret moved. Recomputes the lit range and restarts the countdown.
    public func selectionChanged(to selection: NSRange, in text: NSString) {
        candidate = focusRange(for: selection, in: text)
        idleTimer.touch()
        publish()
        if typewriterScrolling {
            delegate?.focusModeControllerRequestsTypewriterScroll(self)
        }
    }

    /// The writer left the sheet. Nothing is dimmed until the caret returns.
    public func editingEnded() {
        idleTimer.stop()
        isKeyboardVisible = false
        publish()
    }

    /// The range the mode wants lit around a selection, whatever the timer says.
    public func focusRange(for selection: NSRange, in text: NSString) -> NSRange? {
        guard text.length > 0 else { return nil }
        let caret = min(max(0, selection.location), text.length - 1)
        let paragraph = text.paragraphRange(for: NSRange(location: caret, length: 0))
        switch mode {
        case .off:
            return nil
        case .paragraph:
            return paragraph
        case .sentence:
            let sentence = segmenter.sentenceRange(containing: caret, in: paragraph, of: text)
            return sentence ?? paragraph
        }
    }

    private func publish() {
        let wanted = mode == .off ? nil : candidate
        let allowed = isKeyboardVisible || !idleTimer.isIdle
        let next = allowed ? wanted : nil
        guard next != focusRange else { return }
        focusRange = next
        delegate?.focusModeController(self, didChangeFocusRange: next)
    }

    // MARK: - FocusIdleTimerDelegate

    public func focusIdleTimerDidExpire(_ timer: FocusIdleTimer) {
        publish()
    }
}
