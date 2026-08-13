//
//  AudioScriptPipeline.swift
//  LunaAudioPlayback
//

import LunaModels
import LunaStorage
import Foundation
import UIKit

/// Orchestrates Phase 4 trimming end to end: cache lookups, the always-on
/// heuristic pass, the opportunistic LLM refinement pass, and the sweep that
/// builds scripts as soon as an article is saved rather than lazily at first
/// playback (see "Trimming timing" in `claudedocs/audio-playback-plan.md`).
///
/// Installed ONLY by the main app (`Luna/AudioScriptPipelineWiring.swift`,
/// called once from `AppDelegate`) — the Share/Action extensions never call
/// `install()`, so they never observe `.savesChanged` or run the
/// builder themselves (extension memory limits + FoundationModels
/// constraints), matching the plan doc's "MAIN APP ONLY" requirement.
public final class AudioScriptPipeline {
    public static let shared = AudioScriptPipeline()

    private let store: SavesScriptSource
    private let scriptStore: AudioScriptStore
    /// A FRESH `AudioTrimModelSession` per article's refinement pass (not one
    /// shared instance reused across every article) — keeps each article's
    /// on-device conversation/context isolated and small, rather than
    /// accumulating turns across an entire sweep.
    private let modelSessions: any AudioTrimModelSessionMaking

    /// Debounces bursts of `.savesChanged` (e.g. a multi-item import)
    /// into one sweep.
    private let debounceInterval: TimeInterval
    /// Owns the debounce scheduling + foreground tracking; `runSweep()` (this
    /// class's own reentrancy-guarded sweep body) and `isForeground` stay here.
    private lazy var sweepDriver = SavesSweepDriver(
        queueLabel: "com.hsanabria.luna.audioScriptPipeline",
        debounceInterval: debounceInterval,
        sweeper: self)
    private var isSweeping = false
    /// Guards against kicking off a second concurrent refinement pass for the
    /// same item while an earlier one (from `script(for:content:)` or a
    /// sweep) is still in flight.
    private var inFlightItemIDs: Set<UUID> = []
    private let inFlightLock = NSLock()
    /// Tracked via `UIApplication.didBecomeActiveNotification`/
    /// `didEnterBackgroundNotification` rather than reading
    /// `UIApplication.shared.applicationState` directly — `UIApplication.shared`
    /// is unavailable to app extensions, and this module is transitively
    /// linked into them (via `LunaReaderUI`), so it must stay
    /// `APPLICATION_EXTENSION_API_ONLY`-safe even though `install()` itself
    /// is never called there.
    private var isForeground = true

    /// Testing seam: invoked on `sweepDriver`'s queue at the end of every sweep
    /// pass, so a test can wait for the sweep to HAVE RUN instead of sleeping
    /// on a fixed interval and hoping. Nil in production.
    var didFinishSweepForTesting: (() -> Void)?

    public init(
        store: SavesScriptSource = SavesStore.shared,
        modelSessions: any AudioTrimModelSessionMaking = DefaultAudioTrimModelSessionMaker(),
        debounceInterval: TimeInterval = 1.5
    ) {
        self.store = store
        self.scriptStore = AudioScriptStore(articlesDirectory: store.articlesDirectory)
        self.modelSessions = modelSessions
        self.debounceInterval = debounceInterval
    }

    // MARK: - Installation (main app only)

    /// Idempotent. Observes `.savesChanged` (debounced) plus
    /// foreground/background transitions, and runs an immediate launch
    /// sweep.
    public func install() {
        sweepDriver.install()
    }

    // MARK: - Playback-time lookup (never blocks on the LLM)

    /// Cache hit -> returns immediately. Cache miss -> builds the heuristic
    /// script NOW (fast, synchronous), persists it, and — when eligible —
    /// kicks off LLM refinement in the background (updating the cache for
    /// NEXT time; never swaps the script an in-progress playback session is
    /// already using). Playback-time build is a last-resort fallback; the
    /// sweep below is what normally keeps scripts ready ahead of time.
    public func script(for item: SavedItem, content: ArticleContent) -> AudioScript {
        guard let contentFileName = item.contentFileName else {
            return AudioTrimHeuristics.classify(content).heuristicScript(for: content)
        }
        if let cached = scriptStore.load(forContentFileName: contentFileName) {
            if cached.refinementState == .heuristicOnly {
                kickOffRefinementIfEligible(item: item, content: content, contentFileName: contentFileName, baseline: cached)
            }
            return cached.script
        }
        let heuristicResult = AudioTrimHeuristics.classify(content)
        let script = heuristicResult.heuristicScript(for: content)
        let envelope = AudioScriptCacheEnvelope(script: script, refinementState: .heuristicOnly)
        scriptStore.save(envelope, forContentFileName: contentFileName)
        kickOffRefinementIfEligible(item: item, content: content, contentFileName: contentFileName, baseline: envelope)
        return script
    }

    /// Verifies/prefetches `item`'s script without returning it — called when
    /// `AudioPlaybackCenter` resolves the NEXT autoplay queue candidate, so
    /// its script is ready (or at least building) before playback reaches it.
    public func prefetch(item: SavedItem, content: ArticleContent) {
        _ = script(for: item, content: content)
    }

