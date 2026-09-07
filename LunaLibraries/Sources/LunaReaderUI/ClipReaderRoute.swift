//
//  ClipReaderRoute.swift
//  LunaReaderUI
//

import LunaIngest

/// What the Reader App Clip does with an `Outcome`.
///
/// The clip target is the one article surface a test bundle can't import (an
/// `.app` inside an `.app`, hosted by nothing), so its outcome switch lived
/// entirely outside `SurfaceParityTests` — and drifted: `.needsArchive` dead-ended
/// on "download the full app" while the app and BOTH extensions unlocked the same
/// article in place through `ArchiveWebReaderViewController`. The decision is a
/// pure function here so the parity suite can hold the clip to the same mapping.
public enum ClipReaderRoute: Equatable {
    /// Readable right now — present the native reader.
    case reader
    /// A paywall / bot wall the silent tier couldn't pass. Same answer as every
    /// other article surface: open the archive web reader here, so the user solves
    /// at most a CAPTCHA and reads without leaving the clip.
    case archiveUnlock
    /// Another app's kind (a video, a post, a product, a document). The Reader clip
    /// has nothing to show for it.
    case notReadable
    /// The page couldn't be read at all.
    case failed

    public static func route(for outcome: Outcome) -> ClipReaderRoute {
        switch outcome {
        case .article: return .reader
        case .needsArchive: return .archiveUnlock
        case .product, .video, .social, .document: return .notReadable
        // The clip runs no plugin platform, so neither `.locked` nor
        // `.transcription` can arrive here.
        case .failed, .unsupported, .locked, .transcription: return .failed
        }
    }
}
