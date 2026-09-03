//
//  AuthorshipSpanList.swift
//  LunaWriterModels
//

import Foundation

/// Who wrote each stretch of the document, as a sorted list of spans that
/// never overlap and never touch a neighbour of the same source.
///
/// Text no span covers has no recorded author. Every edit maps the list
/// through the change: a deletion shrinks and drops spans, an insertion
/// splits the span it lands inside, and typed characters extend an
/// `.author` span they touch instead of making a second one.
public struct AuthorshipSpanList: Equatable {

    private var storage: [AuthorshipSpan]

    public init(spans: [AuthorshipSpan] = []) {
        storage = AuthorshipSpanList.normalised(spans)
    }

    public var spans: [AuthorshipSpan] { storage }

    public var isEmpty: Bool { storage.isEmpty }

    // MARK: - Reading

    public func source(at location: Int) -> AuthorshipSpan.Source? {
        guard let index = indexOfSpan(covering: location) else { return nil }
        return storage[index].source
    }

    /// The spans inside `range`, clipped to it.
    public func spans(in range: NSRange) -> [AuthorshipSpan] {
        guard range.length > 0 else { return [] }
        var out: [AuthorshipSpan] = []
        for span in storage {
            let clipped = NSIntersectionRange(span.range.nsRange, range)
            if clipped.length > 0 {
                out.append(AuthorshipSpan(range: clipped, source: span.source, createdAt: span.createdAt))
            }
            if span.range.start >= NSMaxRange(range) { break }
        }
        return out
    }

    /// True when part of `range` was written by anybody but the writer.
    public func containsForeignText(in range: NSRange) -> Bool {
        spans(in: range).contains { $0.source != .author }
    }

    // MARK: - Editing

    /// Maps the list through one text change.
    ///
    /// `source` is what the inserted characters are recorded as. Pass nil when
    /// the caller records the insertion itself, as a paste does.
    public mutating func apply(
        edit: NSRange, replacementLength: Int, typedBy source: AuthorshipSpan.Source?,
        at date: Date = Date()
    ) {
        if edit.length > 0 { removeCharacters(in: edit) }
        if replacementLength > 0 {
            insertCharacters(at: edit.location, length: replacementLength)
            if let source {
                storage.insert(
                    AuthorshipSpan(
                        range: NSRange(location: edit.location, length: replacementLength),
                        source: source, createdAt: date),
                    at: insertionIndex(for: edit.location))
            }
        }
        storage = AuthorshipSpanList.normalised(storage)
    }

    /// Records a stretch as written by one source, replacing whatever the
    /// range held before.
    public mutating func record(range: NSRange, source: AuthorshipSpan.Source, at date: Date = Date()) {
        guard range.length > 0 else { return }
        clear(range)
        storage.insert(
            AuthorshipSpan(range: range, source: source, createdAt: date),
            at: insertionIndex(for: range.location))
        storage = AuthorshipSpanList.normalised(storage)
    }

    /// Takes a stretch back as the writer's own words.
    public mutating func markAsOwn(_ range: NSRange, at date: Date = Date()) {
        record(range: range, source: .author, at: date)
    }

    // MARK: - Mapping

    private mutating func removeCharacters(in edit: NSRange) {
        let start = edit.location
        let end = NSMaxRange(edit)
        let removed = edit.length
        var out: [AuthorshipSpan] = []
        out.reserveCapacity(storage.count)
        for span in storage {
            let newStart = shifted(span.range.start, deletionStart: start, deletionEnd: end, removed: removed)
            let newEnd = shifted(span.range.end, deletionStart: start, deletionEnd: end, removed: removed)
            guard newEnd > newStart else { continue }
            out.append(AuthorshipSpan(
                range: TextRange(start: newStart, end: newEnd), source: span.source, createdAt: span.createdAt))
        }
        storage = out
    }

    private func shifted(_ offset: Int, deletionStart: Int, deletionEnd: Int, removed: Int) -> Int {
        if offset <= deletionStart { return offset }
        if offset >= deletionEnd { return offset - removed }
        return deletionStart
    }

