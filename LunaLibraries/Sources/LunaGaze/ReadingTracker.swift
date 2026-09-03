//
//  ReadingTracker.swift
//  LunaGaze
//

import CoreGraphics
import Foundation

/// The thresholds the reading model runs on. Every distance is stated in
/// degrees of visual angle and converted once, against the session's
/// points-per-degree.
public struct ReadingTrackerConfiguration: Equatable {

    /// How long a stall at the end of a sentence is allowed to last before the
    /// model moves on by itself.
    public struct AutoAdvance: Equatable {
        /// Gaze mode, weak signal.
        public var gazeLow: TimeInterval
        /// Gaze mode, strong signal: give the eyes longer to say so themselves.
        public var gazeHigh: TimeInterval
        /// Auto mode. Here the stall IS the pacing, so it is short.
        public var auto: TimeInterval

        public init(gazeLow: TimeInterval = 0.9, gazeHigh: TimeInterval = 1.4, auto: TimeInterval = 0.26) {
            self.gazeLow = gazeLow
            self.gazeHigh = gazeHigh
            self.auto = auto
        }
    }

    /// Vertical width of a sentence's likelihood.
    public var sigmaYDegrees: CGFloat
    /// How much broader the horizontal likelihood is. Horizontal gaze carries
    /// far less information about which sentence is being read.
    public var sigmaXFactor: CGFloat
    /// How long a rival sentence must keep winning before the model switches.
    public var switchDelay: TimeInterval
    /// Reading speed assumed before anything is measured.
    public var initialWordsPerMinute: Double
    /// Bounds the learned reading speed is held inside.
    public var wordsPerMinuteBounds: ClosedRange<Double>
    /// How long the gaze must sit on a distant word before the cursor jumps.
    public var snapDwell: TimeInterval
    /// How far from the modelled cursor a word must be for a jump to be worth
    /// making, in words.
    public var snapMinimumIndexDelta: Int
    public var autoAdvance: AutoAdvance
    /// Quality under which the signal counts as bad.
    public var qualityFloor: Double
    /// How long the signal must stay bad before the model gives up on gaze.
    public var qualityDropDelay: TimeInterval
    /// Quality above which the model trusts gaze.
    public var gazeModeQuality: Double
    /// Quality the sweep needs before gaze may steer it.
    public var sweepQuality: Double
    /// Quality above which a stall gets the longer auto-advance limit.
    public var autoAdvanceQuality: Double
    /// How far ahead of the cursor the gaze must be to speed the sweep up.
    public var paceLeadDegrees: CGFloat
    /// How close the gaze must sit to a word for a jump to it.
    public var snapDistanceDegrees: CGFloat
    /// Longest step the sweep will take for one tick. A tick after a stall
    /// must not advance the cursor by a paragraph.
    public var maximumTickInterval: TimeInterval

    public init(
        sigmaYDegrees: CGFloat = 2.0,
        sigmaXFactor: CGFloat = 4.2,
        switchDelay: TimeInterval = 0.48,
        initialWordsPerMinute: Double = 230,
        wordsPerMinuteBounds: ClosedRange<Double> = 120...520,
        snapDwell: TimeInterval = 0.40,
        snapMinimumIndexDelta: Int = 5,
        autoAdvance: AutoAdvance = AutoAdvance(),
        qualityFloor: Double = 0.22,
        qualityDropDelay: TimeInterval = 2.5,
        gazeModeQuality: Double = 0.4,
        sweepQuality: Double = 0.45,
        autoAdvanceQuality: Double = 0.6,
        paceLeadDegrees: CGFloat = 1.5,
        snapDistanceDegrees: CGFloat = 1.9,
        maximumTickInterval: TimeInterval = 0.08
    ) {
        self.sigmaYDegrees = sigmaYDegrees
        self.sigmaXFactor = sigmaXFactor
        self.switchDelay = switchDelay
        self.initialWordsPerMinute = initialWordsPerMinute
        self.wordsPerMinuteBounds = wordsPerMinuteBounds
        self.snapDwell = snapDwell
        self.snapMinimumIndexDelta = snapMinimumIndexDelta
        self.autoAdvance = autoAdvance
        self.qualityFloor = qualityFloor
        self.qualityDropDelay = qualityDropDelay
        self.gazeModeQuality = gazeModeQuality
        self.sweepQuality = sweepQuality
        self.autoAdvanceQuality = autoAdvanceQuality
        self.paceLeadDegrees = paceLeadDegrees
        self.snapDistanceDegrees = snapDistanceDegrees
        self.maximumTickInterval = maximumTickInterval
    }
}

/// What the reading model believes right now.
public struct ReadingState: Equatable {

