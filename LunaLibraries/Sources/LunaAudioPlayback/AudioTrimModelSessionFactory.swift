//
//  AudioTrimModelSessionFactory.swift
//  LunaAudioPlayback
//

import Foundation

/// The ONE place that decides which `AudioTrimModelSession` conformer to
/// construct for a fresh refinement pass — shared by `AudioScriptPipeline`
/// (main app) and `ExtensionAudioScriptResolver` (Share/Action extensions,
/// Phase 6) so the iOS-26-availability gate is never duplicated between them.
/// See the discrepancy note on `AudioCleanupVerdict`: this project's actual
/// deployment target is iOS 18, below FoundationModels' iOS 26 minimum, so
/// the real session is only ever constructed behind this `#available` check
/// — `UnavailableTrimSession` folds a pre-26 OS into the exact same
/// "heuristics only" path as Apple-Intelligence-not-enabled or rate-limited.
public enum AudioTrimModelSessionFactory {
    public static func makeDefault() -> AudioTrimModelSession {
        if #available(iOS 26.0, *) {
            return FoundationModelsTrimSession()
        } else {
            return UnavailableTrimSession()
        }
    }
}
