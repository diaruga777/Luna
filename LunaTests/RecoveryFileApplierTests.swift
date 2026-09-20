//
//  RecoveryFileApplierTests.swift
//  LunaTests
//

import LunaHTMLClassification
import LunaIngest
import LunaModels
@testable import LunaSaves
import LunaStorage
import XCTest

/// A replay witness that answers what the test wants and records the ask.
private final class StubRecipeReplay: RecoveryRecipeReplaying {
    let canReplay: Bool
    let succeeds: Bool
    private(set) var replayed: [URL] = []

    init(canReplay: Bool, succeeds: Bool) {
        self.canReplay = canReplay
        self.succeeds = succeeds
    }

    func replay(_ recipe: LunaRecoveryRecipe, pageURL: URL, itemID: UUID) async -> Bool {
        replayed.append(recipe.url)
        return succeeds
    }
}

private final class StubArticleAdopter: ArticleModelAdopting {
    var next: PluginAdoptedOutcome = .article(
        ArticleContent(title: "Recovered", blocks: [
            .init(kind: .paragraph, text: String(repeating: "word ", count: 60), links: []),
        ]), sourceHTML: "<p>x</p>")
    private(set) var adoptedURLs: [URL] = []

    func adopt(
        _ model: ArticleModel, url: URL, page: CapturedPage, pluginID: String
    ) async -> PluginAdoptedOutcome {
        adoptedURLs.append(url)
        return next
    }
}

private final class StubArticleHandler: IngestorArticleHandling {
    private(set) var persistedURLs: [URL] = []
    func persistArticle(
        _ content: ArticleContent, html: String, for item: SavedItem, url: URL, store: SavesStore
    ) async {
        persistedURLs.append(url)
        _ = store.saveContent(content, for: item)
    }
    func ingestDocument(_ item: SavedItem, store: SavesStore) async {}
    func backfillMissingWebArchives(store: SavesStore) {}
    func backfillMissingThumbnails(store: SavesStore) {}
    func preloadPasteboard(content: ArticleContent, sourceURL: URL) {}
    func doubleSaveDestinationIDs() -> [String] { [] }
    func sendToDestination(_ item: SavedItem, destinationID: String) async {}
    func isDestinationConfigured(_ destinationID: String) -> Bool { false }
}

/// What a recovery Luna file becomes (`claudedocs/luna-file.md`): the recipe
/// first, the content next, and the existing failed save either way.
@MainActor
final class RecoveryFileApplierTests: XCTestCase {

    private var directory: URL!
    private var store: SavesStore!
    private var ingestor: SavesIngestor!
    private var handoffs: LLMHandoffStore!
    private var recipes: PendingRecoveryRecipeStore!
    private var adopter: StubArticleAdopter!
    private var handler: StubArticleHandler!

    private var savedAdopters: (ArticleModelAdopting?, MediaModelAdopting?, ProductModelAdopting?)!
    private var savedArticleHandler: IngestorArticleHandling?
    private var savedReplay: (any RecoveryRecipeReplaying)!

    private let pageURL = URL(string: "https://example.com/story")!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SavesStore(containerURL: directory)
        ingestor = SavesIngestor(store: store)
        handoffs = LLMHandoffStore(containerURL: directory)
        recipes = PendingRecoveryRecipeStore(containerURL: directory)

        savedAdopters = (
            PluginModelAdopters.article, PluginModelAdopters.media, PluginModelAdopters.product)
        savedArticleHandler = IngestorKindHandlers.article
        savedReplay = RecoveryFileApplier.recipeReplay

