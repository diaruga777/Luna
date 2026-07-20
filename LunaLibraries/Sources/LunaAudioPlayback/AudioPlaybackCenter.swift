//
//  AudioPlaybackCenter.swift
//  LunaAudioPlayback
//

import AVFoundation
import LunaModels
import LunaStorage
import Foundation

/// Playback lifecycle. `announcing` covers the whole autoplay transition
/// (transition chime -> "Now Reading — <title>" -> chime) between one
/// article's body finishing and the next one's body starting.
public enum AudioPlaybackState: Equatable {
    case idle
    case playing(itemID: UUID)
    case announcing(nextItemID: UUID)
    case paused(itemID: UUID)
}

/// The currently-playing (or paused/announcing) item's UI-facing identity.
public struct AudioPlaybackItemInfo: Equatable {
    public var itemID: UUID
    public var title: String
    /// The Now Playing "artist" line: the article's author when extraction
    /// found one, else the source host (`www.` stripped), else nil.
    public var artist: String?
    public var thumbnailFileName: String?

    public init(itemID: UUID, title: String, artist: String?, thumbnailFileName: String?) {
        self.itemID = itemID
        self.title = title
        self.artist = artist
        self.thumbnailFileName = thumbnailFileName
    }
}

/// One word becoming current during forward playback, for reader
/// highlighting. `rangeInBlockText` is a UTF-16 range within the ORIGINAL
/// `ArticleContent.Block.text` at `blockIndex`. This needs no re-mapping even
/// with the Phase 4 trimming pass: trimming only ever narrows `AudioScript`
/// to a subset of whole blocks (by `blockIndex`) — every `SpokenBlock` that
/// survives keeps its source block's text verbatim, word-for-word, so a word
/// index/range computed against `SpokenBlock.text` is always valid against
/// the original `ArticleContent.Block.text` at the same `blockIndex`.
public struct AudioWordEvent: Equatable {
    public var blockIndex: Int
    public var rangeInBlockText: NSRange

    public init(blockIndex: Int, rangeInBlockText: NSRange) {
        self.blockIndex = blockIndex
        self.rangeInBlockText = rangeInBlockText
    }
}

/// The Phase 6 extension → main-app playback handoff's launch-time preview:
/// enough to show the mini-player in a paused state (title/thumbnail) before
/// any playback session exists, WITHOUT starting the engine/session — see
/// `AudioPlaybackCenter.restorableHandoffIfAvailable()`. Tapping play resumes
/// via the EXISTING `restorePersistedSessionIfAvailable()`, never a
/// half-initialized paused state grafted onto this struct.
public struct AudioPlaybackHandoff: Equatable {
    public var itemID: UUID
    public var title: String
    public var thumbnailFileName: String?
    /// A rough progress estimate (persisted word index over the article's
    /// total, untrimmed, word count) — good enough for a paused preview's
    /// progress bar; never the authoritative value a live session computes
    /// from its actual `AudioScript`.
    public var progressFraction: Double

    public init(
        itemID: UUID, title: String, thumbnailFileName: String?, progressFraction: Double
    ) {
        self.itemID = itemID
        self.title = title
        self.thumbnailFileName = thumbnailFileName
        self.progressFraction = progressFraction
    }
}

/// A point-in-time read of everything the mini-player / Now Playing / reader
/// highlighting need, computed on demand from the center's internal counters
/// (see `AudioPlaybackCenter.currentSnapshot`).
public struct AudioPlaybackSnapshot {
    public var state: AudioPlaybackState
    public var itemInfo: AudioPlaybackItemInfo?
    public var progressFraction: Double
    public var elapsed: TimeInterval
    public var estimatedDuration: TimeInterval
    public var rate: Float
    /// True during `.playing`/`.announcing`, false for `.idle`/`.paused` —
    /// distinct from `state` itself so observers don't need to pattern-match
    /// just to decide whether a play/pause button should show a pause glyph.
    public var isAudiblyPlaying: Bool
}

/// Multicast observer for `AudioPlaybackCenter`. Every method has a default
/// (empty) implementation, so conformers only implement what they use.
/// Delivered on the main thread; observers are held weakly.
public protocol AudioPlaybackObserver: AnyObject {
    func audioPlaybackCenter(_ center: AudioPlaybackCenter, didChangeState state: AudioPlaybackState)
    func audioPlaybackCenter(_ center: AudioPlaybackCenter, didUpdateItem info: AudioPlaybackItemInfo?)
    func audioPlaybackCenter(
        _ center: AudioPlaybackCenter, didUpdateProgress fraction: Double,
        elapsed: TimeInterval, duration: TimeInterval)
    func audioPlaybackCenter(_ center: AudioPlaybackCenter, didEmitWordEvent event: AudioWordEvent)
}

