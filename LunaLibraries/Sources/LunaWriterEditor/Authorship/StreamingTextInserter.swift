//
//  StreamingTextInserter.swift
//  LunaWriterEditor
//

import UIKit
import LunaWriterModels

public protocol StreamingTextInserterDelegate: AnyObject {
    func streamingTextInserter(
        _ inserter: StreamingTextInserter, didInsert range: NSRange, as source: AuthorshipSpan.Source)
    func streamingTextInserterDidFinish(_ inserter: StreamingTextInserter)
}

/// Types an assistant's answer into the sheet a few characters at a time.
///
/// The writer sees the words arrive rather than appear, and the whole run is
/// recorded as one authorship span when it ends.
public final class StreamingTextInserter {

    public static let defaultChunk = 3
    public static let defaultInterval: TimeInterval = 0.02

    public weak var delegate: StreamingTextInserterDelegate?

    private weak var textView: WriterTextView?
    private let chunk: Int
    private let interval: TimeInterval
    private var remaining: [Character] = []
    private var source: AuthorshipSpan.Source = .author
    private var start = 0
    private var inserted = 0
    private var timer: Timer?

    public init(
        textView: WriterTextView?, chunk: Int = defaultChunk, interval: TimeInterval = defaultInterval
    ) {
        self.textView = textView
        self.chunk = max(1, chunk)
        self.interval = interval
    }

    deinit { timer?.invalidate() }

    public var isRunning: Bool { timer != nil }

    /// Starts a run at the caret. A run already going is finished first.
    public func insert(_ text: String, as source: AuthorshipSpan.Source, at location: Int) {
        finish()
        guard !text.isEmpty else { return }
        remaining = Array(text)
        self.source = source
        start = location
        inserted = 0
        textView?.selectedRange = NSRange(location: location, length: 0)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.step()
        }
        step()
    }

    /// Inserts at the text view's OWN current caret, read fresh every step —
    /// not `start + inserted`, recomputed by hand. That arithmetic goes
    /// stale the moment anything else edits the document between two
    /// chunks; the caret itself is always exactly where the last thing
    /// typed — this chunk, or someone else's edit — left it.
    private func step() {
        guard let textView else {
            finish()
            return
        }
        guard !remaining.isEmpty else {
            finish()
            return
        }
        let take = min(chunk, remaining.count)
        let piece = String(remaining.prefix(take))
        remaining.removeFirst(take)
        let at = textView.selectedRange
        textView.replaceText(in: at, with: piece)
        inserted += (piece as NSString).length
    }

    /// Ends the run and reports the whole inserted range.
    public func finish() {
        timer?.invalidate()
        timer = nil
        guard inserted > 0 else {
            remaining = []
            return
        }
        let range = NSRange(location: start, length: inserted)
        let source = self.source
        remaining = []
        inserted = 0
        delegate?.streamingTextInserter(self, didInsert: range, as: source)
        delegate?.streamingTextInserterDidFinish(self)
    }
}
