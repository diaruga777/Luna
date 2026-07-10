//
//  AudioTrimHeuristics.swift
//  LunaAudioPlayback
//

import LunaModels
import Foundation

/// The deterministic, synchronous, always-runs half of Phase 4 trimming (see
/// "Phase 4: Trimming" / `AudioScriptBuilder` in
/// `claudedocs/audio-playback-plan.md`). Classifies `ArticleContent.blocks`
/// into "keep" vs. "drop" at WHOLE-BLOCK granularity only — word events assume
/// script text is verbatim block text, so a block is either spoken in full or
/// not at all; nothing here ever edits within a block's text.
///
/// **Positional confidence** (product-owner rule): a contiguous run of blocks
/// from the very START or END of the article may be dropped on weaker
/// ("weak") signals — bylines, datelines, "min read", share prompts,
/// newsletter signups, social-embed boilerplate, moderate link density. A
/// MID-ARTICLE block is only ever dropped on a "high-precision" signal (image
/// blocks, exact caption/credit patterns, explicit `READ MORE:`-style
/// markers/short ALL-CAPS lines, very-high link density) — these are also
/// safe (and applied) at the edges.
///
/// **Global cap:** if the full rule set would drop more than ~50% of the
/// article's total word count, that's a sign something over-matched —
/// heuristics degrade to ONLY the high-precision rules (at any position) and
/// report `didDegradeForGlobalCap` so callers/tests can see it happened; the
/// cap is never exceeded silently.
public enum AudioTrimHeuristics {

    /// One block's classification. `.high`-precision signals are safe to act
    /// on anywhere in the article; `.weak` signals are only ever acted on as
    /// part of a contiguous run from the start or end.
    struct Signal {
        enum Precision { case high, weak }
        /// Where a `.weak` signal is allowed to apply. Meaningless for `.high`
        /// (those apply anywhere, including mid-article).
        enum Edge { case leadingOnly, trailingOnly, either, anywhere }
        var precision: Precision
        var edge: Edge
        var reason: String
    }

    public struct Result: Equatable {
        public var droppedBlockIndices: Set<Int>
        /// Human-readable reason each dropped index was dropped (debugging/tests).
        public var reasons: [Int: String]
        /// True when the full rule set exceeded the ~50% global word-count
        /// cap and the result below is the degraded, high-precision-only pass.
        public var didDegradeForGlobalCap: Bool

        public static func == (lhs: Result, rhs: Result) -> Bool {
            lhs.droppedBlockIndices == rhs.droppedBlockIndices
                && lhs.reasons == rhs.reasons
                && lhs.didDegradeForGlobalCap == rhs.didDegradeForGlobalCap
        }
    }

    /// If the full rule set would drop more than this fraction of the
    /// article's total word count, degrade to high-precision-only.
    static let globalCapFraction = 0.5
    /// Link text share of a block's text at/above which link density is a
    /// WEAK signal (edge-only).
    static let edgeLinkDensityThreshold = 0.4
    /// Link text share of a block's text at/above which link density is
    /// "very high" — a HIGH-PRECISION signal, safe anywhere including
    /// mid-article.
    static let midLinkDensityThreshold = 0.7
    /// Weak leading/trailing-edge metadata (bylines, datelines, share
    /// prompts, …) reads short; a block this long or longer never qualifies
    /// for a WEAK edge drop, which is the concrete mechanism protecting the
    /// article's actual lead/closing prose from being swept into an edge run.
    static let weakEdgeMaxWordCount = 40
    /// A block this short (or shorter) counts as "short" for the LLM's
    /// mid-article weak-signal gate (`looksLikeRemovableJunk`).
    static let shortBlockMaxWordCount = 12

    // MARK: - Public entry point