    public enum Mode: String, Equatable {
        /// The gaze is steering. The highlight follows the reader.
        case gaze
        /// The gaze is not usable. The highlight runs on the reading-speed
        /// model alone, which is still a better guess than stopping.
        case auto
    }

    /// The sentence being read, or nil before a layout is set.
    public var activeSentence: Int?
    /// Index of the last word taken as read, or -1 when none is.
    public var readUpToWord: Int
    /// The word under the sweep cursor.
    public var cursorWord: Int?
    public var mode: Mode
    /// Rolling confidence in the gaze signal, 0…1.
    public var quality: Double
    /// Rolling vertical distance from the gaze to the active sentence, in
    /// points. A residual that will not come down means the calibration has
    /// drifted.
    public var residual: CGFloat

    public init(
        activeSentence: Int?, readUpToWord: Int, cursorWord: Int?,
        mode: Mode, quality: Double, residual: CGFloat
    ) {
        self.activeSentence = activeSentence
        self.readUpToWord = readUpToWord
        self.cursorWord = cursorWord
        self.mode = mode
        self.quality = quality
        self.residual = residual
    }
}

/// Tracks which sentence a reader is on, and how far into it.
///
/// The hidden state is a sentence index; the observation is a fixation point in
/// the text container's coordinates. Gaze resolves to a band, never to a word,
/// so a Gaussian likelihood per sentence cannot on its own separate "this
/// sentence" from "the next one": consecutive lines sit closer together than
/// the vertical error. What separates them is a transition prior over how
/// readers move, weighted by how far into the current sentence the sweep has
/// got. The word cursor inside a sentence is MODELLED from an adaptive reading
/// speed and only nudged by horizontal gaze — with one exception, the snap,
/// which is how a regression to an earlier word gets caught.
///
/// Nothing here reads a clock. The caller supplies the time, so a whole reading
/// session can be replayed in a test in microseconds.
public final class ReadingTracker {

    public private(set) var configuration: ReadingTrackerConfiguration
    /// Points subtended by one degree of visual angle in this session.
    public let pointsPerDegree: CGFloat

    private var sentences: [SentenceLayout] = []
    private var sentenceIndex = 0
    private var progress: Double = 0
    private var wpm: Double
    private var quality: Double = 0
    private var mode: ReadingState.Mode = .auto
    private var residual: CGFloat = 0

    private var candidate: Int?
    private var candidateSince: TimeInterval = 0
    private var enteredAt: TimeInterval = 0
    private var doneAt: TimeInterval?
    private var snapCandidate: Int?
    private var snapSince: TimeInterval = 0
    private var badSince: TimeInterval?

    private var best: Int?
    private var bestScore: Double = 0
    private var bestRaw: Double = 0
    private var currentScore: Double = 0

    private var lastGaze: CGPoint?
    private var lastGateReason: GateReason = .ok
    private var hasGaze = false
    private var lastTime: TimeInterval = 0
    private var lastTickTime: TimeInterval?
    private var started = false

    private let sigmaY: Double
    private let sigmaX: Double
    private let paceLead: CGFloat
    private let snapDistance: CGFloat

    public init(
        configuration: ReadingTrackerConfiguration = ReadingTrackerConfiguration(),
        pointsPerDegree: CGFloat
    ) {
        self.configuration = configuration
        self.pointsPerDegree = pointsPerDegree
        self.wpm = configuration.initialWordsPerMinute
        self.sigmaY = Double(configuration.sigmaYDegrees * pointsPerDegree)
        self.sigmaX = Double(configuration.sigmaYDegrees * pointsPerDegree * configuration.sigmaXFactor)
        self.paceLead = configuration.paceLeadDegrees * pointsPerDegree
        self.snapDistance = configuration.snapDistanceDegrees * pointsPerDegree
    }

    // MARK: - Layout

    /// Replaces the geometry. Text that re-wraps keeps the reader's place: the
    /// sentence index survives, the sweep inside it does not.
    public func setLayout(_ sentences: [SentenceLayout]) {
        self.sentences = sentences
        guard !sentences.isEmpty else {
            started = false
            return
        }
        sentenceIndex = min(sentenceIndex, sentences.count - 1)
        if !started { resetTo(sentence: 0) }
    }

    /// The learned reading speed, in words per minute.
    public var wordsPerMinute: Double { wpm }

    /// Everything the model believes, as one value.
    public var state: ReadingState {
        guard started, sentences.indices.contains(sentenceIndex) else {
            return ReadingState(
                activeSentence: nil, readUpToWord: -1, cursorWord: nil,
                mode: mode, quality: quality, residual: residual)
        }
        let sentence = sentences[sentenceIndex]
        guard !sentence.words.isEmpty else {
            return ReadingState(
                activeSentence: sentenceIndex, readUpToWord: -1, cursorWord: nil,
                mode: mode, quality: quality, residual: residual)
        }
        let last = sentence.words.count - 1
        let floorIndex = Int(progress.rounded(.down))
        return ReadingState(
            activeSentence: sentenceIndex,
            readUpToWord: max(-1, min(floorIndex - 1, last)),
            cursorWord: min(max(floorIndex, 0), last),
            mode: mode,
            quality: quality,
            residual: residual)
    }

