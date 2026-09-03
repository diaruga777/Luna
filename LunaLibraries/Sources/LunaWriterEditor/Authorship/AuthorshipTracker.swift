//
//  AuthorshipTracker.swift
//  LunaWriterEditor
//

import UIKit
import LunaWriterModels

/// Told when the spans under a range changed, so the tint is repainted.
public protocol AuthorshipObserving: AnyObject {
    func authorshipTracker(_ tracker: AuthorshipTracker, didChange range: NSRange)
}

/// Keeps the document's authorship spans in step with its text.
public final class AuthorshipTracker: AuthorshipSpanProviding, WriterTextViewDataSource {

    public weak var observer: AuthorshipObserving?

    public private(set) var list: AuthorshipSpanList

    public init(spans: [AuthorshipSpan] = []) {
        list = AuthorshipSpanList(spans: spans)
    }

    public var spans: [AuthorshipSpan] { list.spans }

    /// Replaces everything, as a document load does.
    public func reset(to spans: [AuthorshipSpan]) {
        list = AuthorshipSpanList(spans: spans)
        observer?.authorshipTracker(self, didChange: NSRange(location: 0, length: Int.max))
    }

    /// One text change. `source` is nil when the caller records the inserted
    /// text itself.
    public func textDidChange(
        edit: NSRange, replacementLength: Int, typedBy source: AuthorshipSpan.Source?
    ) {
        list.apply(edit: edit, replacementLength: replacementLength, typedBy: source)
        observer?.authorshipTracker(
            self, didChange: NSRange(location: edit.location, length: max(replacementLength, 1)))
    }

    public func record(range: NSRange, source: AuthorshipSpan.Source) {
        guard range.length > 0 else { return }
        list.record(range: range, source: source)
        observer?.authorshipTracker(self, didChange: range)
    }

    public func markAsOwn(_ range: NSRange) {
        guard range.length > 0 else { return }
        list.markAsOwn(range)
        observer?.authorshipTracker(self, didChange: range)
    }

    // MARK: - AuthorshipSpanProviding

    public func authorshipSpans(in range: NSRange) -> [AuthorshipSpan] {
        list.spans(in: range)
    }

    // MARK: - WriterTextViewDataSource

    public func writerTextView(
        _ textView: WriterTextView, selectionTouchesForeignAuthorship range: NSRange
    ) -> Bool {
        list.containsForeignText(in: widened(range, upTo: textView.textStorage.length))
    }

    /// A caret touches the characters on either side of it.
    private func widened(_ range: NSRange, upTo length: Int) -> NSRange {
        guard range.length == 0 else { return range }
        let start = max(0, range.location - 1)
        let end = min(length, range.location + 1)
        return NSRange(location: start, length: max(0, end - start))
    }
}
