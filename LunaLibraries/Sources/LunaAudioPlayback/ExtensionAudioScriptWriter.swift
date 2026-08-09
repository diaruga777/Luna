//
//  ExtensionAudioScriptWriter.swift
//  LunaAudioPlayback
//
//  Phase 6, product requirement B: when a Share/Action extension SAVES an
//  article, write a heuristics-only script to the cache immediately — cheap
//  and synchronous (no LLM involvement) — so the article is audio-ready
//  before the main app's `AudioScriptPipeline` sweep ever gets to it. See
//  "Extension audio" in claudedocs/audio-playback.md.
//

import LunaModels
import Foundation

/// A single, forkless entry point extensions call right after persisting an
/// article's content. Reuses `AudioScriptStore`/`AudioTrimHeuristics` — the
/// SAME types (and `builderVersion`) the main app's `AudioScriptPipeline`
/// uses — so a script written here is indistinguishable from one the main
/// app would have built, and the main app's sweep can upgrade it with the
/// LLM in place without ever needing to rebuild the heuristic pass.
public enum ExtensionAudioScriptWriter {

    /// Writes a heuristics-only `AudioScriptCacheEnvelope` for `item`/
    /// `content` unless a current-`builderVersion` script is already
    /// cached (never overwrites an existing entry — including one the main
    /// app already refined). No-op (returns `false`) when `item` has no
    /// `contentFileName` yet (nothing to key the sibling file off of) or a
    /// cached script already exists.
    ///
    /// - Parameter articlesDirectory: `ReadingListStore.articlesDirectory`
    ///   in production; tests pass a scratch directory.
    @discardableResult
    public static func writeHeuristicScriptIfNeeded(
        item: ReadingListItem, content: ArticleContent, articlesDirectory: URL
    ) -> Bool {
        guard let contentFileName = item.contentFileName else { return false }
        let scriptStore = AudioScriptStore(articlesDirectory: articlesDirectory)
        guard scriptStore.load(forContentFileName: contentFileName) == nil else { return false }

        let heuristicResult = AudioTrimHeuristics.classify(content)
        let script = heuristicResult.heuristicScript(for: content)
        let envelope = AudioScriptCacheEnvelope(script: script, refinementState: .heuristicOnly)
        scriptStore.save(envelope, forContentFileName: contentFileName)
        return true
    }
}