        adopter = StubArticleAdopter()
        handler = StubArticleHandler()
        PluginModelAdopters.article = adopter
        PluginModelAdopters.media = nil
        PluginModelAdopters.product = nil
        IngestorKindHandlers.article = handler
        RecoveryFileApplier.recipeReplay = NoRecipeReplay()
    }

    override func tearDown() {
        PluginModelAdopters.article = savedAdopters.0
        PluginModelAdopters.media = savedAdopters.1
        PluginModelAdopters.product = savedAdopters.2
        IngestorKindHandlers.article = savedArticleHandler
        RecoveryFileApplier.recipeReplay = savedReplay
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeApplier() -> RecoveryFileApplier {
        RecoveryFileApplier(
            store: store, ingestor: ingestor, handoffs: handoffs, pendingRecipes: recipes)
    }

    /// Built by PARSING a real Luna file, because that is the only way a
    /// `PluginModel` is made: the Models decode, they have no memberwise init.
    private func file(
        url: URL? = nil, kind: PluginModelKind = .article, recipeURL: String? = nil
    ) -> LunaRecoveryFile {
        let page = (url ?? pageURL).absoluteString
        let content: String
        switch kind {
        case .article:
            content = #"{"kind":"article","title":"Recovered","html":"<p>body</p>"}"#
        case .media:
            content = #"{"kind":"media","title":"Clip","assets":[{"url":"https://cdn.test/v.mp4","type":"video"}]}"#
        case .product:
            content = #"{"kind":"product","name":"Widget","price":{"amount":"12.00","currency":"USD"}}"#
        }
        let recipe = recipeURL.map { #","recipe":{"url":"\#($0)"}"# } ?? ""
        let text = """
        /* luna-recovery
        {"api":1,"url":"\(page)","kind":"\(kind.rawValue)"}
        */
        {"content":\(content)\(recipe)}
        """
        guard case .success(.recovery(let file))? = LunaFileIntake.classify(text: text) else {
            fatalError("the fixture is not a valid recovery file")
        }
        return file
    }

    private static let recipeURL = "https://example.com/story?output=amp"

    private func failedItem(_ urlString: String? = nil) -> SavedItem {
        let item = store.add(urlString: urlString ?? pageURL.absoluteString)
        store.markFailed(item.id)
        return store.item(withID: item.id)!
    }

    // MARK: - Recipe first

    /// The recipe is a route Luna can take itself, so it is tried before the
    /// one answer the model already wrote down.
    func testAWorkingRecipeWinsAndTheContentIsNeverAdopted() async {
        let item = failedItem()
        let replay = StubRecipeReplay(canReplay: true, succeeds: true)
        RecoveryFileApplier.recipeReplay = replay

        let result = await makeApplier().apply(file(recipeURL: Self.recipeURL))

        XCTAssertEqual(result, .recovered(itemID: item.id))
        XCTAssertEqual(replay.replayed.map(\.absoluteString), ["https://example.com/story?output=amp"])
        XCTAssertTrue(adopter.adoptedURLs.isEmpty, "the content is the fallback, not the first try")
    }

    func testAFailedRecipeFallsBackToTheContent() async {
        let item = failedItem()
        RecoveryFileApplier.recipeReplay = StubRecipeReplay(canReplay: true, succeeds: false)

        let result = await makeApplier().apply(file(recipeURL: Self.recipeURL))

        XCTAssertEqual(result, .recovered(itemID: item.id))
        XCTAssertEqual(adopter.adoptedURLs, [pageURL])
        XCTAssertEqual(handler.persistedURLs, [pageURL])
    }

    func testAFileWithNoRecipeAdoptsItsContent() async {
        let item = failedItem()
        let result = await makeApplier().apply(file())

        XCTAssertEqual(result, .recovered(itemID: item.id))
        XCTAssertEqual(store.item(withID: item.id)?.state, .ready)
    }

    /// An extension links no rescue engine, so the recipe is kept for the app
    /// rather than dropped — and the content still recovers the save now.
    func testWithoutAnEngineTheRecipeIsKeptForTheApp() async {
        _ = failedItem()
        let result = await makeApplier().apply(file(recipeURL: Self.recipeURL))

        guard case .recovered = result else { return XCTFail("expected a recovered save") }
        XCTAssertEqual(
            recipes.peek().first?.recipeURLString, "https://example.com/story?output=amp")
    }

    // MARK: - Which save it lands on

    /// The failed card the user was looking at is the save that recovers, even
    /// when the model answers with the canonical form of its URL.
    func testTheExistingFailedSaveIsRecoveredEvenWithADifferingURLForm() async {
        let item = failedItem("https://example.com/story")
        let result = await makeApplier().apply(
            file(url: URL(string: "https://www.example.com/story/")!))

        XCTAssertEqual(result, .recovered(itemID: item.id))
        XCTAssertEqual(store.items().count, 1, "no second save for the same page")
    }

    /// A page Luna never saved arrives as a new save rather than as nothing.
    func testAFileForAnUnknownPageMakesANewSave() async {
        let result = await makeApplier().apply(file())

        guard case .recovered(let itemID) = result else { return XCTFail("expected a save") }
        XCTAssertNotNil(store.item(withID: itemID))
        XCTAssertEqual(store.item(withID: itemID)?.state, .ready)
    }

    /// A page Luna already holds keeps ONE row, whatever state it was in. The
    /// reservation is the same one a save press makes, so a recovery file can
    /// never leave a duplicate behind.
    func testAFileForAnAlreadySavedPageKeepsOneRow() async {
        let existing = store.add(urlString: pageURL.absoluteString)
        _ = store.saveContent(
            ArticleContent(title: "Already there", blocks: [
                .init(kind: .paragraph, text: "Body.", links: []),
            ]), for: existing)

        let result = await makeApplier().apply(file())

        XCTAssertEqual(result, .recovered(itemID: existing.id))
        XCTAssertEqual(store.items().count, 1)
    }

    /// An item parked in the interactive unlock tier is still a save waiting to
    /// be filled in, so a file for it recovers that one.
    func testANeedsCaptchaSaveIsRecovered() async {
        let item = store.add(urlString: pageURL.absoluteString)
        store.markNeedsCaptcha(item.id, title: "Locked")

        let result = await makeApplier().apply(file())
        XCTAssertEqual(result, .recovered(itemID: item.id))
    }

    // MARK: - Replacing a save that already worked

    /// A save can land READY with the wrong content, and the user hands it to
    /// a chat model from its own long-press menu. The file that comes back
    /// replaces the content on that very row (`claudedocs/llm-handoff.md`).
    func testAReadyArticleIsReplacedInPlace() async {
        let existing = store.add(urlString: pageURL.absoluteString)
        _ = store.saveContent(
            ArticleContent(title: "The teaser", blocks: [
                .init(kind: .paragraph, text: "Subscribe to read on.", links: []),
            ]), for: existing)
        handoffs.begin(
            .recovery(itemID: existing.id, urlString: pageURL.absoluteString), provider: .chatGPT)

        let result = await makeApplier().apply(file())

        XCTAssertEqual(result, .recovered(itemID: existing.id))
        XCTAssertEqual(store.items().count, 1)
        XCTAssertEqual(store.content(for: store.item(withID: existing.id)!)?.title, "Recovered")
    }

    /// Two rows can answer to one page: the ready save the user asked about and
    /// an older failed attempt at the same URL. The hand-off names which one.
    func testTheRecordedHandoffWinsOverASameURLFailedSave() async {
        let ready = store.add(urlString: "https://www.example.com/story/")
        _ = store.saveContent(
            ArticleContent(title: "The teaser", blocks: [
                .init(kind: .paragraph, text: "Subscribe to read on.", links: []),
            ]), for: ready)
        let failed = failedItem("https://example.com/story")
        handoffs.begin(
            .recovery(itemID: ready.id, urlString: "https://www.example.com/story/"),
            provider: .claude)

        let result = await makeApplier().apply(file())

        XCTAssertEqual(result, .recovered(itemID: ready.id))
        XCTAssertEqual(store.item(withID: failed.id)?.state, .failed, "the failed row is untouched")
    }

    // MARK: - The surface gate

    /// A Reader handed a product file stores nothing and says whose kind it is
    /// — the same answer a product LINK gets there.
    func testAForeignKindIsDroppedByTheSurfaceGate() async throws {
        try XCTSkipIf(
            SurfaceSupport.evaluateForCurrentProcess(owner: .priceTracker) == .supported,
            "this host app handles products")
        let result = await makeApplier().apply(file(kind: .product))
        XCTAssertEqual(result, .dropped(owner: .priceTracker))
        XCTAssertTrue(store.items().isEmpty)
    }

    // MARK: - Failure

    /// No adopter for the kind means no save, and a line the card can show.
    func testAKindWithNoAdopterFailsWithAReason() async {
        PluginModelAdopters.article = nil
        _ = failedItem()

        let applier = makeApplier()
        let result = await applier.apply(file())

        guard case .failed(let reason) = result else { return XCTFail("expected a failure") }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertEqual(applier.lastFailure(forURL: pageURL.absoluteString), reason)
    }

    // MARK: - The hand-off record

    /// The card stops saying "waiting" the moment the reply is applied.
    func testApplyingTheFileClearsTheHandoffRecord() async {
        let item = failedItem()
        handoffs.begin(
            .recovery(itemID: item.id, urlString: pageURL.absoluteString), provider: .claude)

        _ = await makeApplier().apply(file())
        XCTAssertNil(handoffs.record(forURL: pageURL.absoluteString))
    }
}
