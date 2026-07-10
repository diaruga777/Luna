//
//  AudioTrimIntelligence.swift
//  LunaAudioPlayback
//

import LunaModels
import Foundation
import FoundationModels

/// The schema the on-device model fills in: which numbered blocks (from the
/// prompt's numbered list, numbered by their ORIGINAL `ArticleContent.blocks`
/// index — not a per-chunk ordinal, so no renumbering step can introduce a
/// transcription bug) are NOT main article prose. The model never rewrites
/// prose — it only ever returns indices.
///
/// NOTE: despite `claudedocs/audio-playback-plan.md` describing this project
/// as targeting iOS 26 uniformly, the actual `Luna.xcodeproj` build settings
/// currently have `IPHONEOS_DEPLOYMENT_TARGET = 18.0` on every target (a
/// real, present-day discrepancy — verified directly, not assumed) while the
/// `LunaLibraries` package declares `.iOS(.v18)`. FoundationModels is an iOS
/// 26+-only framework, so every type below needs an explicit `@available`
/// guard; `FoundationModelsTrimSession` is only ever constructed behind an
/// `#available` check (see `AudioScriptPipeline`'s `modelSessionFactory`
/// default), with `UnavailableTrimSession` standing in on older OS versions
/// — a pre-26 device just folds into the same "LLM unavailable, heuristics
/// only" path an iOS-26-but-Apple-Intelligence-not-enabled device already
/// takes.
@available(iOS 26.0, *)
@Generable
struct AudioCleanupVerdict {
    @Guide(description: """
    Indices (the numbers shown in the list) of blocks that are NOT main \
    article prose — photo captions, related-link lists, ads, bylines, \
    newsletter or share prompts. Omit any index you are not confident about.
    """)
    let removeIndices: [Int]
}

/// Every FoundationModels failure this module cares about, normalized so
/// `AudioTrimIntelligence`'s chunking/validation/error-handling logic (see
/// "Phase 4: Trimming" in `claudedocs/audio-playback-plan.md`) never has to
/// name a FoundationModels type directly.
public enum AudioTrimModelError: Error {
    /// A content-safety guardrail tripped — including the documented
    /// "available yet throws immediately" Siri-language-mismatch quirk.
    /// Permanent for this article: callers must never retry.
    case guardrailViolation
    /// The chunk was too large for the model's context window; the caller
    /// halves the chunk and retries once.
    case exceededContextWindowSize
    /// The model is rate-limited right now; skip the LLM pass for this
    /// attempt (the heuristics-only script stands — a later foreground sweep
    /// may retry).
    case rateLimited
    case other(Error)
}

/// The seam every FoundationModels type in this module hides behind, so
/// `AudioTrimIntelligence`'s orchestration is unit-testable with a fake — the
/// on-device model is NEVER available in a CI simulator.
public protocol AudioTrimModelSession: AnyObject {
    /// Mirrors `SystemLanguageModel.default.availability == .available`.
    var isAvailable: Bool { get }
    /// Warms the session up before the first call of a batch.
    func prewarm()
    /// One chunk's request. `instructions` carries the task contract;
    /// `numberedListPrompt` is ONLY the numbered list of block excerpts (so
    /// article text is never itself interpreted as instructions). Returns the
    /// raw indices the model proposed; throws `AudioTrimModelError` on any
    /// failure — callers never see a raw FoundationModels error type.
    func requestCleanupVerdict(instructions: String, numberedListPrompt: String) async throws -> [Int]
}

/// Stands in for `FoundationModelsTrimSession` on an OS version older than
/// the framework's iOS 26 minimum — see the discrepancy note on
/// `AudioCleanupVerdict`. Always reports unavailable, so callers take
/// exactly the same "heuristics only" path they'd take for any other
/// on-device-model-unavailable reason.
public final class UnavailableTrimSession: AudioTrimModelSession {
    public init() {}
    public var isAvailable: Bool { false }
    public func prewarm() {}
    public func requestCleanupVerdict(instructions: String, numberedListPrompt: String) async throws -> [Int] {
        throw AudioTrimModelError.other(CocoaError(.featureUnsupported))
    }
}

/// The real, on-device-model-backed conformer. The ONLY place in this module
/// (and in `LunaAudioPlayback`) that imports `FoundationModels` or names one
/// of its types.
@available(iOS 26.0, *)
public final class FoundationModelsTrimSession: AudioTrimModelSession {
    public static let shared = FoundationModelsTrimSession()

    private var session: LanguageModelSession?

    public var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    public init() {}

    public func prewarm() {
        currentSession().prewarm()
    }

    public func requestCleanupVerdict(instructions: String, numberedListPrompt: String) async throws -> [Int] {
        let session = currentSession(instructions: instructions)
        do {
            let response = try await session.respond(to: numberedListPrompt, generating: AudioCleanupVerdict.self)
            return response.content.removeIndices
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.normalize(error)
        } catch {
            throw AudioTrimModelError.other(error)
        }
    }

