//
//  CreateWriterDocumentIntent.swift
//  LunaWriter
//

import AppIntents
import Foundation
import LunaWriterStorage
import LunaWriterModels

/// "New sheet in Luna Writer": creates the sheet, then opens the app on it.
struct CreateWriterDocumentIntent: AppIntent {
    static let title: LocalizedStringResource = "WriterIntents_createDocument_title_Luna"
    static let description = IntentDescription("WriterIntents_createDocument_description_Luna")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "WriterIntents_createDocument_titleParameter_title_Luna")
    var sheetTitle: String?

    @Parameter(title: "WriterIntents_createDocument_textParameter_title_Luna")
    var text: String?

    @Parameter(title: "Folder") var group: WriterGroupEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("WriterIntents_createDocument_summary_Luna") {
            \.$sheetTitle
            \.$text
            \.$group
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<WriterDocumentEntity> {
        let document = try WriterWiring.intentServices().createDocument(
            title: sheetTitle, text: text, in: group.map { GroupID($0.id) })
        WriterWiring.show(document: document.id)
        return .result(value: WriterDocumentEntity(document: document))
    }
}
