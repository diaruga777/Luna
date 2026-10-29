import AppIntents
import CoreSpotlight
import Foundation
import LunaAppConfig
import LunaStorage

struct KeyboardShortcutEntity: IndexedEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Keyboard Shortcut"
    static var defaultQuery = KeyboardShortcutQuery()
    var id: String
    @Property(title: "ID") var identifier: String
    @Property(title: "Text") var text: String
    @Property(title: "Keywords") var keywords: [String]
    @Property(title: "Kind") var kind: String
    @Property(title: "Suggest While Typing") var suggestWhileTyping: Bool
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(keywords.first ?? text)", subtitle: "\(text)") }
    init(_ shortcut: KeyboardShortcut) { id = shortcut.id; identifier = id; text = shortcut.text; keywords = shortcut.keywords; kind = shortcut.kind; suggestWhileTyping = shortcut.suggestWhileTyping }
}
struct KeyboardShortcutQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [KeyboardShortcutEntity] { try identifiers.compactMap { try KeyboardStore().shortcut(id: $0) }.map(KeyboardShortcutEntity.init) }
    func entities(matching string: String) async throws -> [KeyboardShortcutEntity] { try KeyboardStore().searchShortcuts(string).map(KeyboardShortcutEntity.init) }
    func suggestedEntities() async throws -> [KeyboardShortcutEntity] { try KeyboardStore().shortcuts(limit: 30).map(KeyboardShortcutEntity.init) }
}
struct FindKeyboardShortcutsIntent: AppIntent {
    static var title: LocalizedStringResource = "Find Keyboard Shortcuts"
    @Parameter(title: "Search", default: "") var search: String
    @Parameter(title: "Item ID") var itemID: String?
    @Parameter(title: "Limit", default: 100, inclusiveRange: (1, 500)) var limit: Int
    func perform() async throws -> some IntentResult & ReturnsValue<[KeyboardShortcutEntity]> {
        if let itemID { return .result(value: try await KeyboardShortcutQuery().entities(for: [itemID])) }
        return .result(value: try KeyboardStore().shortcuts(limit: limit, searchTokens: search.lowercased().split(separator: " ").prefix(8).map(String.init)).map(KeyboardShortcutEntity.init))
    }
}
struct SaveKeyboardShortcutIntent: AppIntent {
    static var title: LocalizedStringResource = "Save Keyboard Shortcut"
    static var description = IntentDescription("Create a text shortcut, or update an existing shortcut’s text and keywords.")
    @Parameter(title: "Existing Shortcut") var existing: KeyboardShortcutEntity?
    @Parameter(title: "Text") var text: String
    @Parameter(title: "Keywords") var keywords: [String]
    @Parameter(title: "Suggest While Typing", default: true) var suggest: Bool
    func perform() async throws -> some IntentResult & ReturnsValue<KeyboardShortcutEntity> {
        let store = KeyboardStore()
        var shortcut: KeyboardShortcut
        if let existing {
            guard let value = try store.shortcut(id: existing.id) else { throw CocoaError(.fileNoSuchFile) }; shortcut = value
        } else { shortcut = KeyboardShortcut(keywords: [], text: "") }
        shortcut.text = text; shortcut.keywords = keywords; shortcut.suggestWhileTyping = suggest
        try store.save(shortcut)
        guard let saved = try store.shortcut(id: shortcut.id) else { throw CocoaError(.fileNoSuchFile) }
        return .result(value: KeyboardShortcutEntity(saved))
    }
}
struct DeleteKeyboardShortcutsIntent: AppIntent {
    static var title: LocalizedStringResource = "Delete Keyboard Shortcuts"
    @Parameter(title: "Shortcuts") var shortcuts: [KeyboardShortcutEntity]
    func perform() async throws -> some IntentResult {
        try await requestConfirmation(result: .result(dialog: "Delete \(shortcuts.count) keyboard shortcuts?"))
        for shortcut in shortcuts { try KeyboardStore().delete(id: shortcut.id) }
        return .result()
    }
}
struct GetKeyboardShortcutFileIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Keyboard Shortcut File"
    @Parameter(title: "Shortcut") var shortcut: KeyboardShortcutEntity
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let store = KeyboardStore()
        guard let saved = try store.shortcut(id: shortcut.id), let url = store.fileURL(for: saved), FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileNoSuchFile) }
        return .result(value: IntentFile(fileURL: url))
    }
}
struct KeyboardWordEntity: IndexedEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Dictionary Word"
    static var defaultQuery = KeyboardWordQuery()
    var id: String
    @Property(title: "ID") var identifier: String
    @Property(title: "Word") var word: String
    @Property(title: "Language") var language: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(word)", subtitle: "\(language)") }
    init(word: String, language: String) {
        id = language + ":" + word
        identifier = id
        self.word = word; self.language = language
    }
}
struct KeyboardWordQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [KeyboardWordEntity] {
        try identifiers.compactMap { id in
            guard let colon = id.firstIndex(of: ":") else { return nil }
            let language = String(id[..<colon]), word = String(id[id.index(after: colon)...])
            guard try KeyboardStore().dictionary(language: language, prefix: word).contains(word) else { return nil }
            return KeyboardWordEntity(word: word, language: language)
        }
    }
    func entities(matching string: String) async throws -> [KeyboardWordEntity] { try KeyboardStore().allDictionaryWords().filter { $0.word.localizedStandardContains(string) }.map { KeyboardWordEntity(word: $0.word, language: $0.language) } }
    func suggestedEntities() async throws -> [KeyboardWordEntity] { try KeyboardStore().allDictionaryWords().prefix(30).map { KeyboardWordEntity(word: $0.word, language: $0.language) } }
}
struct SetKeyboardDictionaryWordIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Keyboard Dictionary Word"
    @Parameter(title: "Word") var word: String
    @Parameter(title: "Language", default: "en") var language: String
    @Parameter(title: "Included", default: true) var included: Bool
    func perform() async throws -> some IntentResult {
        try KeyboardStore().setWord(word, language: language, included: included); return .result()
    }
}
struct LunaKeyboardShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: FindKeyboardShortcutsIntent(), phrases: ["Find shortcuts in \(.applicationName)"], shortTitle: "Find Keyboard Shortcuts", systemImageName: "keyboard")
        AppShortcut(intent: SaveKeyboardShortcutIntent(), phrases: ["Save a shortcut in \(.applicationName)"], shortTitle: "Save Keyboard Shortcut", systemImageName: "plus")
    }
}