    public static func classify(_ content: ArticleContent) -> Result {
        let blocks = content.blocks
        guard !blocks.isEmpty else {
            return Result(droppedBlockIndices: [], reasons: [:], didDegradeForGlobalCap: false)
        }
        let totalWords = wordCount(blocks: blocks, at: Set(blocks.indices))
        guard totalWords > 0 else {
            return Result(droppedBlockIndices: [], reasons: [:], didDegradeForGlobalCap: false)
        }

        let full = computeDrops(blocks: blocks, includeWeakSignals: true)
        let droppedWordsFull = wordCount(blocks: blocks, at: full.dropped)
        if Double(droppedWordsFull) / Double(totalWords) <= globalCapFraction {
            return Result(droppedBlockIndices: full.dropped, reasons: full.reasons, didDegradeForGlobalCap: false)
        }

        // Degrade: drop the weak edge-run logic entirely, keep only
        // high-precision signals (which apply at any position anyway).
        let degraded = computeDrops(blocks: blocks, includeWeakSignals: false)
        return Result(droppedBlockIndices: degraded.dropped, reasons: degraded.reasons, didDegradeForGlobalCap: true)
    }

    /// Whether `block` shows ANY heuristic signal (high or weak) or simply
    /// reads short — the bar `AudioTrimIntelligence` requires before ever
    /// accepting a MID-ARTICLE LLM-proposed removal (the model's say-so alone
    /// is never enough there; see `claudedocs/audio-playback-plan.md`).
    public static func looksLikeRemovableJunk(_ block: ArticleContent.Block) -> Bool {
        if block.kind == .image { return true }
        if signal(for: block) != nil { return true }
        let words = wordCount(text: block.text)
        return words > 0 && words <= shortBlockMaxWordCount
    }

    // MARK: - Drop computation

    private static func computeDrops(
        blocks: [ArticleContent.Block], includeWeakSignals: Bool
    ) -> (dropped: Set<Int>, reasons: [Int: String]) {
        var reasons: [Int: String] = [:]
        var dropped: Set<Int> = []

        // High-precision signals apply anywhere, unconditionally.
        for (index, block) in blocks.enumerated() {
            if let signal = signal(for: block), signal.precision == .high {
                dropped.insert(index)
                reasons[index] = signal.reason
            }
        }

        guard includeWeakSignals else { return (dropped, reasons) }

        // Leading edge: walk forward from index 0 while each block is either
        // already high-precision-dropped or shows a weak leading/either
        // signal on a short-enough block. Stops at the first block that
        // doesn't qualify — that's what protects the article's real lead
        // paragraph (and title, which isn't a block at all) from removal.
        var leadingRun: Set<Int> = []
        for (index, block) in blocks.enumerated() {
            if dropped.contains(index) { leadingRun.insert(index); continue }
            guard let signal = signal(for: block), signal.precision == .weak,
                  signal.edge == .leadingOnly || signal.edge == .either,
                  block.kind != .heading,
                  wordCount(text: block.text) <= weakEdgeMaxWordCount
            else { break }
            leadingRun.insert(index)
            reasons[index] = signal.reason
        }

        // Trailing edge: same walk, backward from the last index. Never
        // reaches back into the leading run (guards very short articles from
        // being wiped out entirely by both edges meeting in the middle).
        var trailingRun: Set<Int> = []
        for index in stride(from: blocks.count - 1, through: 0, by: -1) {
            if leadingRun.contains(index) { break }
            let block = blocks[index]
            if dropped.contains(index) { trailingRun.insert(index); continue }
            guard let signal = signal(for: block), signal.precision == .weak,
                  signal.edge == .trailingOnly || signal.edge == .either,
                  block.kind != .heading,
                  wordCount(text: block.text) <= weakEdgeMaxWordCount
            else { break }
            trailingRun.insert(index)
            reasons[index] = signal.reason
        }

        dropped.formUnion(leadingRun)
        dropped.formUnion(trailingRun)
        return (dropped, reasons)
    }

    // MARK: - Word counting