    /// Every word sharing the visual line of `word` in `sentence`. The voice
    /// anchor attaches an utterance to this range.
    public func lineRange(aroundWord word: Int, in sentence: Int) -> Range<Int> {
        guard sentences.indices.contains(sentence) else { return 0..<0 }
        return sentences[sentence].lineRange(around: word)
    }

    /// Puts the reader at the start of a sentence and forgets the sweep.
    public func resetTo(sentence: Int) {
        guard !sentences.isEmpty else { return }
        sentenceIndex = min(max(sentence, 0), sentences.count - 1)
        progress = 0
        candidate = nil
        candidateSince = 0
        enteredAt = lastTime
        doneAt = nil
        snapCandidate = nil
        started = true
    }

    // MARK: - Observation

    /// Feeds one observation. `gaze` is in the text container's coordinates;
    /// pass nil when the frame produced none.
    ///
    /// A caller with no gaze source at all passes `gaze: nil, gate: .ok`, which
    /// leaves the model sweeping on its reading-speed estimate alone.
    public func ingest(gaze: CGPoint?, gate: GateReason, at time: TimeInterval) {
        lastTime = time
        guard !sentences.isEmpty else { return }
        if !started { resetTo(sentence: 0) }

        lastGaze = gaze
        lastGateReason = gate
        hasGaze = gaze != nil && gate == .ok
        score(now: time)
        if hasGaze { trackSwitch(now: time) }
    }

    /// Advances the sweep to `time` and returns the new state.
    @discardableResult
    public func tick(at time: TimeInterval) -> ReadingState {
        lastTime = time
        guard !sentences.isEmpty else { return state }
        if !started { resetTo(sentence: 0) }

        let elapsed = min(configuration.maximumTickInterval, max(0, time - (lastTickTime ?? time)))
        lastTickTime = time
        // Blink, face gone, or eyes off the page: freeze the highlight where it
        // is rather than guess through it.
        guard lastGateReason == .ok else { return state }
        sweep(now: time, elapsed: elapsed)
        return state
    }

    // MARK: - Scoring

    /// Transition prior over how far the reader moved.
    ///
    /// Consecutive sentences sit closer together than the vertical gaze error,
    /// so the likelihood alone can never separate them. What breaks the tie is
    /// where in the sentence the sweep is: staying put gets less likely as the
    /// sweep nears the end, and moving on gets more likely. `done` is the
    /// fraction of the current sentence already swept.
    static func prior(delta: Int, done: Double) -> Double {
        switch delta {
        case 0: return 1.0 - 0.55 * done
        case 1: return 0.45 + 0.75 * done
        case 2: return 0.15 + 0.25 * done
        case -1: return 0.34
        case -2: return 0.26
        case -3: return 0.16
        default: return 0.10
        }
    }

    private func score(now: TimeInterval) {
        guard hasGaze, let gaze = lastGaze else {
            quality = max(0, quality - 0.02)
            if quality < configuration.qualityFloor {
                if badSince == nil { badSince = now }
                if let badSince, now - badSince > configuration.qualityDropDelay { mode = .auto }
            }
            return
        }

        let current = sentences[sentenceIndex]
        let done = current.wordCount > 0
            ? min(1, progress / Double(current.wordCount))
            : 0

        var bestRawValue: Double = 0
        var bestIndex: Int?
        var bestScoreValue: Double = 0
        var bestOwnRaw: Double = 0
        var currentScoreValue: Double = 0

        for (index, sentence) in sentences.enumerated() {
            let dy = Double(sentence.verticalDistance(to: gaze.y))
            let dx = Double(sentence.horizontalDistance(to: gaze.x))
            guard dy.isFinite, dx.isFinite else { continue }
            let raw = exp(-(dy * dy) / (2 * sigmaY * sigmaY))
                * exp(-(dx * dx) / (2 * sigmaX * sigmaX))
            let scored = raw * Self.prior(delta: index - sentenceIndex, done: done)
            if raw > bestRawValue { bestRawValue = raw }
            if scored > bestScoreValue {
                bestScoreValue = scored
                bestIndex = index
                bestOwnRaw = raw
            }
            if index == sentenceIndex { currentScoreValue = scored }
        }

        best = bestIndex
        bestScore = bestScoreValue
        bestRaw = bestOwnRaw
        currentScore = currentScoreValue

        // "The gaze landed on some text" is the proxy for signal quality. It
        // decays fast once the gaze wanders off the column.
        let target = bestRawValue > 0.35 ? 1.0 : (bestRawValue > 0.12 ? 0.5 : 0.0)
        quality = quality * 0.94 + target * 0.06

        residual = residual * 0.95 + current.verticalDistance(to: gaze.y) * 0.05

        if quality > configuration.gazeModeQuality {
            mode = .gaze
            badSince = nil
        } else if quality < configuration.qualityFloor {
            if badSince == nil { badSince = now }
            if let badSince, now - badSince > configuration.qualityDropDelay { mode = .auto }
        }
    }