    /// One `LanguageModelSession` per article's refinement pass (created
    /// lazily on first use, reused across that article's chunks so the model
    /// doesn't re-pay session setup per chunk); `AudioScriptPipeline` creates
    /// a fresh `FoundationModelsTrimSession` per article rather than sharing
    /// `.shared` across concurrent articles (see `AudioScriptPipeline`).
    private func currentSession(instructions: String? = nil) -> LanguageModelSession {
        if let session { return session }
        let newSession = instructions.map { LanguageModelSession(instructions: $0) } ?? LanguageModelSession()
        session = newSession
        return newSession
    }

    private static func normalize(_ error: LanguageModelSession.GenerationError) -> AudioTrimModelError {
        switch error {
        case .guardrailViolation: return .guardrailViolation
        case .exceededContextWindowSize: return .exceededContextWindowSize
        case .rateLimited: return .rateLimited
        default: return .other(error)
        }
    }
}

/// The optional, async refinement pass over the blocks SURVIVING
/// `AudioTrimHeuristics`. Never throws — every model/validation failure
/// degrades to "no additional removals" (see `RefinementResult`).
public enum AudioTrimIntelligence {

    public struct RefinementResult {
        public var additionalDroppedIndices: Set<Int>
        /// `guardrailViolation`: this article must never be retried again —
        /// callers persist this via `AudioScriptCacheEnvelope.llmPermanentlyFailed`.
        public var permanentFailure: Bool

        public init(additionalDroppedIndices: Set<Int> = [], permanentFailure: Bool = false) {
            self.additionalDroppedIndices = additionalDroppedIndices
            self.permanentFailure = permanentFailure
        }
    }

    /// Blocks surviving the heuristic pass are chunked ~this many per call.
    public static let chunkSize = 25
    /// Reject an entire chunk's verdict if it flags more than this fraction
    /// of the chunk's own blocks — a strong signal the model over-matched.
    static let perChunkRejectionFraction = 0.5

    /// The exact instructions text shipped to the model: the task contract
    /// (identify non-prose blocks by number; omit anything uncertain). The
    /// article text itself only ever appears in the PROMPT (the numbered
    /// list), never here.
    public static let instructions = """
    You are cleaning up an article's extracted text so it can be read aloud, \
    like a podcast. You will be given a numbered list of the article's text \
    blocks; each entry shows a block's number followed by roughly its first \
    20 words. Identify the numbers of blocks that are NOT main article prose \
    — photo captions, related-link lists, advertisements, bylines, \
    newsletter signups, or share prompts. If you are not confident a block \
    is one of these, do NOT include its number — when in doubt, keep it.
    """

    /// Refines `heuristicResult` for `content` using `session`: chunks the
    /// blocks the heuristic pass left standing, applies the positional rule
    /// (edge-adjacent extensions of the heuristic run are accepted outright;
    /// mid-article candidates additionally require
    /// `AudioTrimHeuristics.looksLikeRemovableJunk`), and re-applies the
    /// GLOBAL cap to the COMBINED heuristic + LLM removal — discarding every
    /// LLM verdict if the combination would exceed it.
    public static func refine(
        content: ArticleContent,
        heuristicResult: AudioTrimHeuristics.Result,
        totalWordCount: Int,
        session: AudioTrimModelSession
    ) async -> RefinementResult {
        let blocks = content.blocks
        let survivingIndices = blocks.indices.filter {
            !heuristicResult.droppedBlockIndices.contains($0) && !blocks[$0].text.isEmpty
        }
        guard !survivingIndices.isEmpty else { return RefinementResult() }

        session.prewarm()

        var candidateIndices: Set<Int> = []
        for chunk in Array(survivingIndices).chunked(into: chunkSize) {
            switch await requestChunkVerdict(chunk: chunk, blocks: blocks, session: session) {
            case .permanentFailure:
                return RefinementResult(permanentFailure: true)
            case .skip:
                continue
            case .indices(let indices):
                candidateIndices.formUnion(indices)
            }
        }
        guard !candidateIndices.isEmpty else { return RefinementResult() }

        let accepted = applyPositionalRule(
            candidateIndices: candidateIndices, heuristicDropped: heuristicResult.droppedBlockIndices, blocks: blocks)
        guard !accepted.isEmpty else { return RefinementResult() }

        let combinedDropped = heuristicResult.droppedBlockIndices.union(accepted)
        let combinedWords = combinedDropped.reduce(0) { $0 + AudioTrimHeuristics.wordCount(text: blocks[$1].text) }
        guard totalWordCount > 0,
              Double(combinedWords) / Double(totalWordCount) <= AudioTrimHeuristics.globalCapFraction
        else {
            // Combined removal would blow the cap — discard the LLM
            // verdicts entirely and keep the heuristic-only script.
            return RefinementResult()
        }
        return RefinementResult(additionalDroppedIndices: accepted)
    }

