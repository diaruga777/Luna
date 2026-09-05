//
//  RelatedNotesRanker.swift
//  LunaWriterEditor
//

import Foundation
import LunaWriterModels
import LunaWriterStorage

public protocol RelatedNotesObserving: AnyObject {
    func relatedNotesRanker(
        _ ranker: RelatedNotesRanker, didRank hits: [NoteHit], topMatch: NoteHit?)
}

/// Keeps saying which notes belong beside what is being written.
///
/// Pen's matcher, made local: the last 400 characters before the caret are
/// the question, asked half a second after typing stops. A window that did
/// not change is not asked again, and a question still in flight is dropped
/// when a newer one arrives.
public final class RelatedNotesRanker {

    public static let windowLength = 400
    public static let defaultDebounce: TimeInterval = 0.5
    public static let defaultLimit = 3

    public weak var observer: RelatedNotesObserving?

    public private(set) var hits: [NoteHit] = []
    public private(set) var topMatch: NoteHit?

    private let noteIndex: NoteIndexing
    private let documentID: DocumentID
    private let limit: Int
    private let debounce: TimeInterval
    private let queue: DispatchQueue

    private var lastWindow: String?
    private var timer: Timer?
    private var generation = 0

    public init(
        noteIndex: NoteIndexing,
        documentID: DocumentID,
        limit: Int = defaultLimit,
        debounce: TimeInterval = defaultDebounce,
        queue: DispatchQueue = DispatchQueue(label: "com.luna.writer.related", qos: .utility)
    ) {
        self.noteIndex = noteIndex
        self.documentID = documentID
        self.limit = limit
        self.debounce = debounce
        self.queue = queue
    }

    deinit { timer?.invalidate() }

    /// The 400 characters before `location`, which is the question asked.
    public func window(before location: Int, in text: NSString) -> String {
        let end = min(max(0, location), text.length)
        let start = max(0, end - Self.windowLength)
        guard end > start else { return "" }
        return text.substring(with: NSRange(location: start, length: end - start))
    }

    /// The caret moved or the text changed. Asks again once typing stops.
    public func caretMoved(to location: Int, in text: NSString) {
        let window = self.window(before: location, in: text)
        guard window != lastWindow else { return }
        lastWindow = window
        timer?.invalidate()
        generation &+= 1
        guard !window.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            publish([])
            return
        }
        let generation = self.generation
        timer = Timer.scheduledTimer(withTimeInterval: debounce, repeats: false) { [weak self] _ in
            self?.run(window, generation: generation)
        }
    }

    public func cancel() {
        timer?.invalidate()
        timer = nil
        generation &+= 1
    }

    private func run(_ window: String, generation: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            let found = (try? self.noteIndex.related(
                to: window, in: self.documentID, limit: self.limit)) ?? []
            DispatchQueue.main.async {
                guard generation == self.generation else { return }
                self.publish(found)
            }
        }
    }

    private func publish(_ found: [NoteHit]) {
        hits = found
        topMatch = found.first
        observer?.relatedNotesRanker(self, didRank: found, topMatch: topMatch)
    }
}
