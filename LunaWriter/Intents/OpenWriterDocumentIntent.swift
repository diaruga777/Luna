//
//  OpenWriterDocumentIntent.swift
//  LunaWriter
//

import AppIntents
import Foundation
import LunaWriterStorage

/// "Open <sheet> in Luna Writer".
struct OpenWriterDocumentIntent: AppIntent {
    static let title: LocalizedStringResource = "WriterIntents_openDocument_title_Luna"
    static let description = IntentDescription("WriterIntents_openDocument_description_Luna")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "WriterIntents_openDocument_documentParameter_title_Luna")
    var document: WriterDocumentEntity

    static var parameterSummary: some ParameterSummary {
        Summary("WriterIntents_openDocument_summary_Luna \(\.$document)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard try WriterWiring.intentServices().document(document.documentID) != nil else {
            throw WriterIntentServices.Failure.missingDocument
        }
        WriterWiring.show(document: document.documentID)
        return .result()
    }
}