    // MARK: - Per-chunk request + validation

    private enum ChunkOutcome {
        case indices(Set<Int>)
        case skip
        case permanentFailure
    }

    private static func requestChunkVerdict(
        chunk: [Int], blocks: [ArticleContent.Block], session: AudioTrimModelSession
    ) async -> ChunkOutcome {
        let prompt = numberedListPrompt(for: chunk, blocks: blocks)
        do {
            let raw = try await session.requestCleanupVerdict(instructions: instructions, numberedListPrompt: prompt)
            return validate(raw: raw, chunk: chunk)
        } catch let error as AudioTrimModelError {
            switch error {
            case .guardrailViolation:
                return .permanentFailure
            case .exceededContextWindowSize:
                return await retryHalved(chunk: chunk, blocks: blocks, session: session)
            case .rateLimited, .other:
                return .skip
            }
        } catch {
            return .skip
        }
    }

    /// `exceededContextWindowSize`: halve the chunk and retry ONCE per half —
    /// any further failure (including the same error again) just skips that
    /// half, except a `guardrailViolation`, which is always permanent.
    private static func retryHalved(
        chunk: [Int], blocks: [ArticleContent.Block], session: AudioTrimModelSession
    ) async -> ChunkOutcome {
        let halfSize = max(1, chunk.count / 2)
        var combined: Set<Int> = []
        for half in chunk.chunked(into: halfSize) {
            let prompt = numberedListPrompt(for: half, blocks: blocks)
            do {
                let raw = try await session.requestCleanupVerdict(instructions: instructions, numberedListPrompt: prompt)
                if case .indices(let indices) = validate(raw: raw, chunk: half) {
                    combined.formUnion(indices)
                }
            } catch let error as AudioTrimModelError {
                if case .guardrailViolation = error { return .permanentFailure }
                continue // exceededContextWindowSize again / rateLimited / other: skip this half
            } catch {
                continue
            }
        }
        return .indices(combined)
    }

    /// In-range (must be a member of this chunk) + de-duplicated (via
    /// `Set`); rejects the WHOLE chunk's verdict if what remains still flags
    /// more than `perChunkRejectionFraction` of the chunk.
    private static func validate(raw: [Int], chunk: [Int]) -> ChunkOutcome {
        let chunkSet = Set(chunk)
        let inRange = Set(raw).intersection(chunkSet)
        guard !inRange.isEmpty else { return .indices([]) }
        guard Double(inRange.count) / Double(chunk.count) <= perChunkRejectionFraction else {
            return .indices([])
        }
        return .indices(inRange)
    }

    private static func numberedListPrompt(for indices: [Int], blocks: [ArticleContent.Block]) -> String {
        indices.map { index in
            let words = blocks[index].text.split(whereSeparator: { $0.isWhitespace }).prefix(20)
            return "\(index). \(words.joined(separator: " "))"
        }.joined(separator: "\n")
    }

    // MARK: - Positional acceptance

    /// Accepts candidates that extend a contiguous heuristic-dropped run at
    /// the article's start or end outright. Every other ("mid-article")
    /// candidate is accepted only if the block ALSO shows a weak heuristic
    /// signal or reads short (`AudioTrimHeuristics.looksLikeRemovableJunk`) —
    /// the model's opinion alone is never enough for a mid-article removal.
    private static func applyPositionalRule(
        candidateIndices: Set<Int>, heuristicDropped: Set<Int>, blocks: [ArticleContent.Block]
    ) -> Set<Int> {
        guard !blocks.isEmpty else { return [] }
        var accepted: Set<Int> = []
        var remaining = candidateIndices

        var prefixBoundary = 0
        while prefixBoundary < blocks.count, heuristicDropped.contains(prefixBoundary) { prefixBoundary += 1 }
        var suffixBoundary = blocks.count - 1
        while suffixBoundary >= 0, heuristicDropped.contains(suffixBoundary) { suffixBoundary -= 1 }

        var progressed = true
        while progressed {
            progressed = false
            if prefixBoundary <= suffixBoundary, remaining.contains(prefixBoundary) {
                accepted.insert(prefixBoundary)
                remaining.remove(prefixBoundary)
                prefixBoundary += 1
                progressed = true
            }
            if suffixBoundary >= prefixBoundary, remaining.contains(suffixBoundary) {
                accepted.insert(suffixBoundary)
                remaining.remove(suffixBoundary)
                suffixBoundary -= 1
                progressed = true
            }
        }

        for index in remaining where blocks.indices.contains(index) {
            if AudioTrimHeuristics.looksLikeRemovableJunk(blocks[index]) {
                accepted.insert(index)
            }
        }
        return accepted
    }
}

extension Array {
    /// File-scoped chunking helper shared by `AudioTrimIntelligence`'s
    /// chunk-then-halve logic.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
