import Foundation

/// Receives the tags of one paragraph. The editor's syntax layer is the
/// production witness; it applies the colours when they arrive.
public protocol POSTaggingObserving: AnyObject {
    func posTagging(_ service: POSTaggingService, didTag spans: [POSSpan], forParagraphIn range: NSRange, revision: Int)
}

/// Tags paragraphs away from the main thread and remembers the answers.
/// One paragraph has at most one job in flight: a new request for the same
/// paragraph start replaces the one before it, and scrolling away cancels it.
///
/// The paragraph text is copied on the caller's thread, so the tagger never
/// reads a string the editor is changing.
public final class POSTaggingService {
    private let tagger: ParagraphTagging
    private let workQueue: DispatchQueue
    private let deliveryQueue: DispatchQueue
    private let lock = NSLock()
    private var cache: LRUCache<String, [POSSpan]>
    /// One job per paragraph BODY, not per screen position: a paragraph's
    /// location moves when text above it changes, so keying on location
    /// would orphan the running job instead of superseding it.
    private var inFlight: [String: Job] = [:]
    /// The body each location's most recent request asked to tag, so
    /// `cancelParagraph(at:)` can still cancel by position.
    private var locationBodies: [Int: String] = [:]

    public weak var observer: POSTaggingObserving?

    public init(
        tagger: ParagraphTagging = PartOfSpeechTagger(),
        cacheLimit: Int = 256,
        workQueue: DispatchQueue = DispatchQueue(label: "com.luna.writer.pos", qos: .utility),
        deliveryQueue: DispatchQueue = .main
    ) {
        self.tagger = tagger
        self.workQueue = workQueue
        self.deliveryQueue = deliveryQueue
        cache = LRUCache(limit: cacheLimit)
    }

    /// The tags of a paragraph already seen, ready to draw this frame.
    public func cachedTags(forParagraphIn range: NSRange, of text: NSString) -> [POSSpan]? {
        guard range.length > 0, NSMaxRange(range) <= text.length else { return nil }
        let body = text.substring(with: range)
        lock.lock()
        let cached = cache.value(for: body)
        lock.unlock()
        return cached.map { shift($0, by: range.location) }
    }

    /// Asks for the tags of one paragraph. `revision` comes back untouched,
    /// so the caller can drop an answer about text it has already replaced.
    public func requestTags(forParagraphIn range: NSRange, of text: NSString, revision: Int) {
        guard range.length > 0, NSMaxRange(range) <= text.length else { return }
        let body = text.substring(with: range)
        let location = range.location

        lock.lock()
        let cached = cache.value(for: body)
        lock.unlock()
        if let cached {
            deliver(shift(cached, by: location), range: range, revision: revision)
            return
        }

        lock.lock()
        if let previousBody = locationBodies[location], previousBody != body {
            inFlight.removeValue(forKey: previousBody)?.isCancelled = true
        }
        locationBodies[location] = body
        let job = inFlight[body] ?? Job()
        inFlight[body] = job
        lock.unlock()

        workQueue.async { [weak self] in
            guard let self, !self.isCancelled(job) else { return }
            let spans = self.tagger.tags(ofParagraph: body)
            self.lock.lock()
            self.cache.insert(spans, for: body)
            let cancelled = job.isCancelled
            if self.inFlight[body] === job { self.inFlight[body] = nil }
            self.lock.unlock()
            guard !cancelled else { return }
            self.deliver(self.shift(spans, by: location), range: range, revision: revision)
        }
    }

    /// Drops the job for the paragraph that starts at `location`.
    public func cancelParagraph(at location: Int) {
        lock.lock()
        if let body = locationBodies.removeValue(forKey: location) {
            inFlight.removeValue(forKey: body)?.isCancelled = true
        }
        lock.unlock()
    }

    public func cancelAll() {
        lock.lock()
        inFlight.values.forEach { $0.isCancelled = true }
        inFlight.removeAll()
        locationBodies.removeAll()
        lock.unlock()
    }

    private func isCancelled(_ job: Job) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return job.isCancelled
    }

    /// One tagging job. Cancelling flips the flag the job reads before it
    /// tags and again before it answers.
    private final class Job {
        var isCancelled = false
    }

    private func deliver(_ spans: [POSSpan], range: NSRange, revision: Int) {
        deliveryQueue.async { [weak self] in
            guard let self else { return }
            self.observer?.posTagging(self, didTag: spans, forParagraphIn: range, revision: revision)
        }
    }

    private func shift(_ spans: [POSSpan], by offset: Int) -> [POSSpan] {
        guard offset != 0 else { return spans }
        return spans.map { POSSpan(range: NSRange(location: $0.range.location + offset, length: $0.range.length), pos: $0.pos) }
    }
}
