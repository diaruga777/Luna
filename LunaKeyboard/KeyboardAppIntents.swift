import AppIntents
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers
import LunaAppConfig
import LunaKeyboardCore
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
    static var description = IntentDescription("Find saved text and image shortcuts by their text or keywords. Use Item ID for one exact shortcut; it overrides Search.")
    @Parameter(title: "Search", default: "") var search: String
    @Parameter(title: "Item ID", description: "The exact ID property from an item or data change. Leave blank to search instead.") var itemID: String?
    @Parameter(title: "Maximum Results", description: "The most items to return, from 1 to 500.", default: 100, inclusiveRange: (1, 500)) var limit: Int
    static var parameterSummary: some ParameterSummary {
        Summary("Find Keyboard Shortcuts") {
            \.$search
            \.$itemID
            \.$limit
        }
    }
    func perform() async throws -> some IntentResult & ReturnsValue<[KeyboardShortcutEntity]> {
        if let itemID, !itemID.isEmpty { return .result(value: try await KeyboardShortcutQuery().entities(for: [itemID])) }
        return .result(value: try KeyboardStore().shortcuts(limit: limit, searchTokens: search.lowercased().split(separator: " ").prefix(8).map(String.init)).map(KeyboardShortcutEntity.init))
    }
}
struct SaveKeyboardShortcutIntent: AppIntent {
    static var title: LocalizedStringResource = "Save Keyboard Shortcut"
    static var description = IntentDescription("Create a text or image shortcut, or update an existing shortcut.")
    @Parameter(title: "Existing Shortcut", description: "Leave blank to create a shortcut. Choose a shortcut to replace its text, keywords and suggestion setting; a blank Image keeps its existing image.") var existing: KeyboardShortcutEntity?
    @Parameter(title: "Text", default: "") var text: String
    @Parameter(title: "Image") var image: IntentFile?
    @Parameter(title: "Keywords", description: "Words that trigger this shortcut’s typing suggestions. Add each keyword as a separate entry.") var keywords: [String]
    @Parameter(title: "Suggest While Typing", default: true) var suggest: Bool
    static var parameterSummary: some ParameterSummary {
        Summary("Save Keyboard Shortcut") {
            \.$existing
            \.$text
            \.$image
            \.$keywords
            \.$suggest
        }
    }
    func perform() async throws -> some IntentResult & ReturnsValue<KeyboardShortcutEntity> {
        let store = KeyboardStore()
        var shortcut: KeyboardShortcut
        if let existing {
            guard let value = try store.shortcut(id: existing.id) else { throw CocoaError(.fileNoSuchFile) }; shortcut = value
        } else { shortcut = KeyboardShortcut(keywords: [], text: "") }
        shortcut.text = text; shortcut.keywords = keywords; shortcut.suggestWhileTyping = suggest
        var temporary: URL?
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        let source: URL?
        if let image {
            let filename = (image.filename as NSString).lastPathComponent
            let ext = (filename as NSString).pathExtension.lowercased()
            guard let type = UTType(filenameExtension: ext), type.conforms(to: .image) else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            if let url = image.fileURL { source = url }
            else {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                temporary = directory
                let url = directory.appendingPathComponent(filename)
                try image.data.write(to: url)
                source = url
            }
            shortcut.kind = ext == "gif" ? "gif" : "image"
        } else { source = nil }
        let access = source?.startAccessingSecurityScopedResource() ?? false
        defer { if access { source?.stopAccessingSecurityScopedResource() } }
        try store.save(shortcut, importing: source)
        guard let saved = try store.shortcut(id: shortcut.id) else { throw CocoaError(.fileNoSuchFile) }
        return .result(value: KeyboardShortcutEntity(saved))
    }
}
struct DeleteKeyboardShortcutsIntent: AppIntent {
    static var title: LocalizedStringResource = "Delete Keyboard Shortcuts"
    static var description = IntentDescription("Delete saved keyboard shortcuts after confirmation.")
    @Parameter(title: "Shortcuts") var shortcuts: [KeyboardShortcutEntity]
    static var parameterSummary: some ParameterSummary {
        Summary("Delete Keyboard Shortcuts") {
            \.$shortcuts
        }
    }
    func perform() async throws -> some IntentResult {
        try await requestConfirmation(result: .result(dialog: "Delete \(shortcuts.count) keyboard shortcuts?"))
        for shortcut in shortcuts { try KeyboardStore().delete(id: shortcut.id) }
        return .result()
    }
}
struct GetKeyboardShortcutFileIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Keyboard Shortcut File"
    static var description = IntentDescription("Get the image or GIF attached to a keyboard shortcut. Text-only shortcuts have no file.")
    @Parameter(title: "Shortcut") var shortcut: KeyboardShortcutEntity
    static var parameterSummary: some ParameterSummary {
        Summary("Get Keyboard Shortcut File") {
            \.$shortcut
        }
    }
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
    static var description = IntentDescription("Add a word to the keyboard’s personal dictionary, or remove it by turning Add to Dictionary off. Language Code identifies its dictionary.")
    @Parameter(title: "Word") var word: String
    @Parameter(title: "Language Code", description: "Use en for English, es for Spanish, es-419 for Latin American Spanish, or it for Italian.", default: "en") var language: String
    @Parameter(title: "Add to Dictionary", default: true) var included: Bool
    static var parameterSummary: some ParameterSummary {
        Summary("Set Keyboard Dictionary Word") {
            \.$word
            \.$language
            \.$included
        }
    }
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
    static var description = IntentDescription("Find words in the keyboard’s personal dictionaries. Leave Language Code blank to search all languages.")
    @Parameter(title: "Search", default: "") var search: String
    @Parameter(title: "Language Code", description: "For example, en for English or es for Spanish. Leave blank for all languages.") var language: String?
    @Parameter(title: "Maximum Results", description: "The most items to return, from 1 to 500.", default: 100, inclusiveRange: (1, 500)) var limit: Int
    static var parameterSummary: some ParameterSummary {
        Summary("Find Dictionary Words") {
            \.$search
            \.$language
            \.$limit
        }
    }
    func perform() async throws -> some IntentResult & ReturnsValue<[KeyboardWordEntity]> {
        let words = try KeyboardStore().allDictionaryWords().filter {
            (language == nil || language?.isEmpty == true || $0.language == language) && (search.isEmpty || $0.word.localizedStandardContains(search))
        }
        return .result(value: words.prefix(max(1, min(500, limit))).map { KeyboardWordEntity(word: $0.word, language: $0.language) })
    }
}
struct DeleteKeyboardWordsIntent: AppIntent {
    static var title: LocalizedStringResource = "Delete Dictionary Words"
    static var description = IntentDescription("Remove selected words from the keyboard’s personal dictionaries.")
    @Parameter(title: "Words") var words: [KeyboardWordEntity]
    static var parameterSummary: some ParameterSummary {
        Summary("Delete Dictionary Words") {
            \.$words
        }
    }
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
    @Property(title: "Name") var name: String
    @Property(title: "Accepted Values") var acceptedValues: String
    @Property(title: "Value") var value: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)", subtitle: "\(value)") }
    init(key: String, value: String) {
        id = key; self.key = key; self.value = value
        if let toggle = KeyboardPreferences.toggles.first(where: { $0.0 == key }) {
            name = toggle.1; acceptedValues = "true, false"
        } else {
            switch key {
            case "theme": name = "Theme"; acceptedValues = KeyboardTheme.allCases.map(\.rawValue).joined(separator: ", ")
            case "textStyle": name = "Text Style"; acceptedValues = TextStyle.allCases.map(\.rawValue).joined(separator: ", ")
            case "language": name = "Language"; acceptedValues = KeyboardPreferences.languages.map { $0.0 + " (" + $0.1 + ")" }.joined(separator: ", ")
            case "secondaryLanguage": name = "Second Language"; acceptedValues = "Leave empty for none; " + KeyboardPreferences.languages.map { $0.0 + " (" + $0.1 + ")" }.joined(separator: ", ")
            default: name = key; acceptedValues = ""
            }
        }
    }
}
struct KeyboardPreferenceQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [KeyboardPreferenceEntity] {
        let values = KeyboardPreferences(values: try KeyboardStore().preferences()).automationValues
        return identifiers.compactMap { key in values[key].map { KeyboardPreferenceEntity(key: key, value: $0) } }
    }
    func entities(matching string: String) async throws -> [KeyboardPreferenceEntity] {
        KeyboardPreferences(values: try KeyboardStore().preferences()).automationValues.map { KeyboardPreferenceEntity(key: $0.key, value: $0.value) }.filter { string.isEmpty || $0.name.localizedStandardContains(string) || $0.key.localizedStandardContains(string) }.sorted { $0.name < $1.name }
    }
    func suggestedEntities() async throws -> [KeyboardPreferenceEntity] { try await entities(matching: "") }
}
struct GetKeyboardPreferencesIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Keyboard Preferences"
    static var description = IntentDescription("Get supported keyboard preferences and their current values, including defaults. Each preference includes the values it accepts.")
    func perform() async throws -> some IntentResult & ReturnsValue<[KeyboardPreferenceEntity]> {
        .result(value: try await KeyboardPreferenceQuery().suggestedEntities())
    }
}
struct SetKeyboardPreferenceIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Keyboard Preference"
    static var description = IntentDescription("Change a preference from Get Keyboard Preferences. Use one of that preference’s Accepted Values. For on/off preferences, enter true or false.")
    @Parameter(title: "Preference") var preference: KeyboardPreferenceEntity
    @Parameter(title: "Value", description: "Use a value listed in the preference’s Accepted Values property. Boolean settings accept true or false.") var value: String
    static var parameterSummary: some ParameterSummary {
        Summary("Set Keyboard Preference") {
            \.$preference
            \.$value
        }
    }
    func perform() async throws -> some IntentResult {
        // Resolve the key again instead of trusting a stale entity snapshot.
        let validated = try KeyboardPreferences.validatedAutomationValue(value, for: preference.id)
        try KeyboardStore().setPreference(preference.id, value: validated)
        return .result()
    }
}
