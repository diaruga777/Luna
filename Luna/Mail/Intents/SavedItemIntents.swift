import AppIntents
import CoreSpotlight
import Foundation
import LunaAppConfig
import LunaAudioPlayback
import LunaIntents
import LunaModels
import LunaStorage
import LunaSaves

/// All user saves, including documents, media, social links and products.
/// Properties are a snapshot; actions resolve the ID against current storage.
struct SavedItemEntity: IndexedEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Saved Item"
    static var defaultQuery = SavedItemEntityQuery()
    var id: UUID
    @Property(title: "ID") var identifier: String
    @Property(title: "Title") var title: String
    @Property(title: "URL") var url: String
    @Property(title: "Saved Date") var savedDate: Date
    @Property(title: "Kind") var kind: String
    @Property(title: "State") var state: String
    @Property(title: "Read State") var readState: String
    @Property(title: "Archived") var archived: Bool
    @Property(title: "Word Count") var wordCount: Int
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)", subtitle: "\(kind)") }
    init(_ item: SavedItem) {
        id = item.id; identifier = item.id.uuidString; title = item.title ?? item.urlString; url = item.urlString; savedDate = item.dateAdded
        kind = item.state == .link ? "link" : item.exportKind.rawValue; state = item.state.rawValue; readState = item.readState.rawValue
        archived = item.isArchived; wordCount = item.wordCount ?? 0
    }
}
struct SavedItemEntityQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [SavedItemEntity] { identifiers.compactMap { SavesStore.shared.item(withID: $0) }.map(SavedItemEntity.init) }
    func entities(matching string: String) async throws -> [SavedItemEntity] {
        SavesStore.shared.items().filter { ($0.title ?? "").localizedStandardContains(string) || $0.urlString.localizedStandardContains(string) }.map(SavedItemEntity.init)
    }
    func suggestedEntities() async throws -> [SavedItemEntity] { Array(SavesStore.shared.items().prefix(30)).map(SavedItemEntity.init) }
}
enum SavedItemIntentError: LocalizedError {
    case missing, invalidID
    var errorDescription: String? { self == .missing ? "This saved item is no longer available." : "Enter a saved item’s ID." }
}
struct FindSavedItemsIntent: AppIntent {
    static var title: LocalizedStringResource = "Find Saved Items"
    static var description = IntentDescription("Find saves, newest first by original saved date. Use Item ID to resolve an item from a data change.")
    @Parameter(title: "Search") var search: String?
    @Parameter(title: "Item ID") var itemID: String?
    @Parameter(title: "Saved After") var after: Date?
    @Parameter(title: "Kind") var kind: String?
    @Parameter(title: "Include Archived", default: false) var includeArchived: Bool
    @Parameter(title: "Limit", default: 20, inclusiveRange: (1, 500)) var limit: Int
    func perform() async throws -> some IntentResult & ReturnsValue<[SavedItemEntity]> {
        if let itemID, !itemID.isEmpty {
            guard let id = UUID(uuidString: itemID) else { throw SavedItemIntentError.invalidID }
            guard let item = SavesStore.shared.item(withID: id) else { throw SavedItemIntentError.missing }
            return .result(value: [SavedItemEntity(item)])
        }
        let items = SavesStore.shared.items().filter { item in
            (includeArchived || !item.isArchived) && (after == nil || item.dateAdded > after!)
                && (kind == nil || kind?.isEmpty == true || (item.state == .link ? "link" : item.exportKind.rawValue) == kind)
                && (search == nil || search?.isEmpty == true || (item.title ?? "").localizedStandardContains(search!) || item.urlString.localizedStandardContains(search!))
        }.sorted { $0.dateAdded == $1.dateAdded ? $0.id.uuidString < $1.id.uuidString : $0.dateAdded > $1.dateAdded }
        return .result(value: Array(items.prefix(max(1, min(limit, 500)))).map(SavedItemEntity.init))
    }
}
struct GetSavedItemTextIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Saved Item Text"
    @Parameter(title: "Item") var item: SavedItemEntity
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let saved = SavesStore.shared.item(withID: item.id), let content = SavesStore.shared.content(for: saved) else { throw SavedItemIntentError.missing }
        return .result(value: content.blocks.map(\.text).joined(separator: "\n\n"))
    }
}
enum SavedItemAction: String, AppEnum {
    case markRead, markUnread, archive, unarchive, delete
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Saved Item Action"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [.markRead: "Mark Read", .markUnread: "Mark Unread", .archive: "Archive", .unarchive: "Unarchive", .delete: "Delete"]
}
struct UpdateSavedItemsIntent: AppIntent {
    static var title: LocalizedStringResource = "Update Saved Items"
    @Parameter(title: "Items") var items: [SavedItemEntity]
    @Parameter(title: "Action") var action: SavedItemAction
    func perform() async throws -> some IntentResult {
        let store = SavesStore.shared
        let resolved = try items.map { entity -> SavedItem in
            guard let item = store.item(withID: entity.id) else { throw SavedItemIntentError.missing }; return item
        }
        if action == .delete { try await requestConfirmation(result: .result(dialog: "Delete \(resolved.count) saved items?")) }
        for item in resolved {
            switch action {
            case .markRead: store.markFinishedReading(item.id)
            case .markUnread: store.markUnread(item.id)
            case .archive: store.setArchived(true, for: item.id)
            case .unarchive: store.setArchived(false, for: item.id)
            case .delete: store.delete(item)
            }
        }
        return .result()
    }
}
enum ArticleExportVoice: String, AppEnum {
    case device, gemini
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Read-Aloud Voice"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [.device: "Device Voice", .gemini: "Gemini Voice"]
}
struct GetArticleAudioIntent: AppIntent, ProgressReportingIntent {
    static var title: LocalizedStringResource = "Get Article Audio"
    static var description = IntentDescription("Create an M4A read-aloud file from a saved article. Pass the file to another app, save it, or add it to a podcast queue.")
    @Parameter(title: "Item") var item: SavedItemEntity
    @Parameter(title: "Voice", default: .device) var voice: ArticleExportVoice
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        progress.totalUnitCount = 100
        let url: URL
        #if compiler(>=6.4)
        if #available(iOS 27, *) { url = try await performBackgroundTask { try await renderAudio() } }
        else { url = try await renderAudio() }
        #else
        url = try await renderAudio()
        #endif
        return .result(value: IntentFile(fileURL: url, filename: "Article.m4a", type: .mpeg4Audio))
    }
    private func renderAudio() async throws -> URL {
        let heartbeat = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                if progress.completedUnitCount < 99 { progress.completedUnitCount += 1 }
            }
        }
        defer { heartbeat.cancel() }
        return try await ArticleAudioExport.write(saveID: item.id, voice: voice == .device ? .device : .gemini) { value in
            progress.completedUnitCount = max(progress.completedUnitCount, Int64(value * 100))
        }
    }
}
#if compiler(>=6.4)
@available(iOS 27, *)
extension GetArticleAudioIntent: LongRunningIntent {}
#endif

struct SaveURLToReaderIntent: AppIntent {
    static var title: LocalizedStringResource = "Save URL"
    static var description = IntentDescription("Save a URL and extract its content using Luna Reader’s normal save pipeline.")
    @Parameter(title: "URL") var url: URL
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<SavedItemEntity> {
        await AppLaunchServices.shared.waitUntilReady()
        return .result(value: SavedItemEntity(try await ReaderURLSave.save(url)))
    }
}
