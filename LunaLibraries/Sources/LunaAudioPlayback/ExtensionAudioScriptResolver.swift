//
//  ExtensionAudioScriptResolver.swift
//  LunaAudioPlayback
//
//  Phase 6: lets a Share/Action extension speak the TRIMMED script when the
//  user starts read-aloud there, without pulling `AudioScriptPipeline`'s
//  main-app-only machinery (`install()`, the `.readingListChanged` sweep,
//  foreground/background tracking) into the extension process. See
//  "Extension audio" in claudedocs/audio-playback.md.
//

import LunaModels
import Foundation

/// Extension-safe resolution of the best available `AudioScript` for
/// IMMEDIATE playback, plus an opportunistic, cancellable on-device LLM
/// refinement attempt that only ever updates the cache for NEXT time.
///
/// Ladder (never blocks on the LLM): cached refined script > cached
/// heuristic script > a freshly-built heuristic script (synchronous — pure
/// and fast, fine to run in-extension). Whichever is returned is what the
/// legacy `SpeechController` speaks THIS session; a refinement that completes
/// later never swaps it mid-playback (hard contract — see
/// `AudioScriptPipeline`'s identical rule for the main app).
///
/// Reuses `AudioScriptStore`/`AudioTrimHeuristics`/`AudioTrimIntelligence`
/// exactly as the main pipeline does — no forked trimming logic, so a script
/// written here is `builderVersion`-identical to one the main app would
/// build, and either can upgrade the other's cache entry in place.
public final class ExtensionAudioScriptResolver {
    private let scriptStore: AudioScriptStore
    private let modelSessionFactory: () -> AudioTrimModelSession

    /// The in-flight opportunistic refinement, if any — cancelled by
    /// `cancelInFlightRefinement()` when the extension is tearing down (the
    /// caller's `deinit`/`viewWillDisappear`) so a straggling attempt never
    /// outlives the view controller that started it.
    private var refinementTask: Task<Void, Never>?

    /// - Parameters:
    ///   - articlesDirectory: `ReadingListStore.articlesDirectory` in
    ///     production (App-Group-backed, readable from an extension); tests
    ///     pass a scratch directory.
    ///   - modelSessionFactory: defaults to the same iOS-26-gated factory
    ///     `AudioScriptPipeline` uses; tests inject a `FakeTrimModelSession`.
    public init(
        articlesDirectory: URL,
        modelSessionFactory: @escaping () -> AudioTrimModelSession = AudioTrimModelSessionFactory.makeDefault
    ) {
        self.scriptStore = AudioScriptStore(articlesDirectory: articlesDirectory)
        self.modelSessionFactory = modelSessionFactory
    }

    deinit {
        refinementTask?.cancel()
    }

    /// Returns the best available script for `item`/`content` RIGHT NOW,
    /// never blocking on the LLM. Cache hit (refined or heuristic) returns
    /// immediately; cache miss builds the heuristic script synchronously,
    /// persists it (so a save-time write via `ExtensionAudioScriptWriter`
    /// isn't required for this to work), and returns it. Either way, if the
    /// cached/just-built script isn't yet refined and isn't permanently
    /// failed, kicks off a cancellable opportunistic refinement pass
    /// (subject to `AudioSettings.isIntelligentTrimmingEnabled` and model
    /// availability) that only writes the cache for a LATER session.
    public func bestAvailableScriptForImmediatePlayback(
        item: ReadingListItem, content: ArticleContent
    ) -> AudioScript {
        guard let contentFileName = item.contentFileName else {
            return AudioTrimHeuristics.classify(content).heuristicScript(for: content)
        }

        if let cached = scriptStore.load(forContentFileName: contentFileName) {
            if !cached.refined, !cached.llmPermanentlyFailed {
                kickOffOpportunisticRefinement(
                    content: content, contentFileName: contentFileName, baseline: cached)
            }
            return cached.script
        }

        let heuristicResult = AudioTrimHeuristics.classify(content)
        let script = heuristicResult.heuristicScript(for: content)
        let envelope = AudioScriptCacheEnvelope(script: script, refined: false, llmPermanentlyFailed: false)
        scriptStore.save(envelope, forContentFileName: contentFileName)
        kickOffOpportunisticRefinement(content: content, contentFileName: contentFileName, baseline: envelope)
        return script
    }

    /// Cancels any in-flight refinement without touching the cache — call
    /// from the extension VC's teardown. A refinement that already finished
    /// and applied its result before this is called is unaffected (the cache
    /// write already happened); this only stops one still running.
    public func cancelInFlightRefinement() {
        refinementTask?.cancel()
        refinementTask = nil
    }

    // MARK: - Opportunistic LLM refinement

    private func kickOffOpportunisticRefinement(
        content: ArticleContent, contentFileName: String, baseline: AudioScriptCacheEnvelope
    ) {
        guard AudioSettings.isIntelligentTrimmingEnabled else { return }
        let session = modelSessionFactory()
        // The availability check is exactly what already folds "unavailable
        // for any reason" (Apple Intelligence off, unsupported language,
        // model not ready, pre-iOS-26) into a silent no-op — including
        // whatever differs about extension-context availability, since this
        // is the same real `SystemLanguageModel.default.availability` check
        // the main app uses (see `FoundationModelsTrimSession`).
        guard session.isAvailable else { return }

        refinementTask?.cancel()
        let heuristicResult = AudioTrimHeuristics.classify(content)
        refinementTask = Task { [weak self] in
            let refinement = await AudioTrimIntelligence.refine(
                content: content, heuristicResult: heuristicResult,
                totalWordCount: baseline.script.totalWordCount, session: session)
            guard let self, !Task.isCancelled else { return }
            self.applyRefinement(
                refinement, content: content, contentFileName: contentFileName, heuristicResult: heuristicResult)
        }
    }

    private func applyRefinement(
        _ refinement: AudioTrimIntelligence.RefinementResult, content: ArticleContent,
        contentFileName: String, heuristicResult: AudioTrimHeuristics.Result
    ) {
        if refinement.permanentFailure {
            let script = heuristicResult.heuristicScript(for: content)
            let envelope = AudioScriptCacheEnvelope(script: script, refined: false, llmPermanentlyFailed: true)
            scriptStore.save(envelope, forContentFileName: contentFileName)
            return
        }
        let combinedDropped = heuristicResult.droppedBlockIndices.union(refinement.additionalDroppedIndices)
        let script = AudioScriptPipeline.buildScript(content: content, droppedBlockIndices: combinedDropped)
        let envelope = AudioScriptCacheEnvelope(script: script, refined: true, llmPermanentlyFailed: false)
        scriptStore.save(envelope, forContentFileName: contentFileName)
    }
}
