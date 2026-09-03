//
//  CreateWriterDocumentIntent.swift
//  LunaWriter
//

import AppIntents
import Foundation
import LunaWriterStorage

/// "New sheet in Luna Writer": creates the sheet, then opens the app on it.
struct CreateWriterDocumentIntent: AppIntent {
    static let title: LocalizedStringResource = "WriterIntents_createDocument_title_Luna"
    static let description = IntentDescription("WriterIntents_createDocument_description_Luna")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "WriterIntents_createDocument_titleParameter_title_Luna")
    var sheetTitle: String?

    @Parameter(title: "WriterIntents_createDocument_textParameter_title_Luna")
    var text: String?

    static var parameterSummary: some ParameterSummary {
        Summary("WriterIntents_createDocument_summary_Luna") {
            \.$sheetTitle
            \.$text
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let document = try WriterWiring.intentServices().createDocument(
            title: sheetTitle, text: text, in: nil)
        WriterWiring.show(document: document.id)
        return .result()
    }
}
