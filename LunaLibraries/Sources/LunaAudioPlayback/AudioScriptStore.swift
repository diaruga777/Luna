//
//  AudioScriptStore.swift
//  LunaAudioPlayback
//

import LunaStorage
import Foundation

/// What's actually persisted to disk for one article: the built script plus
/// bookkeeping the pipeline needs to decide whether it can stop touching this
/// article — see `AudioScriptPipeline`.
public struct AudioScriptCacheEnvelope: Codable, Equatable {
    /// Where a script's LLM refinement stands. Used to be two independent
    /// bools (`refined`/`llmPermanentlyFailed`) whose both-true combination
    /// meant nothing — a script can't be both a finished refinement AND a
    /// permanent refusal to ever refine.
    public enum RefinementState: String, Codable, Equatable {
        /// The heuristic pass built `script`; refinement hasn't run yet (or
        /// is still eligible to be retried by a later foreground sweep) —
        /// WITHOUT touching playback logic, since `AudioScript`'s shape never
        /// changes, only which blocks survive.
        case heuristicOnly
        /// The on-device LLM pass ran and contributed to `script`.
        case refined
        /// The LLM pass hit a `guardrailViolation` for this article —
        /// permanent: the pipeline must never attempt refinement again.
        case permanentlyFailed
    }

    public var script: AudioScript
    public var refinementState: RefinementState

    public init(script: AudioScript, refinementState: RefinementState) {
        self.script = script
        self.refinementState = refinementState
    }
}

/// Persists a finished `AudioScript` as a sibling JSON file of the item's
/// content file, in the same App-Group `Articles` directory
/// `LunaStorage.SavesStore` already uses — so it survives exactly as
/// long as the article's content does, and is cleaned up the same way
/// (`SavesStore.delete` removes the content file; a stale sibling
/// script would just fail to load next time it's looked up by a name nothing
/// references any more). A version mismatch (`AudioScript.builderVersion !=
/// currentBuilderVersion`) or a missing/corrupt file both mean "rebuild" —
/// `load` returns `nil` either way, never a stale script.
public final class AudioScriptStore {
    /// The heuristic (+ optional LLM refinement) builder's version — see
    /// `AudioScript.heuristicBuilderVersion`. A cached envelope whose script
    /// was built by an older/newer version is treated as absent.
    public static let currentBuilderVersion = AudioScript.heuristicBuilderVersion

    private let articlesDirectory: URL
    private let fileManager = FileManager.default

    /// - Parameter articlesDirectory: `SavesStore.articlesDirectory` in
    ///   production; tests pass a scratch directory.
    public init(articlesDirectory: URL) {
        self.articlesDirectory = articlesDirectory
    }

    /// `<stem>.audioScript.json` for a content file named `<stem>.json`.
    public static func scriptFileName(forContentFileName contentFileName: String) -> String {
        let stem = (contentFileName as NSString).deletingPathExtension
        return "\(stem).audioScript.json"
    }

    public func load(forContentFileName contentFileName: String) -> AudioScriptCacheEnvelope? {
        let url = articlesDirectory.appendingPathComponent(Self.scriptFileName(forContentFileName: contentFileName))
        guard let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(AudioScriptCacheEnvelope.self, from: data),
              envelope.script.builderVersion == Self.currentBuilderVersion
        else { return nil }
        return envelope
    }

    public func save(_ envelope: AudioScriptCacheEnvelope, forContentFileName contentFileName: String) {
        let url = articlesDirectory.appendingPathComponent(Self.scriptFileName(forContentFileName: contentFileName))
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        try? data.write(to: url, options: .atomic)
        // Purely a rebuildable derived cache (a version bump or missing file
        // silently rebuilds it) — excluded from backups, unlike the article
        // content JSON itself.
        BackupPolicy.excludeFromBackups(url)
    }
}
