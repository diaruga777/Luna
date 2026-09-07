//
//  TranscribeSaveAction.swift
//  Luna
//
//  The one way a user asks for a transcript: a NEW save of the link, ingested
//  with the transcribe intent so the media plugins stand aside and a transcript
//  plugin claims it (`claudedocs/plans/transcription-plugins.md` §6). Shared by
//  the util card's paste row and the media card's menu. Compiled into every
//  app; `isOffered` keeps the affordances to central Luna on iOS 26.
//

import Foundation
import LunaIngest
import LunaModels
import LunaSaves
import LunaStorage

enum TranscribeSaveAction {

    /// Whether this app, on this OS, offers a Transcribe action at all.
    static var isOffered: Bool {
        guard LunaApp.current.transcribesMedia else { return false }
        if #available(iOS 26, *) { return true }
        return false
    }

    /// Inserts a separate pending save for `urlString` and runs the ingest
    /// walk with the transcribe intent. The item is returned when the save was
    /// accepted; nil when this app dropped it as another app's kind.
    @MainActor
    static func start(urlString: String, source: CaptureSource) async -> SavedItem? {
        let item = SavesStore.shared.addSeparate(urlString: urlString, source: source)
        switch await SavesIngestor.shared.ingest(item, intent: .transcribe) {
        case .supported: return item
        case .unsupported: return nil
        }
    }
}