public extension AudioPlaybackObserver {
    func audioPlaybackCenter(_ center: AudioPlaybackCenter, didChangeState state: AudioPlaybackState) {}
    func audioPlaybackCenter(_ center: AudioPlaybackCenter, didUpdateItem info: AudioPlaybackItemInfo?) {}
    func audioPlaybackCenter(
        _ center: AudioPlaybackCenter, didUpdateProgress fraction: Double,
        elapsed: TimeInterval, duration: TimeInterval) {}
    func audioPlaybackCenter(_ center: AudioPlaybackCenter, didEmitWordEvent event: AudioWordEvent) {}
}

/// The app-wide singleton and single owner of read-aloud playback: offline
/// rendering via `SpeechRendering` -> scheduling via
/// `ArticleAudioEngineControlling`, the autoplay chain, position persistence,
/// and session-interruption handling. See
/// `claudedocs/audio-playback-plan.md` ("Phase 2: Playback center + system
/// integration").
///
/// Every dependency is injected behind a protocol (see
/// `AudioPlaybackSeams.swift`) specifically so tests can exercise the STATE
/// MACHINE / QUEUE / AUTOPLAY / PERSISTENCE logic with fast, deterministic
/// fakes instead of real `AVSpeechSynthesizer`/`AVAudioEngine`/
/// `AVAudioSession` — this class owns real Apple frameworks in production via
/// its default parameter values only.
public final class AudioPlaybackCenter {
    public static let shared = AudioPlaybackCenter()