    private mutating func insertCharacters(at location: Int, length: Int) {
        var out: [AuthorshipSpan] = []
        out.reserveCapacity(storage.count + 1)
        for span in storage {
            let start = span.range.start
            let end = span.range.end
            if end <= location {
                out.append(span)
            } else if start >= location {
                out.append(AuthorshipSpan(
                    range: TextRange(start: start + length, end: end + length),
                    source: span.source, createdAt: span.createdAt))
            } else {
                // The insertion landed inside this span: split it, so the new
                // characters are attributed on their own.
                out.append(AuthorshipSpan(
                    range: TextRange(start: start, end: location), source: span.source, createdAt: span.createdAt))
                out.append(AuthorshipSpan(
                    range: TextRange(start: location + length, end: end + length),
                    source: span.source, createdAt: span.createdAt))
            }
        }
        storage = out
    }

    /// Cuts `range` out of every span it overlaps, without moving anything.
    private mutating func clear(_ range: NSRange) {
        let start = range.location
        let end = NSMaxRange(range)
        var out: [AuthorshipSpan] = []
        out.reserveCapacity(storage.count + 1)
        for span in storage {
            let spanStart = span.range.start
            let spanEnd = span.range.end
            if spanEnd <= start || spanStart >= end {
                out.append(span)
                continue
            }
            if spanStart < start {
                out.append(AuthorshipSpan(
                    range: TextRange(start: spanStart, end: start), source: span.source, createdAt: span.createdAt))
            }
            if spanEnd > end {
                out.append(AuthorshipSpan(
                    range: TextRange(start: end, end: spanEnd), source: span.source, createdAt: span.createdAt))
            }
        }
        storage = out
    }

    // MARK: - Search

    private func indexOfSpan(covering location: Int) -> Int? {
        var low = 0
        var high = storage.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let span = storage[mid].range
            if location < span.start {
                high = mid - 1
            } else if location >= span.end {
                low = mid + 1
            } else {
                return mid
            }
        }
        return nil
    }

    private func insertionIndex(for location: Int) -> Int {
        var low = 0
        var high = storage.count
        while low < high {
            let mid = (low + high) / 2
            if storage[mid].range.start < location { low = mid + 1 } else { high = mid }
        }
        return low
    }

    // MARK: - Normalising

    /// Sorts, drops empty spans, and merges neighbours that share a source.
    static func normalised(_ spans: [AuthorshipSpan]) -> [AuthorshipSpan] {
        let sorted = spans
            .filter { $0.range.length > 0 }
            .sorted { $0.range.start == $1.range.start ? $0.range.end < $1.range.end : $0.range.start < $1.range.start }
        var out: [AuthorshipSpan] = []
        out.reserveCapacity(sorted.count)
        for span in sorted {
            guard var last = out.last else {
                out.append(span)
                continue
            }
            if span.range.start >= last.range.end {
                if span.range.start == last.range.end, span.source == last.source {
                    last.range.end = span.range.end
                    out[out.count - 1] = last
                } else {
                    out.append(span)
                }
                continue
            }
            // Overlap: the later span wins the shared characters.
            if span.range.end <= last.range.end, span.source == last.source { continue }
            let precedingEnd = last.range.end
            last.range.end = span.range.start
            if last.range.length > 0 { out[out.count - 1] = last } else { out.removeLast() }
            if let previous = out.last, previous.range.end == span.range.start, previous.source == span.source {
                var merged = previous
                merged.range.end = max(previous.range.end, span.range.end)
                out[out.count - 1] = merged
            } else {
                out.append(span)
            }
            // `span` can sit entirely inside the one it overlapped — the
            // stretch after it, in the earlier span's source, must not
            // vanish just because `span` won the characters in the middle.
            if precedingEnd > span.range.end {
                out.append(AuthorshipSpan(
                    range: TextRange(start: span.range.end, end: precedingEnd),
                    source: last.source, createdAt: last.createdAt))
            }
        }
        return out
    }
}