    static func wordCount(text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    private static func wordCount(blocks: [ArticleContent.Block], at indices: Set<Int>) -> Int {
        indices.reduce(0) { total, index in
            guard blocks.indices.contains(index) else { return total }
            return total + wordCount(text: blocks[index].text)
        }
    }

    // MARK: - Per-block signal detection

    private static func signal(for block: ArticleContent.Block) -> Signal? {
        if block.kind == .image { return Signal(precision: .high, edge: .anywhere, reason: "image block") }
        let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let reason = captionCreditReason(text) {
            return Signal(precision: .high, edge: .anywhere, reason: reason)
        }
        if let reason = explicitMarkerReason(text) {
            return Signal(precision: .high, edge: .anywhere, reason: reason)
        }
        if let density = linkDensity(block) {
            if density >= midLinkDensityThreshold {
                return Signal(precision: .high, edge: .anywhere, reason: "very high link density (\(Int(density * 100))%)")
            }
            if density >= edgeLinkDensityThreshold {
                return Signal(precision: .weak, edge: .either, reason: "moderate link density (\(Int(density * 100))%)")
            }
        }
        if let reason = leadingBoilerplateReason(text) {
            return Signal(precision: .weak, edge: .leadingOnly, reason: reason)
        }
        if let reason = trailingBoilerplateReason(text) {
            return Signal(precision: .weak, edge: .trailingOnly, reason: reason)
        }
        return nil
    }

    /// `Photo:`/`Credit:`/`Image:` prefixes, trailing photo-agency credits
    /// (`… /Getty Images`, `… /AP`, `… /Reuters`), and `(Photo by …)` parentheticals.
    private static func captionCreditReason(_ text: String) -> String? {
        if matches(text, prefixPattern: "(?i)^(photo|credit|image)\\s*:") {
            return "caption/credit prefix"
        }
        for suffix in ["/Getty Images", "/AP", "/Reuters"] where text.hasSuffix(suffix) {
            return "trailing photo-agency credit (\(suffix))"
        }
        if matches(text, containsPattern: "(?i)\\(photo by [^)]+\\)") {
            return "\"(Photo by …)\" credit"
        }
        return nil
    }

    /// `READ MORE:`/`MORE:`/`ALSO READ:`/`RELATED:` markers, and short
    /// ALL-CAPS lines (section headers like "TRENDING" / "ADVERTISEMENT").
    private static func explicitMarkerReason(_ text: String) -> String? {
        if matches(text, prefixPattern: "(?i)^(read more|more|also read|related)\\s*:") {
            return "explicit related-content marker"
        }
        if isShortAllCaps(text) {
            return "short ALL-CAPS line"
        }
        return nil
    }

    private static func isShortAllCaps(_ text: String) -> Bool {
        let words = wordCount(text: text)
        guard words >= 1, words <= 6 else { return false }
        guard text.rangeOfCharacter(from: .lowercaseLetters) == nil else { return false }
        guard text.rangeOfCharacter(from: .letters) != nil else { return false }
        return text == text.uppercased()
    }

    /// Bylines (`^By NAME`), datelines (`CITY — `), `Updated:`/`Published:`,
    /// and "N min read" — all leading-edge-only, all typically short.
    private static func leadingBoilerplateReason(_ text: String) -> String? {
        if matches(text, prefixPattern: "^By [A-Z]") { return "byline" }
        if matches(text, prefixPattern: "(?i)^(updated|published)\\s*:") { return "updated/published timestamp" }
        if matches(text, containsPattern: "(?i)\\d+\\s*min(ute)?s?\\s*read") { return "\"min read\" label" }
        if matches(text, prefixPattern: "^[A-Z]{2,}[A-Za-z.,'’ ]*\\s[—–-]\\s") { return "dateline" }
        return nil
    }

    /// Share prompts, newsletter signups, social-embed boilerplate, and
    /// copyright/rights lines — all trailing-edge-only.
    private static func trailingBoilerplateReason(_ text: String) -> String? {
        let lower = text.lowercased()
        for phrase in ["share this article", "share this story", "follow us on", "like us on facebook"] {
            if lower.contains(phrase) { return "share prompt" }
        }
        if lower.contains("sign up for") { return "newsletter/social-embed prompt (\"sign up for\")" }
        if lower.contains("view this post on instagram") || lower.contains("a post shared by") {
            return "social-embed boilerplate"
        }
        if text.hasPrefix("©") || lower.contains("all rights reserved") || matches(text, containsPattern: "(?i)copyright\\s*©") {
            return "copyright/rights line"
        }
        return nil
    }

    private static func linkDensity(_ block: ArticleContent.Block) -> Double? {
        guard !block.links.isEmpty else { return nil }
        let textLength = block.text.utf16.count
        guard textLength > 0 else { return nil }
        let linkLength = block.links.reduce(0) { $0 + $1.length }
        return Double(linkLength) / Double(textLength)
    }

    // MARK: - Regex helpers

    private static func matches(_ text: String, prefixPattern pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range)?.range.location == 0
    }

    private static func matches(_ text: String, containsPattern pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }
}