    /// Default estimate for words-not-yet-rendered-this-session (bootstrap,
    /// and for any words skipped past by a resume/seek) — roughly 170 words
    /// per minute, a reasonable spoken-word rate. Replaced by the real
    /// running average the moment at least one block has been rendered this
    /// session.
    private static let defaultSecondsPerWord: TimeInterval = 0.35
    private static let fallbackFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 22050, channels: 1, interleaved: false)!
    /// How many rendered-but-not-yet-fully-heard blocks are allowed to be
    /// scheduled ahead of the playhead at once.
    private static let maxBlocksAhead = 2
    /// Phase 6 extension → main-app handoff: a persisted position older than
    /// this is stale and never surfaced as a launch-time paused mini-player
    /// preview (see `restorableHandoffIfAvailable()`). A named constant per
    /// the product requirement ("choose ~30 minutes; make it a constant").
    public static let handoffRecencyWindow: TimeInterval = 30 * 60

    // MARK: - Public state

    public private(set) var state: AudioPlaybackState = .idle {
        didSet {
            guard state != oldValue else { return }
            notifyObservers { $0.audioPlaybackCenter(self, didChangeState: self.state) }
        }
    }

    public private(set) var currentItemInfo: AudioPlaybackItemInfo? {
        didSet {
            guard currentItemInfo != oldValue else { return }
            notifyObservers { $0.audioPlaybackCenter(self, didUpdateItem: self.currentItemInfo) }
        }
    }

    /// Installed by the app shell at launch (see `Luna/AppDelegate.swift` /
    /// `AudioPlaybackAppWiring`). Returns the next queue candidate — the
    /// top-most unopened, readable Reader-surface article in the reading
    /// list's own displayed order — or `nil` when the queue is empty.
    public var nextItemProvider: (() -> QueueCandidate?)?

    /// Phase 4 seam (`claudedocs/audio-playback-plan.md`): resolves the
    /// script to speak for `item`. Defaults to the Phase-1 pass-through (so
    /// nothing regresses if the app shell never overrides it); the app shell
    /// installs `AudioScriptPipeline.shared.script(for:content:)` here at
    /// launch (`Luna/AudioScriptPipelineWiring.swift`) — cache hit, or a
    /// fast synchronous heuristic build on miss. NEVER blocks on the LLM
    /// refinement pass; an upgrade landing later only updates the cache for
    /// the NEXT play of this item, never swaps mid-playback.
    public var scriptProvider: (ReadingListItem, ArticleContent) -> AudioScript = { _, content in
        AudioScript(passthrough: content)
    }

    /// Phase 4 seam: called once the autoplay chain resolves the NEXT queue
    /// candidate (before its transition chime/announcement even starts), so
    /// the app shell can ask the script pipeline to verify/prefetch that
    /// item's script ahead of when playback actually reaches it. Optional —
    /// unset in tests/extensions with no measurable effect on playback.
    public var scriptPrefetchHandler: ((ReadingListItem, ArticleContent) -> Void)?

    public var currentSnapshot: AudioPlaybackSnapshot {
        let totalWords = currentScript?.totalWordCount ?? 0
        let remainingWords = max(0, totalWords - sessionStartWordsSkipped - wordsRenderedSoFar)
        let duration = elapsedBaselineAtResume + renderedDurationSoFar + Double(remainingWords) * avgSecPerWord
        let elapsed = engine?.currentTime ?? elapsedBaselineAtResume
        let fraction = duration > 0 ? min(max(elapsed / duration, 0), 1) : 0
        return AudioPlaybackSnapshot(
            state: state, itemInfo: currentItemInfo, progressFraction: fraction, elapsed: elapsed,
            estimatedDuration: duration, rate: engine?.rate ?? AudioSettings.preferredRate,
            isAudiblyPlaying: isAudiblyPlaying)
    }

    /// The running average seconds-per-word for the current session, or the
    /// bootstrap estimate before any block has been rendered yet — used to
    /// estimate remaining duration and to map a skip/seek's seconds delta to
    /// a word-index delta.
    private var avgSecPerWord: Double {
        wordsRenderedSoFar > 0
            ? (renderedDurationSoFar / Double(wordsRenderedSoFar)) : Self.defaultSecondsPerWord
    }

    private var isAudiblyPlaying: Bool {
        switch state {
        case .playing, .announcing: return true
        case .idle, .paused: return false
        }
    }

    // MARK: - Dependencies (seams)

    private let store: ReadingListPlaybackStore
    private let renderer: SpeechRendering
    private let positionStore: AudioPlaybackPositionStore
    private let sessionCoordinator: AudioSessionControlling
    private let engineFactory: (AVAudioFormat) throws -> ArticleAudioEngineControlling
    private var engine: ArticleAudioEngineControlling?

    // MARK: - Observers

    private final class WeakObserverBox {
        weak var observer: AudioPlaybackObserver?
        init(_ observer: AudioPlaybackObserver) { self.observer = observer }
    }
    private var observers: [WeakObserverBox] = []

    // MARK: - Session/render pipeline state (reset per `beginPlayback`)

    private var currentItem: ReadingListItem?
    private var currentScript: AudioScript?
    private var blockStartWordIndices: [Int] = []
    /// Index into `currentScript.spokenBlocks` of the NEXT block to render.
    private var renderCursor = 0
    /// Whether a `renderer.render(_:)` call is currently in flight — the
    /// renderer only supports one render at a time, so this also serializes
    /// the pump (never two concurrent `render` calls).
    private var isPumping = false
    /// Rendered-and-scheduled blocks not yet fully heard (bounds the
    /// look-ahead to `maxBlocksAhead`).
    private var scheduledNotYetPlayedCount = 0
    /// Absolute content-time (seconds, `ArticleAudioEngine.currentTime`
    /// domain) at which the NEXT segment/tone to be scheduled will begin.
    private var scheduledContentTimeCursor: TimeInterval = 0
    /// Flat, time-ordered queue of word markers for every segment scheduled
    /// this session, with absolute content-time offsets — consumed by the
    /// progress timer to fire word events in sync with `engine.currentTime`.
    private var pendingMarkerQueue: [(absoluteTime: TimeInterval, blockIndex: Int, range: NSRange)] = []
    private var markerCursor = 0
    /// Global word index at the start of the block this SESSION began
    /// rendering from (fixed for the session — used to estimate the content
    /// time "skipped" by a resume/seek, and the words still ahead).
    private var sessionStartWordsSkipped = 0
    /// Content-time estimate for everything before `sessionStartWordsSkipped`
    /// (words this session never renders, having resumed/sought past them).
    private var elapsedBaselineAtResume: TimeInterval = 0
    private var renderedDurationSoFar: TimeInterval = 0
    private var wordsRenderedSoFar = 0
    /// Best-known current position, in the global word-index domain —
    /// updated by word events during forward playback and by every
    /// skip/seek. What gets persisted/mirrored into the store.
    private var lastKnownWordIndex = 0
    /// Bumped on every new session/restart so a straggling render `Task` from
    /// a superseded session can detect it's stale and drop its result.
    private var sessionToken = UUID()
    /// Set when a playback session starts before the engine exists yet (very
    /// first render of the app run): applied to the engine the moment it's
    /// created inside `handleRendered`.
    private var pendingResetOffset: TimeInterval?
    /// The state to return to when a pause is resumed — `.playing` normally,
    /// `.announcing` when the pause landed mid-announcement (the engine's
    /// queue still holds the rest of the announcement/chimes, so resuming
    /// just lets them finish).
    private var stateBeforePause: AudioPlaybackState?

    private var progressTimer: Timer?
    private var positionPersistTimer: Timer?

    // MARK: - Init

    public init(
        store: ReadingListPlaybackStore = ReadingListStore.shared,
        renderer: SpeechRendering = SpeechRenderer(),
        positionStore: AudioPlaybackPositionStore = AudioPlaybackPositionStore(),
        sessionCoordinator: AudioSessionControlling = AudioSessionCoordinator(),
        engineFactory: @escaping (AVAudioFormat) throws -> ArticleAudioEngineControlling = {
            try ArticleAudioEngine(format: $0)
        }
    ) {
        self.store = store
        self.renderer = renderer
        self.positionStore = positionStore
        self.sessionCoordinator = sessionCoordinator
        self.engineFactory = engineFactory
        self.sessionCoordinator.actionHandler = { [weak self] action in
            switch action {
            case .pause: self?.handleExternalPause()
            case .resume: self?.handleExternalResume()
            case .none: break
            }
        }
        self.sessionCoordinator.start()
    }

    // MARK: - Observer registration

    public func addObserver(_ observer: AudioPlaybackObserver) {
        observers.removeAll { $0.observer == nil }
        guard !observers.contains(where: { $0.observer === observer }) else { return }
        observers.append(WeakObserverBox(observer))
    }

    public func removeObserver(_ observer: AudioPlaybackObserver) {
        observers.removeAll { $0.observer === observer || $0.observer == nil }
    }

    private func notifyObservers(_ body: @escaping (AudioPlaybackObserver) -> Void) {
        observers.removeAll { $0.observer == nil }
        let targets = observers.compactMap(\.observer)
        guard !targets.isEmpty else { return }
        if Thread.isMainThread {
            for observer in targets { body(observer) }
        } else {
            DispatchQueue.main.async { for observer in targets { body(observer) } }
        }
    }

    // MARK: - Public controls

    /// Starts (or restarts) playback of `item`. `fromWordIndex`, when nil,
    /// resumes from the persisted position store IF it names this same item;
    /// otherwise (or when explicitly `0`) starts from the top.
    public func play(item: ReadingListItem, content: ArticleContent, fromWordIndex: Int? = nil) {
        beginPlayback(item: item, content: content, fromWordIndex: fromWordIndex)
    }

    public func togglePlayPause() {
        if isAudiblyPlaying {
            pause()
        } else if case .paused = state {
            resume()
        }
    }

    public func pause() {
        pauseInternal(deactivateSessionAfterGrace: true)
    }

    public func resume() {
        guard case .paused(let itemID) = state else { return }
        sessionCoordinator.activate()
        engine?.play()
        startProgressTimer()
        startPositionPersistTimer()
        setState(stateBeforePause ?? .playing(itemID: itemID))
        stateBeforePause = nil
    }

    /// Rebuilds a playback session from the persisted App-Group position —
    /// the cold-background-relaunch path: a lock-screen/AirPods play command
    /// arrives while this center is `.idle` but a previous process persisted
    /// a position. Reloads the item and its content from the store, rebuilds
    /// the pipeline, and resumes (silently — no chime) from the persisted
    /// word index. Returns whether playback was actually restored (`false`
    /// when there's no persisted state, the item was deleted, or its content
    /// is gone).
    @discardableResult
    public func restorePersistedSessionIfAvailable() -> Bool {
        guard case .idle = state else { return false }
        guard let position = positionStore.load(),
              let item = store.item(withID: position.itemID),
              let content = store.content(for: item)
        else { return false }
        beginPlayback(item: item, content: content, fromWordIndex: position.wordIndex)
        return state != .idle
    }

    /// Non-mutating peek for the Phase 6 launch-time paused mini-player
    /// preview: never touches `state`/the engine/the session — a pure read of
    /// whether a RECENT, still-valid persisted position exists. Returns nil
    /// when idle-but-no-position, the position is stale (older than
    /// `handoffRecencyWindow`), or the item/content it names no longer
    /// exists (deleted since the extension wrote it) — the caller's "do
    /// nothing" guard per the product requirement. Deliberately does NOT
    /// build a script (that would defeat "never block playback start" for a
    /// preview nobody may ever tap) — `progressFraction` uses the
    /// untrimmed passthrough word count as a good-enough estimate.
    public func restorableHandoffIfAvailable(now: Date = Date()) -> AudioPlaybackHandoff? {
        guard case .idle = state else { return nil }
        guard let position = positionStore.load(),
              now.timeIntervalSince(position.savedAt) <= Self.handoffRecencyWindow
        else { return nil }
        guard let item = store.item(withID: position.itemID),
              let content = store.content(for: item)
        else { return nil }

        let totalWords = AudioScript(passthrough: content).totalWordCount
        let fraction = totalWords > 0 ? min(max(Double(position.wordIndex) / Double(totalWords), 0), 1) : 0
        let title = position.title.isEmpty ? (item.title ?? content.title) : position.title
        return AudioPlaybackHandoff(
            itemID: item.id, title: title, thumbnailFileName: item.thumbnailFileName,
            progressFraction: fraction)
    }

    private func pauseInternal(deactivateSessionAfterGrace: Bool) {
        let pausedItemID: UUID
        switch state {
        case .playing(let itemID): pausedItemID = itemID
        case .announcing(let nextItemID): pausedItemID = nextItemID
        case .idle, .paused: return
        }
        stateBeforePause = state
        engine?.pause()
        stopProgressTimer()
        stopPositionPersistTimer()
        persistPositionToAppGroup()
        mirrorWordIndexToStore()
        if deactivateSessionAfterGrace {
            sessionCoordinator.scheduleDeactivationAfterUserPause()
        }
        setState(.paused(itemID: pausedItemID))
    }

    /// Jumps to the start of the next paragraph (block).
    public func skipForwardParagraph() {
        guard let script = currentScript, !script.spokenBlocks.isEmpty else { return }
        let position = AudioWordIndexing.spokenBlockPosition(forWordIndex: currentSeekBaseWordIndex(), in: blockStartWordIndices)
        let nextPosition = min(position + 1, script.spokenBlocks.count - 1)
        restartPlayback(fromWordIndex: blockStartWordIndices[safe: nextPosition] ?? 0)
    }

    /// Jumps to the start of the current paragraph, or the previous one when
    /// already at its start — mirrors `SpeechController.skipBackward`.
    public func skipBackwardParagraph() {
        guard currentScript != nil else { return }
        let baseWordIndex = currentSeekBaseWordIndex()
        let position = AudioWordIndexing.spokenBlockPosition(forWordIndex: baseWordIndex, in: blockStartWordIndices)
        let spokenIntoBlock = baseWordIndex > (blockStartWordIndices[safe: position] ?? 0)
        let target = spokenIntoBlock ? position : max(0, position - 1)
        restartPlayback(fromWordIndex: blockStartWordIndices[safe: target] ?? 0)
    }

    /// Maps `seconds` to a word-index delta via the running avg sec/word and
    /// seeks there. Negative `seconds` skips backward (system "skip back 15").
    public func skip(bySeconds seconds: TimeInterval) {
        guard let script = currentScript, script.totalWordCount > 0 else { return }
        guard avgSecPerWord > 0 else { return }
        let deltaWords = Int((seconds / avgSecPerWord).rounded())
        let target = max(0, min(currentSeekBaseWordIndex() + deltaWords, script.totalWordCount - 1))
        restartPlayback(fromWordIndex: target)
    }

    public func seek(toFraction fraction: Double) {
        guard let script = currentScript, script.totalWordCount > 0 else { return }
        let clamped = min(max(fraction, 0), 1)
        let target = min(Int((clamped * Double(script.totalWordCount)).rounded()), script.totalWordCount - 1)
        restartPlayback(fromWordIndex: max(0, target))
    }

    public func cycleRate() {
        let steps = AudioSettings.rateSteps
        let index = steps.firstIndex(of: AudioSettings.preferredRate) ?? 1
        setRate(steps[(index + 1) % steps.count])
    }

    public func setRate(_ rate: Float) {
        AudioSettings.preferredRate = rate
        engine?.rate = AudioSettings.preferredRate
    }

    // MARK: - Playback session lifecycle

    /// Resets every per-session render/schedule counter and re-derives the
    /// render cursor/baseline for a session that will render starting at
    /// `wordIndex` — the shared setup `beginPlayback` (fresh item) and
    /// `restartPlayback` (skip/seek/paragraph-jump within the current item)
    /// both need before they touch the engine.
    private func resetRenderSession(atWordIndex wordIndex: Int) {
        sessionToken = UUID()
        isPumping = false
        scheduledNotYetPlayedCount = 0
        pendingMarkerQueue = []
        markerCursor = 0
        renderedDurationSoFar = 0
        wordsRenderedSoFar = 0

        renderCursor = AudioWordIndexing.spokenBlockPosition(forWordIndex: wordIndex, in: blockStartWordIndices)
        sessionStartWordsSkipped = blockStartWordIndices[safe: renderCursor] ?? 0
        elapsedBaselineAtResume = Double(sessionStartWordsSkipped) * Self.defaultSecondsPerWord
        scheduledContentTimeCursor = elapsedBaselineAtResume
        lastKnownWordIndex = sessionStartWordsSkipped
    }

    private func beginPlayback(item: ReadingListItem, content: ArticleContent, fromWordIndex: Int?) {
        // Phase 4: cache hit, or a fast synchronous heuristic build on miss
        // (see `scriptProvider`'s doc comment) — never the LLM refinement
        // pass, which only ever updates the cache for next time.
        let script = scriptProvider(item, content)
        guard !script.spokenBlocks.isEmpty else { return }

        sessionCoordinator.activate()

        currentItem = item
        currentScript = script
        blockStartWordIndices = AudioWordIndexing.blockStartWordIndices(script.spokenBlocks)

        let resumeWordIndex = fromWordIndex ?? matchingPersistedWordIndex(for: item.id) ?? 0
        resetRenderSession(atWordIndex: resumeWordIndex)

        store.markReadState(.opened, for: item.id)
        stateBeforePause = nil
        setState(.playing(itemID: item.id))
        currentItemInfo = AudioPlaybackItemInfo(
            itemID: item.id, title: item.title ?? content.title,
            artist: Self.artistLine(content: content, item: item),
            thumbnailFileName: item.thumbnailFileName)

        if let engine {
            engine.rate = AudioSettings.preferredRate
            engine.resetAndSchedule(from: elapsedBaselineAtResume)
            pendingResetOffset = nil
        } else {
            pendingResetOffset = elapsedBaselineAtResume
        }

        startProgressTimer()
        startPositionPersistTimer()
        pumpRenderingIfNeeded()
    }

    private static func artistLine(content: ArticleContent, item: ReadingListItem) -> String? {
        if let author = content.author, !author.isEmpty { return author }
        if let host = URL(string: item.urlString)?.host {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return nil
    }

    /// Re-renders/schedules from `wordIndex` onward without tearing down the
    /// current item (used by paragraph skip / `skip(bySeconds:)` / seek).
    private func restartPlayback(fromWordIndex wordIndex: Int) {
        guard let script = currentScript else { return }
        let wasPaused: Bool
        if case .paused = state { wasPaused = true } else { wasPaused = false }

        let clamped = max(0, min(wordIndex, max(0, script.totalWordCount - 1)))
        resetRenderSession(atWordIndex: clamped)

        if let engine {
            engine.resetAndSchedule(from: elapsedBaselineAtResume)
            if wasPaused { engine.pause() }
        } else {
            pendingResetOffset = elapsedBaselineAtResume
        }

        persistPositionToAppGroup()
        mirrorWordIndexToStore()
        pumpRenderingIfNeeded()
    }

    /// The word-index base for user-initiated skip/seek actions. Word-marker
    /// callbacks are best-effort, so use the engine's absolute content clock
    /// to keep controls anchored to the audible playhead even when markers
    /// are delayed or unavailable.
    private func currentSeekBaseWordIndex() -> Int {
        guard let script = currentScript, script.totalWordCount > 0 else { return lastKnownWordIndex }
        guard let engine else { return max(0, min(lastKnownWordIndex, script.totalWordCount - 1)) }
        guard avgSecPerWord > 0 else { return max(0, min(lastKnownWordIndex, script.totalWordCount - 1)) }
        let estimated = Int((engine.currentTime / avgSecPerWord).rounded(.down))
        return max(0, min(max(lastKnownWordIndex, estimated), script.totalWordCount - 1))
    }

    // MARK: - Render/schedule pipeline

    private func pumpRenderingIfNeeded() {
        guard !isPumping else { return }
        guard let script = currentScript else { return }
        guard scheduledNotYetPlayedCount < Self.maxBlocksAhead else { return }
        guard renderCursor < script.spokenBlocks.count else { return }

        let block = script.spokenBlocks[renderCursor]
        renderCursor += 1
        isPumping = true
        let token = sessionToken
        Task { [weak self] in
            guard let self else { return }
            let segment: RenderedSegment
            do {
                segment = try await self.renderer.render(block)
            } catch {
                // Render failure degrades to an empty (silently skippable)
                // segment rather than stalling the article — the same
                // "empty segment is always valid" contract `SpeechRenderer`
                // documents for its own simulator quirk.
                segment = RenderedSegment(
                    blockIndex: block.blockIndex, buffers: [], wordMarkers: [], duration: 0,
                    format: self.renderer.canonicalFormat ?? Self.fallbackFormat)
            }
            DispatchQueue.main.async {
                guard token == self.sessionToken else { return } // superseded session
                self.isPumping = false
                self.handleRendered(segment)
            }
        }
    }

    private func handleRendered(_ segment: RenderedSegment) {
        guard currentScript != nil else { return }
        if engine == nil {
            do {
                engine = try engineFactory(segment.format)
                engine?.needsMoreAudioHandler = { [weak self] in self?.pumpRenderingIfNeeded() }
            } catch {
                setState(.idle)
                return
            }
        }
        if let offset = pendingResetOffset {
            engine?.rate = AudioSettings.preferredRate
            engine?.resetAndSchedule(from: offset)
            pendingResetOffset = nil
        }
        scheduleRendered(segment)
        // The user may have paused while this block was still rendering (a
        // freshly created engine — and resetAndSchedule — both leave the
        // player node running): honor the pause.
        if case .paused = state { engine?.pause() }
        pumpRenderingIfNeeded()
    }

    private func scheduleRendered(_ segment: RenderedSegment) {
        guard let script = currentScript else { return }
        let segmentStart = scheduledContentTimeCursor
        for marker in segment.wordMarkers {
            let absoluteTime = segmentStart + Double(marker.sampleOffset) / segment.format.sampleRate
            pendingMarkerQueue.append((absoluteTime, segment.blockIndex, marker.utteranceRange))
        }
        scheduledContentTimeCursor += segment.duration
        renderedDurationSoFar += segment.duration
        if let spokenBlock = script.spokenBlocks.first(where: { $0.blockIndex == segment.blockIndex }) {
            wordsRenderedSoFar += AudioWordIndexing.wordCount(in: spokenBlock.text)
        }

        scheduledNotYetPlayedCount += 1
        let token = sessionToken
        engine?.schedule(segment, rateMode: .followsUserRate) { [weak self] in
            guard let self, token == self.sessionToken else { return }
            self.scheduledNotYetPlayedCount -= 1
            self.pumpRenderingIfNeeded()
            if let script = self.currentScript,
               self.renderCursor >= script.spokenBlocks.count, self.scheduledNotYetPlayedCount == 0 {
                self.handleArticleBodyFinished()
            }
        }
    }

    // MARK: - Autoplay chain

    /// NOTE on the `token` guards throughout this chain: stopping the player
    /// node (which `resetAndSchedule` does on every new `play`/seek) fires
    /// the completion handlers of everything still queued on it — so a chime
    /// or announcement completion can arrive AFTER the user has already
    /// started different playback. Every step of the chain therefore
    /// captures the session token it was scheduled under and drops itself if
    /// a newer session has superseded it.
    private func handleArticleBodyFinished() {
        guard let item = currentItem else { return }
        store.markFinishedReading(item.id)
        stopProgressTimer()
        stopPositionPersistTimer()
        persistPositionToAppGroup()
        mirrorWordIndexToStore()

        // Autoplay is re-read fresh HERE, at the boundary (and re-checked
        // again after the announcement) — the user can toggle it mid-article.
        guard AudioSettings.isAutoplayEnabled, let candidate = nextItemProvider?() else {
            playFinalChimeThenIdle()
            return
        }
        // Phase 4: verify/prefetch the resolved candidate's script now, well
        // before playback actually reaches it (transition chime +
        // announcement + another chime still have to play first).
        scriptPrefetchHandler?(candidate.item, candidate.content)
        let token = sessionToken
        playTransitionChime { [weak self] in
            guard let self, token == self.sessionToken else { return }
            self.playAnnouncement(for: candidate)
        }
    }

    private func playTransitionChime(completion: @escaping () -> Void) {
        guard let engine else { completion(); return }
        do {
            try engine.scheduleTone(.transition, completion: completion)
        } catch {
            completion()
        }
    }

    private func playAnnouncement(for candidate: QueueCandidate) {
        setState(.announcing(nextItemID: candidate.item.id))
        let title = candidate.item.title ?? candidate.content.title
        let announcementBlock = AudioScript.SpokenBlock(blockIndex: -1, text: "Now Reading — \(title)")
        let token = sessionToken
        Task { [weak self] in
            guard let self else { return }
            let segment: RenderedSegment
            do {
                segment = try await self.renderer.render(announcementBlock)
            } catch {
                segment = RenderedSegment(
                    blockIndex: -1, buffers: [], wordMarkers: [], duration: 0,
                    format: self.renderer.canonicalFormat ?? Self.fallbackFormat)
            }
            DispatchQueue.main.async {
                guard token == self.sessionToken, let engine = self.engine else { return }
                engine.schedule(segment, rateMode: .pinnedToNatural) { [weak self] in
                    guard let self, token == self.sessionToken else { return }
                    self.playTransitionChime { [weak self] in
                        guard let self else { return }
                        // Re-check autoplay right before actually starting the
                        // next article — the user may have toggled it off
                        // during the announcement/chime.
                        guard AudioSettings.isAutoplayEnabled else {
                            self.playFinalChimeThenIdle()
                            return
                        }
                        self.beginPlayback(item: candidate.item, content: candidate.content, fromWordIndex: nil)
                    }
                }
            }
        }
    }

    private func playFinalChimeThenIdle() {
        guard let engine else { transitionToIdle(); return }
        let token = sessionToken
        do {
            try engine.scheduleTone(.final) { [weak self] in
                guard let self, token == self.sessionToken else { return }
                self.transitionToIdle()
            }
        } catch {
            transitionToIdle()
        }
    }

    private func transitionToIdle() {
        currentItem = nil
        currentScript = nil
        currentItemInfo = nil
        stateBeforePause = nil
        stopProgressTimer()
        stopPositionPersistTimer()
        positionStore.clear()
        engine?.pause()
        setState(.idle)
        sessionCoordinator.scheduleDeactivationAfterUserPause()
    }

    // MARK: - External (session-driven) pause/resume

    private func handleExternalPause() {
        // The interruption/route-change already owns session state here —
        // deliberately NOT deactivating (no scheduleDeactivationAfterUserPause).
        pauseInternal(deactivateSessionAfterGrace: false)
    }

    private func handleExternalResume() {
        resume()
    }

    // MARK: - Persistence

    private func matchingPersistedWordIndex(for itemID: UUID) -> Int? {
        guard let position = positionStore.load(), position.itemID == itemID else { return nil }
        return position.wordIndex
    }

    /// Cheap, frequent (~5s tick, plus every pause/seek/finish): App-Group
    /// defaults only, never the reading-list store.
    private func persistPositionToAppGroup() {
        guard let item = currentItem else { return }
        let snapshot = currentSnapshot
        positionStore.save(.init(
            itemID: item.id, wordIndex: lastKnownWordIndex, elapsed: snapshot.elapsed,
            title: snapshot.itemInfo?.title ?? item.title ?? ""))
    }

    /// ONE store write per pause/seek/finish — never called from the ~5s
    /// tick, so this never turns into a per-tick write stream.
    private func mirrorWordIndexToStore() {
        guard let item = currentItem else { return }
        store.setLastSpokenWordIndex(lastKnownWordIndex, for: item.id)
    }

    // MARK: - Timers

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.tickProgress()
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func startPositionPersistTimer() {
        positionPersistTimer?.invalidate()
        positionPersistTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.persistPositionToAppGroup()
        }
    }

    private func stopPositionPersistTimer() {
        positionPersistTimer?.invalidate()
        positionPersistTimer = nil
    }

    private func tickProgress() {
        guard let engine, isAudiblyPlaying else { return }
        let elapsed = engine.currentTime
        while markerCursor < pendingMarkerQueue.count, pendingMarkerQueue[markerCursor].absoluteTime <= elapsed {
            let marker = pendingMarkerQueue[markerCursor]
            markerCursor += 1
            guard marker.blockIndex >= 0 else { continue } // announcement segments carry no reader block
            lastKnownWordIndex = wordIndex(forBlockIndex: marker.blockIndex, range: marker.range)
            notifyObservers {
                $0.audioPlaybackCenter(self, didEmitWordEvent: AudioWordEvent(
                    blockIndex: marker.blockIndex, rangeInBlockText: marker.range))
            }
        }
        let snapshot = currentSnapshot
        notifyObservers {
            $0.audioPlaybackCenter(
                self, didUpdateProgress: snapshot.progressFraction, elapsed: snapshot.elapsed,
                duration: snapshot.estimatedDuration)
        }
    }

    private func wordIndex(forBlockIndex blockIndex: Int, range: NSRange) -> Int {
        guard let script = currentScript,
              let position = script.spokenBlocks.firstIndex(where: { $0.blockIndex == blockIndex })
        else { return lastKnownWordIndex }
        let text = script.spokenBlocks[position].text
        let offsets = AudioWordIndexing.wordStartUTF16Offsets(in: text)
        let wordOffsetInBlock = AudioWordIndexing.wordOffset(forUTF16Location: range.location, wordStartOffsets: offsets)
        return (blockStartWordIndices[safe: position] ?? 0) + wordOffsetInBlock
    }

    // MARK: - State helper

    private func setState(_ newState: AudioPlaybackState) {
        state = newState
    }
}