    // MARK: - Sweep (opportunistic builder)

    private func runSweep() {
        guard !isSweeping else { return }
        isSweeping = true
        defer {
            isSweeping = false
            didFinishSweepForTesting?()
        }

        for item in store.items() {
            guard item.state == .ready, let contentFileName = item.contentFileName else { continue }
            guard let content = store.content(for: item), Self.isReadable(content) else { continue }
            guard !isInFlight(item.id) else { continue }

            let cached = scriptStore.load(forContentFileName: contentFileName)
            if cached == nil {
                buildHeuristicScriptSync(item: item, content: content, contentFileName: contentFileName)
                continue
            }
            guard let cached, cached.refinementState == .heuristicOnly else { continue }
            kickOffRefinementIfEligible(item: item, content: content, contentFileName: contentFileName, baseline: cached)
        }
    }

    private func buildHeuristicScriptSync(item: SavedItem, content: ArticleContent, contentFileName: String) {
        let heuristicResult = AudioTrimHeuristics.classify(content)
        let script = heuristicResult.heuristicScript(for: content)
        let envelope = AudioScriptCacheEnvelope(script: script, refinementState: .heuristicOnly)
        scriptStore.save(envelope, forContentFileName: contentFileName)
        kickOffRefinementIfEligible(item: item, content: content, contentFileName: contentFileName, baseline: envelope)
    }

    // MARK: - LLM refinement

    private func kickOffRefinementIfEligible(
        item: SavedItem, content: ArticleContent, contentFileName: String, baseline: AudioScriptCacheEnvelope
    ) {
        guard AudioSettings.isIntelligentTrimmingEnabled, isForeground, !isInFlight(item.id) else { return }
        let session = modelSessions.makeSession()
        guard session.isAvailable else { return }

        markInFlight(item.id)
        let heuristicResult = AudioTrimHeuristics.classify(content)
        Task { [weak self] in
            guard let self else { return }
            let refinement = await AudioTrimIntelligence.refine(
                content: content, heuristicResult: heuristicResult,
                totalWordCount: baseline.script.totalWordCount, session: session)
            self.applyRefinement(
                refinement, item: item, content: content, contentFileName: contentFileName,
                heuristicResult: heuristicResult)
            self.clearInFlight(item.id)
        }
    }

    private func applyRefinement(
        _ refinement: AudioTrimIntelligence.RefinementResult, item: SavedItem, content: ArticleContent,
        contentFileName: String, heuristicResult: AudioTrimHeuristics.Result
    ) {
        if refinement.permanentFailure {
            let script = heuristicResult.heuristicScript(for: content)
            let envelope = AudioScriptCacheEnvelope(script: script, refinementState: .permanentlyFailed)
            scriptStore.save(envelope, forContentFileName: contentFileName)
            return
        }
        let combinedDropped = heuristicResult.droppedBlockIndices.union(refinement.additionalDroppedIndices)
        let script = Self.buildScript(content: content, droppedBlockIndices: combinedDropped)
        let envelope = AudioScriptCacheEnvelope(script: script, refinementState: .refined)
        scriptStore.save(envelope, forContentFileName: contentFileName)
    }

    // MARK: - In-flight bookkeeping

    private func isInFlight(_ itemID: UUID) -> Bool {
        inFlightLock.lock()
        defer { inFlightLock.unlock() }
        return inFlightItemIDs.contains(itemID)
    }

    private func markInFlight(_ itemID: UUID) {
        inFlightLock.lock()
        inFlightItemIDs.insert(itemID)
        inFlightLock.unlock()
    }

    private func clearInFlight(_ itemID: UUID) {
        inFlightLock.lock()
        inFlightItemIDs.remove(itemID)
        inFlightLock.unlock()
    }

    // MARK: - Readability

    static func isReadable(_ content: ArticleContent) -> Bool {
        content.blocks.contains { !$0.text.isEmpty }
    }

    static func buildScript(content: ArticleContent, droppedBlockIndices: Set<Int>) -> AudioScript {
        let spokenBlocks: [AudioScript.SpokenBlock] = content.blocks.enumerated().compactMap { index, block in
            guard !block.text.isEmpty, !droppedBlockIndices.contains(index) else { return nil }
            return AudioScript.SpokenBlock(blockIndex: index, text: block.text)
        }
        let wordCount = spokenBlocks.reduce(0) { $0 + AudioTrimHeuristics.wordCount(text: $1.text) }
        return AudioScript(
            spokenBlocks: spokenBlocks, totalWordCount: wordCount, builderVersion: AudioScript.heuristicBuilderVersion)
    }
}

/// The sweep body and the foreground tracking `SavesSweepDriver` drives.
/// Only the scheduling lives in the driver; the reentrancy guard is this
/// class's own.
extension AudioScriptPipeline: SavesSweepForegroundTracking {
    public func runSavesSweep() { runSweep() }

    public func savesSweepForegroundChanged(to isForeground: Bool) {
        self.isForeground = isForeground
    }
}

extension AudioTrimHeuristics.Result {
    func heuristicScript(for content: ArticleContent) -> AudioScript {
        AudioScriptPipeline.buildScript(content: content, droppedBlockIndices: droppedBlockIndices)
    }
}