struct FindKeyboardWordsIntent: AppIntent {
    static var title: LocalizedStringResource = "Find Dictionary Words"
    @Parameter(title: "Search", default: "") var search: String
    @Parameter(title: "Language") var language: String?
    @Parameter(title: "Limit", default: 100, inclusiveRange: (1, 500)) var limit: Int
    func perform() async throws -> some IntentResult & ReturnsValue<[KeyboardWordEntity]> {
        let words = try KeyboardStore().allDictionaryWords().filter {
            (language == nil || $0.language == language) && (search.isEmpty || $0.word.localizedStandardContains(search))
        }
        return .result(value: words.prefix(max(1, min(500, limit))).map { KeyboardWordEntity(word: $0.word, language: $0.language) })
    }
}
struct DeleteKeyboardWordsIntent: AppIntent {
    static var title: LocalizedStringResource = "Delete Dictionary Words"
    @Parameter(title: "Words") var words: [KeyboardWordEntity]
    func perform() async throws -> some IntentResult {
        for word in words { try KeyboardStore().setWord(word.word, language: word.language, included: false) }
        return .result()
    }
}
struct KeyboardPreferenceEntity: IndexedEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Keyboard Preference"
    static var defaultQuery = KeyboardPreferenceQuery()
    var id: String
    @Property(title: "Key") var key: String
    @Property(title: "Value") var value: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(key)", subtitle: "\(value)") }
    init(key: String, value: String) { id = key; self.key = key; self.value = value }
}
struct KeyboardPreferenceQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [KeyboardPreferenceEntity] {
        let values = try KeyboardStore().preferences()
        return identifiers.compactMap { key in values[key].map { KeyboardPreferenceEntity(key: key, value: $0) } }
    }
    func entities(matching string: String) async throws -> [KeyboardPreferenceEntity] {
        try KeyboardStore().preferences().filter { string.isEmpty || $0.key.localizedStandardContains(string) }.sorted { $0.key < $1.key }.map { KeyboardPreferenceEntity(key: $0.key, value: $0.value) }
    }
    func suggestedEntities() async throws -> [KeyboardPreferenceEntity] { try await entities(matching: "") }
}
struct GetKeyboardPreferencesIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Keyboard Preferences"
    func perform() async throws -> some IntentResult & ReturnsValue<[KeyboardPreferenceEntity]> {
        .result(value: try await KeyboardPreferenceQuery().suggestedEntities())
    }
}
struct SetKeyboardPreferenceIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Keyboard Preference"
    @Parameter(title: "Preference") var preference: KeyboardPreferenceEntity
    @Parameter(title: "Value") var value: String
    func perform() async throws -> some IntentResult {
        // Resolve the key again instead of trusting a stale entity snapshot.
        guard try KeyboardStore().preferences()[preference.id] != nil else { throw CocoaError(.fileNoSuchFile) }
        try KeyboardStore().setPreference(preference.id, value: value)
        return .result()
    }
}
