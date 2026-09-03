//
//  AddWriterNoteIntent.swift
//  LunaWriter
//

import AppIntents
import Foundation
import LunaModels
import LunaWriterStorage

/// "Add a note to Luna Writer". Runs without opening the app. Named a sheet,
/// the note goes there; named nothing, the router files it the way Pen does
/// (claudedocs/plans/writer-app.md §5.4).
struct AddWriterNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "WriterIntents_addNote_title_Luna"
    static let description = IntentDescription("WriterIntents_addNote_description_Luna")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "WriterIntents_addNote_textParameter_title_Luna")
    var text: String

    @Parameter(title: "WriterIntents_addNote_documentParameter_title_Luna")
    var document: WriterDocumentEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("WriterIntents_addNote_summary_Luna \(\.$text)") {
            \.$document
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try WriterWiring.intentServices().addNote(text: text, to: document?.documentID)
        let spoken: String
        switch result {
        case .document(let sheet):
            spoken = L10n.string("WriterIntents_addNote_addedToSheet", sheet.title)
        case .inbox:
            spoken = L10n.string("WriterIntents_addNote_addedToInbox")
        }
        return .result(dialog: IntentDialog(stringLiteral: spoken))
    }
}
