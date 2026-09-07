//
//  TranscriptionEngine.swift
//  LunaTranscribe
//

import Foundation
import LunaModels
import LunaStorage

/// One stretch of recognized speech with its place in the recording.
public struct TranscriptSegment: Equatable, Sendable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String

    public init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Whether an engine can run on this device right now.
public enum TranscriptionAvailability: Equatable, Sendable {
    case available
    /// The OS has no on-device speech analyzer.
    case unsupportedOS
    /// No on-device model exists for the requested language.
    case unsupportedLanguage
    /// The language is supported but its model is not installed yet.
    case modelNotInstalled
}

/// Why a job could not finish (`claudedocs/plans/transcription-plugins.md` §5.4).
/// `isTerminal` decides whether the runner retries or fails the save.
public enum TranscriptionError: Error, Equatable, Sendable {
    case unsupportedOS
    case unsupportedLanguage
    /// The model download did not complete. Retried once, then terminal.
    case modelNotInstalled
    /// The file carries no audio track.
    case noAudioTrack
    /// The recording decoded, but no words came out of it.
    case noSpeech
    /// The source declared, or delivered, more bytes than the runner will hold.
    case tooLarge
    /// The container or its audio could not be read.
    case decodingFailed(String)
    /// The source answered with a non-success status.
    case httpStatus(Int)
    /// A transport failure, already described in the user's words.
    case transport(String)
    /// The URL was stale and the plugin could not supply a fresh one.
    case sourceUnavailable

    /// Whether retrying can help. A terminal error fails the save at once; a
    /// transient one returns the job to `queued` until the attempts run out.
    public var isTerminal: Bool {
        switch self {
        case .unsupportedOS, .unsupportedLanguage, .noAudioTrack, .noSpeech, .tooLarge,
             .decodingFailed:
            return true
        case .modelNotInstalled, .httpStatus, .transport, .sourceUnavailable:
            return false
        }
    }

    /// The sentence the failed card shows under its title, through
    /// `SaveFailureReason.transcriptionFailed`.
    public var userFacingDetail: String {
        switch self {
        case .unsupportedOS: return L10n.string("Transcription_needsIOS26")
        case .unsupportedLanguage: return L10n.string("Transcription_languageUnsupported")
        case .modelNotInstalled: return L10n.string("Transcription_modelUnavailable")
        case .noAudioTrack: return L10n.string("Transcription_noAudioTrack")
        case .noSpeech: return L10n.string("Transcription_noSpeech")
        case .tooLarge: return L10n.string("Transcription_fileTooLarge")
        case .decodingFailed, .httpStatus, .sourceUnavailable:
            return L10n.string("Transcription_failed")
        case let .transport(detail): return detail
        }
    }
}

/// Turns a local recording into timed segments. The one production conformer
/// wraps the iOS 26 speech analyzer; tests script one.
public protocol TranscriptionEngine {
    var availability: TranscriptionAvailability { get }

    /// Transcribes the first audio track of the file at `audioFileURL`.
    /// `language` is BCP-47 or nil for the device locale. `progress` receives
    /// the decoded fraction, 0…1. Throws `TranscriptionError`.
    func transcribe(
        audioFileURL: URL, mediaKind: TranscriptionRequest.MediaKind, language: String?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TranscriptSegment]
}

/// The pending card's status line for a job state.
public enum TranscriptionStatusCopy {
    public static func text(for status: TranscriptionJobStatus) -> String? {
        switch status {
        case .queued: return L10n.string("Transcription_statusQueued")
        case .downloading: return L10n.string("Transcription_statusDownloading")
        case .transcribing: return L10n.string("Transcription_statusTranscribing")
        case .done, .failed: return nil
        }
    }
}
