//
//  AudioScript.swift
//  LunaAudioPlayback
//

import LunaModels

/// The *spoken* subset/shape of an article: what read-aloud actually says, as
/// opposed to `ArticleContent`'s full visual text. A script is built once per
/// article and cached (`AudioScriptStore`/`AudioScriptPipeline`) rather than
/// recomputed on every play.
///
/// The pass-through factory below is the trimming-disabled fallback — every
/// non-empty block, verbatim, in order. `AudioTrimHeuristics`/
/// `AudioTrimIntelligence` narrow `spokenBlocks` to a subset of blocks (by
/// `blockIndex`) with possibly-edited `text` (dropping captions, related-link
/// lists, bylines, share prompts, etc. — see `claudedocs/audio-playback-plan.md`);
/// nothing else about this type needs to change for that.
public struct AudioScript: Codable, Equatable {

    /// One block of the article, as read aloud. `blockIndex` refers back to the
    /// index of the corresponding `ArticleContent.Block` (blocks the trimming
    /// pass drops simply don't appear here).
    public struct SpokenBlock: Codable, Equatable {
        public var blockIndex: Int
        public var text: String

        public init(blockIndex: Int, text: String) {
            self.blockIndex = blockIndex
            self.text = text
        }
    }

    public var spokenBlocks: [SpokenBlock]
    /// Sum of whitespace-delimited word counts across `spokenBlocks` — the
    /// input to duration estimates (rendered-so-far + remaining-words × avg
    /// sec/word) and to `skip(bySeconds:)`'s seconds-to-word-index mapping.
    public var totalWordCount: Int
    /// Bumped whenever the script-building logic changes in a way that should
    /// invalidate previously cached scripts (Phase 4 persists scripts as sibling
    /// JSON files keyed partly on this value). Phase 1's pass-through builder is
    /// version 1.
    public var builderVersion: Int

    public init(spokenBlocks: [SpokenBlock], totalWordCount: Int, builderVersion: Int) {
        self.spokenBlocks = spokenBlocks
        self.totalWordCount = totalWordCount
        self.builderVersion = builderVersion
    }
}

public extension AudioScript {
    /// The builder version produced by the Phase-1 pass-through factory below.
    /// Later phases introduce their own (higher) version when real trimming
    /// lands, so previously cached Phase-1 scripts don't get mistaken for
    /// trimmed ones.
    static let passthroughBuilderVersion = 1

    /// The builder version produced by Phase 4's heuristic (+ optional
    /// on-device-LLM refinement) trimming pass — see `AudioTrimHeuristics`,
    /// `AudioTrimIntelligence`, and `AudioScriptPipeline`. Whether the LLM
    /// pass actually ran is tracked separately
    /// (`AudioScriptCacheEnvelope.RefinementState`) rather than as its own
    /// builder version, since a heuristics-only script is upgraded to a
    /// refined one in place without changing its shape. Bumped for the
    /// `refined`/`llmPermanentlyFailed` bool pair -> `RefinementState` enum
    /// change (no migration — a version bump is simpler than teaching this
    /// rebuildable cache to decode its own retired shape).
    static let heuristicBuilderVersion = 3

    /// Phase-1 stub script builder: every non-empty text block of `content`,
    /// verbatim, in order — no trimming at all. This is a legitimate standing
    /// option (not just a placeholder): it's what a future "disable Apple
    /// Intelligence cleanup" setting falls back to once the heuristic pass also
    /// exists, so this initializer stays public rather than being deleted when
    /// Phase 4 lands.
    init(passthrough content: ArticleContent) {
        let blocks: [SpokenBlock] = content.blocks.enumerated().compactMap { index, block in
            guard !block.text.isEmpty else { return nil }
            return SpokenBlock(blockIndex: index, text: block.text)
        }
        let wordCount = blocks.reduce(0) { total, block in
            total + block.text.split(whereSeparator: { $0.isWhitespace }).count
        }
        self.init(spokenBlocks: blocks, totalWordCount: wordCount, builderVersion: Self.passthroughBuilderVersion)
    }
}
