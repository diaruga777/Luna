//
//  WriterDocumentEntity.swift
//  LunaWriter
//
//  A sheet as a Siri/Shortcuts entity. Lives in the app target for metadata
//  discovery; lookup runs on `WriterIntentServices`.
//

import AppIntents
import Foundation
import LunaWriterModels
import LunaWriterStorage

struct WriterDocumentEntity: AppEntity {
    let id: UUID
    @Property(title: "WriterIntents_documentEntity_titleProperty_title_Luna") var title: String
    @Property(title: "WriterIntents_documentEntity_modifiedProperty_title_Luna") var modified: Date

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "WriterIntents_documentEntity_typeName_Luna"
    static var defaultQuery = WriterDocumentEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(Self.dateFormatter.string(from: modified))")
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    init(document: WriterDocument) {
        id = document.id.rawValue
        title = document.title
        modified = document.updatedAt
    }

    var documentID: DocumentID { DocumentID(id) }
}

struct WriterDocumentEntityQuery: EntityQuery, EntityStringQuery {
    init() {}

    func entities(for identifiers: [UUID]) async throws -> [WriterDocumentEntity] {
        let services = try WriterWiring.intentServices()
        return try identifiers
            .compactMap { try services.document(DocumentID($0)) }
            .map(WriterDocumentEntity.init(document:))
    }

    func entities(matching string: String) async throws -> [WriterDocumentEntity] {
        try WriterWiring.intentServices().documents(matchingTitle: string)
            .map(WriterDocumentEntity.init(document:))
    }

    func suggestedEntities() async throws -> [WriterDocumentEntity] {
        try WriterWiring.intentServices().recentDocuments(limit: 10)
            .map(WriterDocumentEntity.init(document:))
    }
}
