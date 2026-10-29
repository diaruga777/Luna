import AppIntents
import CoreSpotlight
import Foundation
import LunaVaultBEP
import LunaVaultStore
import LunaVaultUI

struct VaultFileEntity: IndexedEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Vault Item"
    static var defaultQuery = VaultFileQuery()
    var id: String
    @Property(title: "ID") var identifier: String
    @Property(title: "Name") var name: String
    @Property(title: "Path") var path: String
    @Property(title: "Modified Date") var modifiedDate: Date
    @Property(title: "Added Date") var addedDate: Date
    @Property(title: "Size") var size: Int
    @Property(title: "Folder") var folder: Bool
    @Property(title: "Downloaded") var downloaded: Bool
    @Property(title: "Pinned") var pinned: Bool
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)", subtitle: "\(path)") }
    init(_ file: VaultFileRecord, folderID: String) {
        // A path on a replacement Mac is a different entity.
        id = Data((folderID + "\n" + file.name).utf8).base64EncodedString()
        identifier = id
        name = file.displayName; path = file.name; modifiedDate = file.modified; addedDate = file.firstSeen
        size = Int(clamping: file.size); folder = file.type == .directory; downloaded = file.isCachedCurrent; pinned = file.cache?.pinned ?? false
    }
    static func identity(in store: VaultFolderStore) throws -> String {
        guard let peer = try store.peer() else { throw VaultIntentError.unpaired }
        return peer.deviceID.description + ":" + peer.folderID
    }
    func resolve(in store: VaultFolderStore) throws -> VaultFileRecord {
        guard let file = try store.file(named: path), !file.deleted, !file.invalid,
              Self.id(file, store: store) == id else { throw VaultIntentError.missing }
        return file
    }
    private static func id(_ file: VaultFileRecord, store: VaultFolderStore) -> String? {
        (try? identity(in: store)).map { VaultFileEntity(file, folderID: $0).id }
    }
}
enum VaultIntentError: LocalizedError {
    case missing, unpaired, folder
    var errorDescription: String? {
        switch self {
        case .missing: return "This Vault item is no longer available."
        case .unpaired: return "Connect Luna Vault to your Mac first."
        case .folder: return "Choose a file to export."
        }
    }
}
struct VaultFileQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [VaultFileEntity] {
        let store = try VaultFolderStore.production()
        guard let identity = try? VaultFileEntity.identity(in: store) else { return [] }
        return try identifiers.compactMap { id in
            guard let data = Data(base64Encoded: id), let value = String(data: data, encoding: .utf8),
                  value.hasPrefix(identity + "\n") else { return nil }
            let name = String(value.dropFirst(identity.count + 1))
            guard let file = try store.file(named: name), !file.deleted, !file.invalid else { return nil }
            return VaultFileEntity(file, folderID: identity)
        }
    }
    func entities(matching string: String) async throws -> [VaultFileEntity] {
        try all().filter { $0.path.localizedStandardContains(string) }
    }
    func suggestedEntities() async throws -> [VaultFileEntity] { Array(try all(limit: 30)) }
    func all(limit: Int = Int.max) throws -> [VaultFileEntity] {
        let store = try VaultFolderStore.production()
        guard let identity = try? VaultFileEntity.identity(in: store) else { return [] }
        return try store.automationItems(limit: limit).map { VaultFileEntity($0, folderID: identity) }
    }
}
struct FindVaultItemsIntent: AppIntent {
    static var title: LocalizedStringResource = "Find Vault Items"
    @Parameter(title: "Search", default: "") var search: String
    @Parameter(title: "Path") var path: String?
    @Parameter(title: "Modified After") var after: Date?
    @Parameter(title: "Folders Only", default: false) var foldersOnly: Bool
    @Parameter(title: "Limit", default: 20, inclusiveRange: (1, 500)) var limit: Int
    func perform() async throws -> some IntentResult & ReturnsValue<[VaultFileEntity]> {
        let items = try VaultFileQuery().all().filter {
            (path == nil || $0.path == path) && (search.isEmpty || $0.path.localizedStandardContains(search))
                && (after == nil || $0.modifiedDate > after!) && (!foldersOnly || $0.folder)
        }
        return .result(value: Array(items.prefix(max(1, min(limit, 500)))))
    }
}
struct GetVaultFileIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Vault File"
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Item") var item: VaultFileEntity
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let runtime = try VaultConnectedWiring.intentRuntime()
        let file = try item.resolve(in: runtime.store)
        guard file.type == .file else { throw VaultIntentError.folder }
        let url = try await runtime.fileURL(named: file.name)
        return .result(value: IntentFile(fileURL: url, filename: file.displayName))
    }
}
struct ImportVaultFileIntent: AppIntent {
    static var title: LocalizedStringResource = "Save File to Vault"
    static var description = IntentDescription("Copy a file into Vault and queue it for sync to your paired Mac.")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "File") var file: IntentFile
    @Parameter(title: "Path") var path: String?
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<VaultFileEntity> {
        let runtime = try VaultConnectedWiring.intentRuntime()
        let name = (path?.isEmpty == false ? path! : (file.filename as NSString).lastPathComponent).precomposedStringWithCanonicalMapping
        try BEPFileInfo.validateName(name)
        let source: URL
        var temporary: URL?
        if let url = file.fileURL { source = url }
        else {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("input"); try file.data.write(to: url); source = url; temporary = directory
        }
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        try await runtime.importFile(at: source, named: name)
        VaultConnectedWiring.resumeIntentTransfers()
        guard let stored = try runtime.store.file(named: name) else { throw VaultIntentError.missing }
        return .result(value: VaultFileEntity(stored, folderID: try VaultFileEntity.identity(in: runtime.store)))
    }
}
struct CreateVaultFolderIntent: AppIntent {
    static var title: LocalizedStringResource = "Create Vault Folder"
    @Parameter(title: "Path") var path: String
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<VaultFileEntity> {
        let runtime = try VaultConnectedWiring.intentRuntime()
        try await runtime.importDirectory(named: path)
        VaultConnectedWiring.resumeIntentTransfers()
        guard let file = try runtime.store.file(named: path) else { throw VaultIntentError.missing }
        return .result(value: VaultFileEntity(file, folderID: try VaultFileEntity.identity(in: runtime.store)))
    }
}
struct DeleteVaultItemsIntent: AppIntent {
    static var title: LocalizedStringResource = "Delete Vault Items"
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Items") var items: [VaultFileEntity]
    @MainActor func perform() async throws -> some IntentResult {
        let runtime = try VaultConnectedWiring.intentRuntime()
        let records = try items.map { try $0.resolve(in: runtime.store) }
        try await requestConfirmation(result: .result(dialog: "Delete \(records.count) items from Vault and your paired Mac?"))
        for record in records { try await runtime.deleteItem(named: record.name) }
        VaultConnectedWiring.resumeIntentTransfers(); return .result()
    }
}
struct SetVaultItemPinnedIntent: AppIntent {
    static var title: LocalizedStringResource = "Keep Vault File Downloaded"
    @Parameter(title: "Item") var item: VaultFileEntity
    @Parameter(title: "Keep Downloaded", default: true) var pinned: Bool
    @MainActor func perform() async throws -> some IntentResult {
        let runtime = try VaultConnectedWiring.intentRuntime()
        let file = try item.resolve(in: runtime.store)
        guard file.type == .file else { throw VaultIntentError.folder }
        if pinned { _ = try await runtime.fileURL(named: file.name) }
        try runtime.store.setCachePinned(name: file.name, pinned: pinned)
        return .result()
    }
}
struct LunaVaultShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: FindVaultItemsIntent(), phrases: ["Find files in \(.applicationName)"], shortTitle: "Find Vault Items", systemImageName: "magnifyingglass")
        AppShortcut(intent: ImportVaultFileIntent(), phrases: ["Save a file to \(.applicationName)"], shortTitle: "Save File to Vault", systemImageName: "square.and.arrow.down")
    }
}
