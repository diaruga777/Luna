import AppIntents
import LunaIntents

struct GetArticleTextChunksIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Article Text Chunks"
    static var description = IntentDescription("Get a saved article or document as an ordered list of text chunks. Each chunk ends at the last sentence that fits, or a word boundary when a sentence is too long. Joining the chunks with no separator restores the full text.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Item", description: "A saved article or document from Find Saved Items.")
    var item: SavedItemEntity

    @Parameter(title: "Maximum Characters", description: "The maximum characters per chunk, including spaces and line breaks. At least 1. Words longer than the limit are split at whole characters.", default: 4000)
    var maximumCharacters: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Get text chunks from \(\.$item), up to \(\.$maximumCharacters) characters")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        .result(value: try ArticleTextChunks.chunks(saveID: item.id, maximumCharacters: maximumCharacters))
    }
}