    private func trackSwitch(now: TimeInterval) {
        func drop() {
            candidate = nil
            candidateSince = 0
        }
        guard let best, best != sentenceIndex else { return drop() }
        // The gaze must be sitting on that sentence, not merely winning on
        // prior, and it must beat staying put by a real margin. Without both
        // the highlight jitters between neighbours.
        guard bestRaw >= 0.25, bestScore >= currentScore * 1.25 else { return drop() }
        guard candidate == best else {
            candidate = best
            candidateSince = now
            return
        }
        if now - candidateSince >= configuration.switchDelay {
            commit(to: best, now: now, learn: true)
        }
    }

    private func commit(to index: Int, now: TimeInterval, learn: Bool) {
        if learn, sentences.indices.contains(sentenceIndex), index > sentenceIndex, enteredAt > 0 {
            learnReadingSpeed(of: sentences[sentenceIndex], now: now)
        }
        sentenceIndex = index
        progress = 0
        candidate = nil
        candidateSince = 0
        enteredAt = now
        doneAt = nil
        snapCandidate = nil
    }

    /// Learns the reader's speed from a sentence they finished.
    ///
    /// Only a sentence the sweep genuinely covered says anything: a switch made
    /// two words in measures the switch, not the reading.
    private func learnReadingSpeed(of sentence: SentenceLayout, now: TimeInterval) {
        let dwell = now - enteredAt
        let words = Double(max(1, min(sentence.wordCount, Int(progress.rounded()))))
        guard dwell > 0.5, dwell < 25,
              words >= 4, progress >= 0.6 * Double(sentence.wordCount)
        else { return }
        let observed = words / (dwell / 60)
        guard observed > 70, observed < 750 else { return }
        let blended = wpm * 0.82 + observed * 0.18
        wpm = min(max(blended, configuration.wordsPerMinuteBounds.lowerBound),
                  configuration.wordsPerMinuteBounds.upperBound)
    }

    // MARK: - Sweep

    private func sweep(now: TimeInterval, elapsed: TimeInterval) {
        let sentence = sentences[sentenceIndex]
        var pace = 1.0

        if hasGaze, let gaze = lastGaze, quality > configuration.sweepQuality, !sentence.words.isEmpty {
            let cursor = min(max(Int(progress.rounded(.down)), 0), sentence.words.count - 1)
            let ahead = gaze.x - sentence.words[cursor].centre.x
            if ahead > paceLead {
                pace = 1.35
            } else if ahead < -paceLead {
                pace = 0.72
            }
            snapIfDwelling(sentence: sentence, gaze: gaze, now: now)
        }

        let wordsPerSecond = (wpm * pace) / 60
        progress = min(Double(sentence.wordCount), progress + wordsPerSecond * elapsed)

        guard progress >= Double(sentence.wordCount) else { return }
        if doneAt == nil { doneAt = now }
        let stalled = now - (doneAt ?? now)
        // In auto mode this stall IS the pacing. In gaze mode it is a safety
        // net for a signal that never gives a clean enough switch.
        let limit: TimeInterval
        if mode == .auto {
            limit = configuration.autoAdvance.auto
        } else {
            limit = quality < configuration.autoAdvanceQuality
                ? configuration.autoAdvance.gazeLow
                : configuration.autoAdvance.gazeHigh
        }
        if stalled > limit, sentenceIndex + 1 < sentences.count {
            commit(to: sentenceIndex + 1, now: now, learn: false)
        }
    }

    /// Re-anchors the cursor onto a word the gaze is plainly sitting on.
    ///
    /// This is how a regression — the reader going back to re-read — is caught.
    /// The dwell requirement is what keeps a glance from moving the cursor.
    private func snapIfDwelling(sentence: SentenceLayout, gaze: CGPoint, now: TimeInterval) {
        guard let near = sentence.nearestWord(to: gaze),
              near.distance < snapDistance,
              abs(Double(near.index) - progress) > Double(configuration.snapMinimumIndexDelta)
        else {
            snapCandidate = nil
            return
        }
        guard snapCandidate == near.index else {
            snapCandidate = near.index
            snapSince = now
            return
        }
        if now - snapSince > configuration.snapDwell {
            progress = Double(near.index)
            snapCandidate = nil
        }
    }
}
