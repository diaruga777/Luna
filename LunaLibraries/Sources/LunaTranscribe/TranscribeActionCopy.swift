//
//  TranscribeActionCopy.swift
//  LunaTranscribe
//

import Foundation
import LunaModels

/// The two Transcribe affordances' labels: the paste row's long-press action
/// and a media card's long-press action, both central Luna only
/// (`claudedocs/plans/transcription-plugins.md` §6).
public enum TranscribeActionCopy {
    public static var pasteAndTranscribe: String { L10n.string("Transcribe_pasteAndTranscribe") }
    public static var cardAction: String { L10n.string("Transcribe_cardAction") }
}
