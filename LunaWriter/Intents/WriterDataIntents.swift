import AppIntents
import CoreSpotlight
import Foundation
import LunaWriterModels
import LunaWriterStorage

struct FindWriterSheetsIntent: AppIntent {
    static var title: LocalizedStringResource = "Find Writer Sheets"
    @Parameter(title: "Search", default: "") var search: String
    @Parameter(title: "Item ID") var itemID: String?
    @Parameter(title: "Modified After") var after: Date?
    @Parameter(title: "Limit", default: 50, inclusiveRange: (1, 500)) var limit: Int
    func perform() async throws -> some IntentResult & ReturnsValue<[WriterDocumentEntity]> {
        let id = try WriterObjectID.parse(itemID).map(DocumentID.init)
        return .result(value: try WriterWiring.intentServices().findDocuments(search: search, id: id, modifiedAfter: after, limit: limit).map(WriterDocumentEntity.init(document:)))
    }
}
struct GetWriterSheetTextIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Writer Sheet Text"
    @Parameter(title: "Sheet") var sheet: WriterDocumentEntity
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try WriterWiring.intentServices().text(for: sheet.documentID))
    }
}

struct WriterNoteEntity: IndexedEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Writer Note"
    static var defaultQuery = WriterNoteQuery()
    var id: UUID
    @Property(title: "ID") var identifier: String
    @Property(title: "Text") var text: String
    @Property(title: "Sheet IDs") var sheetIDs: [String]
    @Property(title: "Created Date") var created: Date
    @Property(title: "Modified Date") var modified: Date
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(text)") }
    init(_ note: WriterNote) {
        id = note.id.rawValue; identifier = id.uuidString; text = note.text
        sheetIDs = note.documentIDs.map { $0.rawValue.uuidString }; created = note.createdAt; modified = note.updatedAt
    }
}
struct WriterNoteQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [WriterNoteEntity] {
        let services = try WriterWiring.intentServices()
        return try identifiers.flatMap { try services.findNotes(id: NoteID($0)).map(WriterNoteEntity.init) }
    }
    func entities(matching string: String) async throws -> [WriterNoteEntity] {
        try WriterWiring.intentServices().findNotes(search: string).map(WriterNoteEntity.init)
    }
    func suggestedEntities() async throws -> [WriterNoteEntity] { try await entities(matching: "") }
}
struct FindWriterNotesIntent: AppIntent {
    static var title: LocalizedStringResource = "Find Writer Notes"
    @Parameter(title: "Search", default: "") var search: String
    @Parameter(title: "Item ID") var itemID: String?
    @Parameter(title: "Sheet") var sheet: WriterDocumentEntity?
    @Parameter(title: "Limit", default: 50, inclusiveRange: (1, 500)) var limit: Int
    func perform() async throws -> some IntentResult & ReturnsValue<[WriterNoteEntity]> {
        .result(value: try WriterWiring.intentServices().findNotes(search: search, id: WriterObjectID.parse(itemID).map(NoteID.init), document: sheet?.documentID, limit: limit).map(WriterNoteEntity.init))
    }
}
struct UpdateWriterNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Update Writer Note"
    @Parameter(title: "Note") var note: WriterNoteEntity
    @Parameter(title: "Text") var text: String
    func perform() async throws -> some IntentResult & ReturnsValue<WriterNoteEntity> {
        .result(value: WriterNoteEntity(try WriterWiring.intentServices().updateNote(NoteID(note.id), text: text)))
    }
}
struct DeleteWriterNotesIntent: AppIntent {
    static var title: LocalizedStringResource = "Delete Writer Notes"
    @Parameter(title: "Notes") var notes: [WriterNoteEntity]
    func perform() async throws -> some IntentResult {
        try await requestConfirmation(result: .result(dialog: "Delete \(notes.count) notes?"))
        try WriterWiring.intentServices().deleteNotes(notes.map { NoteID($0.id) })
        return .result()
    }
}

struct WriterGroupEntity: IndexedEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Writer Folder"
    static var defaultQuery = WriterGroupQuery()
    var id: UUID
    @Property(title: "ID") var identifier: String
    @Property(title: "Name") var name: String
    @Property(title: "Kind") var kind: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    init(_ group: WriterGroup) { id = group.id.rawValue; identifier = id.uuidString; name = group.name; kind = group.kind.rawValue }
}
struct WriterGroupQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [WriterGroupEntity] {
        let groups = try WriterWiring.intentServices().groups()
        return identifiers.compactMap { id in groups.first { $0.id.rawValue == id }.map(WriterGroupEntity.init) }
    }
    func entities(matching string: String) async throws -> [WriterGroupEntity] {
        try WriterWiring.intentServices().groups().filter { string.isEmpty || $0.name.localizedStandardContains(string) }.map(WriterGroupEntity.init)
    }
    func suggestedEntities() async throws -> [WriterGroupEntity] { try await entities(matching: "") }
}
struct FindWriterFoldersIntent: AppIntent {
    static var title: LocalizedStringResource = "Find Writer Folders"
    @Parameter(title: "Search", default: "") var search: String
    @Parameter(title: "Item ID") var itemID: String?
    func perform() async throws -> some IntentResult & ReturnsValue<[WriterGroupEntity]> {
        if let id = try WriterObjectID.parse(itemID) { return .result(value: try await WriterGroupQuery().entities(for: [id])) }
        return .result(value: try await WriterGroupQuery().entities(matching: search))
    }
}
struct CreateWriterFolderIntent: AppIntent {
    static var title: LocalizedStringResource = "Create Writer Folder"
    @Parameter(title: "Name") var name: String
    func perform() async throws -> some IntentResult & ReturnsValue<WriterGroupEntity> {
        .result(value: WriterGroupEntity(try WriterWiring.intentServices().createGroup(name: name)))
    }
}
private enum WriterObjectID {
    static func parse(_ value: String?) throws -> UUID? {
        guard let value, !value.isEmpty else { return nil }
        guard let id = UUID(uuidString: value) else { throw WriterIDError.invalid }
        return id
    }
}

private enum WriterIDError: LocalizedError {
    case invalid
    var errorDescription: String? { "Enter an item’s ID." }
}
