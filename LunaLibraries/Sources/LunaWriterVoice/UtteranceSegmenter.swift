import Foundation

/// One finished span of speech: the text a transcriber settled on, and when
/// it started and ended.
public struct Utterance: Equatable, Sendable {
    public let text: String
    public let startedAt: Date
    public let endedAt: Date
}

/// Turns a transcriber's partial results into finished utterances.
///
/// A partial REPLACES the pending text rather than appending to it — a
/// transcriber re-sends its whole best guess on every partial, not a
/// delta. A boundary closes the pending utterance on a final result, on
/// 400 ms with no new partial, or on a 20 s hard cap — whichever comes
/// first. The segmenter owns no timer: a caller with its own clock (a
/// transcriber's tap callback, or a test) decides when to call `tick()`.
public final class UtteranceSegmenter {

    public static let silenceTimeout: TimeInterval = 0.4
    public static let maximumDuration: TimeInterval = 20.0

    private let now: () -> Date
    private var isActive = false
    private var text = ""
    private var startedAt = Date.distantPast
    private var lastUpdateAt = Date.distantPast

    /// `now` is a seam for tests; production code takes the default clock.
    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// Feeds a partial transcript, replacing whatever was pending. Returns a
    /// finished utterance only if the 20 s cap forces the PREVIOUS one closed
    /// first — the caller starts a fresh partial right after.
    @discardableResult
    public func receivePartial(_ text: String) -> Utterance? {
        let time = now()
        var flushed: Utterance?
        if isActive, time.timeIntervalSince(startedAt) >= Self.maximumDuration {
            flushed = close(at: time)
        }
        if !isActive {
            isActive = true
            startedAt = time
        }
        self.text = text
        lastUpdateAt = time
        return flushed
    }

    /// A final ASR result. Always closes the utterance, even an empty one.
    @discardableResult
    public func receiveFinal(_ text: String) -> Utterance {
        let time = now()
        if !isActive { startedAt = time }
        isActive = true
        self.text = text
        return close(at: time)
    }

    /// Caller-driven clock tick: closes the pending utterance if 400 ms have
    /// passed since the last partial, or if the 20 s cap has been reached.
    /// Returns `nil` while nothing is pending or neither boundary is hit yet.
    public func tick() -> Utterance? {
        guard isActive else { return nil }
        let time = now()
        if time.timeIntervalSince(lastUpdateAt) >= Self.silenceTimeout { return close(at: time) }
        if time.timeIntervalSince(startedAt) >= Self.maximumDuration { return close(at: time) }
        return nil
    }

    /// Discards any pending utterance without emitting it.
    public func reset() {
        isActive = false
        text = ""
    }

    private func close(at time: Date) -> Utterance {
        let utterance = Utterance(text: text, startedAt: startedAt, endedAt: time)
        isActive = false
        text = ""
        return utterance
    }
}
