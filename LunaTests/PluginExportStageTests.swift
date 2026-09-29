//
//  PluginExportStageTests.swift
//  LunaTests
//

import Foundation
import LunaModels
@testable import LunaPluginExport
import LunaPluginKit
import LunaSend
import LunaStorage
import XCTest

/// What the export stage DOES with a hook's answer (§9.2), what a share menu
/// offers (§9.3), and how a plugin destination's answer lands in the store
/// (§9.4).
@MainActor
final class PluginExportStageTests: XCTestCase {

    private var containerURL: URL!
    private var store: SavesStore!
    private var scratch: PluginScratchStore!
    private var invoker: ExportFakeInvoker!
    private var presenter: RecordingExportSharePresenter!
    private var settings: FakePluginSettingsStore!
    private var catalog: ExportFakeCatalog!

    private var previousSettings: (any PluginSettingsStoring)?
    private var previousCatalog: (any PluginCatalogProviding)?
    private var previousInvoker: (any PluginHookInvoking)?

    private static let pluginID = "test.luna.export"

    override func setUpWithError() throws {
        try super.setUpWithError()
        containerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin-export-stage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)
        store = SavesStore(containerURL: containerURL)
        scratch = PluginScratchStore(
            rootURL: containerURL.appendingPathComponent("scratch"))
        invoker = ExportFakeInvoker()
        presenter = RecordingExportSharePresenter()
        settings = FakePluginSettingsStore()
        catalog = ExportFakeCatalog()
        previousSettings = PluginPlatformServices.settings
        previousCatalog = PluginPlatformServices.catalog
        previousInvoker = PluginPlatformServices.invoker
        PluginPlatformServices.settings = settings
        PluginPlatformServices.catalog = catalog
    }

    override func tearDown() {
        PluginPlatformServices.settings = previousSettings
        PluginPlatformServices.catalog = previousCatalog
        PluginPlatformServices.invoker = previousInvoker
        PluginExportMailAccount.readinessOverride = nil
        try? FileManager.default.removeItem(at: containerURL)
        containerURL = nil
        store = nil
        scratch = nil
        invoker = nil
        presenter = nil
        settings = nil
        catalog = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func readyArticle() -> SavedItem {
        let item = store.add(urlString: "https://example.com/article")
        return store.saveContent(
            ArticleContent(
                title: "An Article",
                blocks: [ArticleContent.Block(kind: .paragraph, text: "Words.", links: [])]),
            for: item)
    }

    /// A ready MEDIA save: a recognized platform item, which is the shape
    /// `SavedItem.exportKind` reads.
    private func readyMedia() -> SavedItem {
        let item = store.add(urlString: "https://www.youtube.com/watch?v=abc")
        return store.savePlatformMetadata(
            platform: .youtube, platformItemID: "abc", title: "A Video",
            thumbnailFileName: nil, for: item.id) ?? item
    }

    private func stage(_ export: PluginExportSummary) -> PluginExportStage {
        invoker.plugins = [PluginExportFixtures.summary(id: Self.pluginID, export: export)]
        catalog.listingsByID[Self.pluginID] = PluginExportFixtures.listing(
            invoker.plugins[0])
        return PluginExportStage(
            invoker: invoker,
            producer: PluginExportInputProducer(store: store),
            scratch: scratch,
            presenter: presenter)
    }

    // MARK: - Sinks

    func testAUrlResultReachesTheShareSheet() async {
        let item = readyArticle()
        invoker.resultJSON = "{\"url\":\"https://example.com/exported\"}"
        let stage = stage(PluginExportFixtures.export(input: "url"))

        let outcome = await stage.run(pluginID: Self.pluginID, saveID: item.id)

        XCTAssertEqual(outcome, .presented)
        XCTAssertEqual(
            presenter.sharedURLs.map(\.absoluteString), ["https://example.com/exported"])
    }

    /// A text result becomes a FILE with the name the plugin asked for: the
    /// share sheet hands other apps a document, not a string.
    func testATextResultBecomesAFileNamedByThePlugin() async throws {
        let item = readyArticle()
        invoker.resultJSON =
            "{\"text\":\"# Words\",\"name\":\"Notes.md\",\"mime\":\"text/markdown\"}"
        let stage = stage(PluginExportFixtures.export(input: "markdown"))

        let outcome = await stage.run(pluginID: Self.pluginID, saveID: item.id)

        XCTAssertEqual(outcome, .presented)
        let url = try XCTUnwrap(presenter.sharedURLs.first)
        XCTAssertEqual(url.lastPathComponent, "Notes.md")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Words")
    }

    /// The handle a plugin returns outlives the hook that made it, and reaches
    /// the share sheet under its own name rather than the scratch file's, and
    /// the share's own directory goes when the sheet closes.
    func testAFileResultIsSharedUnderItsHandleName() async throws {
        let item = readyArticle()
        let generation = scratch.openScratchGeneration(pluginID: Self.pluginID)
        let descriptor = try scratch.writeFile(
            Data("book".utf8), suggestedName: "Article.epub",
            mime: "application/epub+zip", pluginID: Self.pluginID, generation: generation)
        invoker.resultJSON = """
            {"file":{"id":"\(descriptor.id)","name":"Article.epub","size":4,\
            "mime":"application/epub+zip"}}
            """
        let stage = stage(PluginExportFixtures.export(input: "epub"))

        let outcome = await stage.run(pluginID: Self.pluginID, saveID: item.id)

        XCTAssertEqual(outcome, .presented)
        let url = try XCTUnwrap(presenter.sharedURLs.first)
        XCTAssertEqual(url.lastPathComponent, "Article.epub")
        XCTAssertEqual(try Data(contentsOf: url), Data("book".utf8))

        presenter.finishShares()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "the share's own directory goes when the sheet closes")
        scratch.closeScratchGeneration(pluginID: Self.pluginID)
        XCTAssertNil(
            scratch.fileURL(for: descriptor),
            "the plugin's generation is reaped once nothing holds it")
    }

    func testANullResultPresentsNothing() async {
        let item = readyArticle()
        invoker.resultJSON = "null"
        let stage = stage(PluginExportFixtures.export(input: "url"))

        let outcome = await stage.run(pluginID: Self.pluginID, saveID: item.id)

        XCTAssertEqual(outcome, .handled)
        XCTAssertTrue(presenter.shares.isEmpty)
    }

    func testAStatusResultPresentsNothingAndReportsItsOwnAnswer() async {
        let item = readyArticle()
        invoker.resultJSON = "{\"status\":\"failed\",\"message\":\"no room\",\"hard\":true}"
        let stage = stage(PluginExportFixtures.export(input: "url"))

        let outcome = await stage.run(pluginID: Self.pluginID, saveID: item.id)

        XCTAssertEqual(outcome, .status(.failed, message: "no room", hard: true))
        XCTAssertTrue(presenter.shares.isEmpty)
    }

    /// The runtime drops a `LunaError`'s `details`, so the terminal signal a
    /// plugin has is the error CODE.
    func testAThrownHardCodeIsTerminalAndAnyOtherThrowIsNot() async {
        let item = readyArticle()
        let stage = stage(PluginExportFixtures.export(input: "url"))

        invoker.failure = .exception(message: "hard: no address is set", stack: nil)
        let terminal = await stage.run(pluginID: Self.pluginID, saveID: item.id)
        invoker.failure = .exception(message: "network: the server hung up", stack: nil)
        let transient = await stage.run(pluginID: Self.pluginID, saveID: item.id)

        XCTAssertEqual(terminal, .failed(message: "hard: no address is set", hard: true))
        XCTAssertEqual(
            transient, .failed(message: "network: the server hung up", hard: false))
    }

    func testAnUnknownPluginNeverCallsAHook() async {
        let item = readyArticle()
        _ = stage(PluginExportFixtures.export(input: "url"))
        let stage = PluginExportStage(
            invoker: invoker, producer: PluginExportInputProducer(store: store),
            scratch: scratch, presenter: presenter)

        let outcome = await stage.run(pluginID: "test.luna.absent", saveID: item.id)

        guard case .failed(_, let hard) = outcome else {
            return XCTFail("an absent plugin cannot export: \(outcome)")
        }
        XCTAssertTrue(hard)
        XCTAssertTrue(invoker.calls.isEmpty)
    }

    /// The stage builds the input the declaration asks for and hands it to the
    /// hook — the plugin never asks Luna for the save.
    func testTheHookIsHandedTheDeclaredInput() async throws {
        let item = readyArticle()
        let stage = stage(PluginExportFixtures.export(input: "markdown"))

        _ = await stage.run(pluginID: Self.pluginID, saveID: item.id, auto: true)

        let argument = try XCTUnwrap(invoker.argumentJSON.first)
        XCTAssertTrue(argument.contains("\"format\":\"markdown\""), argument)
        XCTAssertTrue(argument.contains("\"auto\":true"), argument)
        XCTAssertTrue(argument.contains("\"saveId\":\"\(item.id.uuidString)\""), argument)
    }

    // MARK: - Share rows (§9.3)

    func testRowsAppearOnlyForTheKindsAPluginExports() {
        let article = PluginExportFixtures.summary(
            id: "test.luna.article", export: PluginExportFixtures.export(
                kinds: [.article], title: "To Article Place"))
        let media = PluginExportFixtures.summary(
            id: "test.luna.media", export: PluginExportFixtures.export(
                kinds: [.media], input: "url", title: "To Media Place"))
        invoker.plugins = [article, media]
        catalog.listingsByID = [
            article.id: PluginExportFixtures.listing(article),
            media.id: PluginExportFixtures.listing(media),
        ]
        let provider = PluginExportRowProvider(invoker: invoker)

        let articleRows = provider.exportRows(forSaveID: UUID(), kind: .article)
        let mediaRows = provider.exportRows(forSaveID: UUID(), kind: .media)
        let productRows = provider.exportRows(forSaveID: UUID(), kind: .product)

        XCTAssertEqual(articleRows.map(\.title), ["To Article Place"])
        XCTAssertEqual(mediaRows.map(\.title), ["To Media Place"])
        XCTAssertTrue(productRows.isEmpty)
    }

    func testARowWaitsForItsRequiredSettings() {
        let plugin = PluginExportFixtures.summary(
            id: Self.pluginID, export: PluginExportFixtures.export(
                requiresSettings: ["token"]))
        invoker.plugins = [plugin]
        catalog.listingsByID[plugin.id] = PluginExportFixtures.listing(
            plugin, settings: [PluginSettingField(
                key: "token", type: .password, label: "Token", isRequired: true)])
        let provider = PluginExportRowProvider(invoker: invoker)

        XCTAssertTrue(provider.exportRows(forSaveID: UUID(), kind: .article).isEmpty)
        settings.setString("abc", pluginID: plugin.id, key: "token")
        XCTAssertEqual(
            provider.exportRows(forSaveID: UUID(), kind: .article).map(\.pluginID),
            [plugin.id])
    }

    /// A plugin that sends mail is no more configured than the account is —
    /// the rule `KindleSendSettings.isConfigured` already held.
    func testAMailSendingRowWaitsForAConnectedAccount() {
        let plugin = PluginExportFixtures.summary(
            id: Self.pluginID, export: PluginExportFixtures.export(isDestination: true))
        invoker.plugins = [plugin]
        catalog.listingsByID[plugin.id] = PluginExportFixtures.listing(
            plugin, capabilities: [.mail])
        let provider = PluginExportRowProvider(invoker: invoker)

        PluginExportMailAccount.readinessOverride = false
        XCTAssertTrue(provider.exportRows(forSaveID: UUID(), kind: .article).isEmpty)
        PluginExportMailAccount.readinessOverride = true
        XCTAssertEqual(provider.exportRows(forSaveID: UUID(), kind: .article).count, 1)
    }

    /// Only a destination that REPORTS its liveness draws a dot.
    func testTheStatusDotFollowsTheReservedStatusSetting() {
        let plugin = PluginExportFixtures.summary(
            id: Self.pluginID, export: PluginExportFixtures.export(isDestination: true))
        invoker.plugins = [plugin]
        catalog.listingsByID[plugin.id] = PluginExportFixtures.listing(plugin)
        let provider = PluginExportRowProvider(invoker: invoker)

        XCTAssertNil(provider.exportRows(forSaveID: UUID(), kind: .article).first?.isLive)
        settings.setString("off", pluginID: plugin.id, key: "_status")
        XCTAssertEqual(
            provider.exportRows(forSaveID: UUID(), kind: .article).first?.isLive, false)
        settings.setString("live", pluginID: plugin.id, key: "_status")
        XCTAssertEqual(
            provider.exportRows(forSaveID: UUID(), kind: .article).first?.isLive, true)
    }

    // MARK: - Destinations (§9.4)

    private func destination(
        _ export: PluginExportSummary, id: String = PluginExportStageTests.pluginID,
        mediaFiles: (any PluginExportMediaFileLocating)? = nil
    ) -> PluginDestination {
        invoker.plugins = [PluginExportFixtures.summary(id: id, export: export)]
        catalog.listingsByID[id] = PluginExportFixtures.listing(invoker.plugins[0])
        let stage = PluginExportStage(
            invoker: invoker,
            producer: PluginExportInputProducer(store: store, mediaFiles: mediaFiles),
            scratch: scratch, presenter: presenter)
        return PluginDestination(
            pluginID: id, export: export, stage: stage, mediaFiles: mediaFiles)
    }

    private func coordinator(_ destination: PluginDestination) -> ArticleSendCoordinator {
        ArticleSendCoordinator(
            store: store, destinations: [destination],
            retryPolicy: .init(maxSoftFailures: 3, initialDelay: 60, maxDelay: 300),
            now: { Date(timeIntervalSinceReferenceDate: 1_000) })
    }

    func testDestinationShareRowQueuesRetryAndRecordsSuccessfulDelivery() async {
        let item = readyArticle()
        let destination = destination(PluginExportFixtures.export(input: "url", isDestination: true))
        let provider = PluginExportRowProvider(
            invoker: invoker, store: store, coordinator: coordinator(destination))
        invoker.resultJSON = "{\"status\":\"retry\"}"
        provider.runExport(pluginID: Self.pluginID, saveID: item.id)
        for _ in 0..<100 {
            if store.item(withID: item.id)?.sendState(for: destination.id) == .queued { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.item(withID: item.id)?.sendState(for: destination.id), .queued)
        // Wait for the first invocation to settle before pressing again.
        try? await Task.sleep(nanoseconds: 50_000_000)
        invoker.resultJSON = "{\"status\":\"sent\"}"
        provider.runExport(pluginID: Self.pluginID, saveID: item.id)
        for _ in 0..<100 {
            if store.item(withID: item.id)?.sendState(for: destination.id) == .sent { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.item(withID: item.id)?.sendState(for: destination.id), .sent)
    }

    func testDestinationRegistryTracksImportsUpdatesAndDisablesWithoutRelaunch() {
        let old = ArticleDestinationRegistry.snapshot
        defer { ArticleDestinationRegistry.install(old.destinations, replacingBuiltInIDs: old.replacedIDs) }
        invoker.plugins = []
        PluginExportComposition.installDestinations(invoker: invoker)
        XCTAssertTrue(ArticleDestinationRegistry.installed.isEmpty)
        let export = PluginExportFixtures.export(input: "url", isDestination: true)
        invoker.plugins = [PluginExportFixtures.summary(id: Self.pluginID, export: export)]
        XCTAssertEqual(ArticleDestinationRegistry.installed.map(\.id), [PluginDestinationLegacyIDs.destinationID(forPluginID: Self.pluginID)])
        invoker.plugins = []
        XCTAssertTrue(ArticleDestinationRegistry.installed.isEmpty)
        XCTAssertEqual(ArticleDestinationRegistry.replacedBuiltInIDs, Set(["kindle", "xteink"]))
    }

    func testASentStatusMarksTheSendSent() async {
        let item = readyArticle()
        let destination = destination(
            PluginExportFixtures.export(input: "url", isDestination: true))
        invoker.resultJSON = "{\"status\":\"sent\"}"

        await coordinator(destination).send(item, toDestinationID: destination.id)

        XCTAssertEqual(store.item(withID: item.id)?.sendState(for: destination.id), .sent)
    }

    /// `null` from a destination means "I handled it", which is a send.
    func testANullAnswerFromADestinationCountsAsSent() async {
        let item = readyArticle()
        let destination = destination(
            PluginExportFixtures.export(input: "url", isDestination: true))
        invoker.resultJSON = "null"

        await coordinator(destination).send(item, toDestinationID: destination.id)

        XCTAssertEqual(store.item(withID: item.id)?.sendState(for: destination.id), .sent)
    }

    /// A `retry` is a DEFERRAL, the same answer the Swift Xteink destination
    /// gives when no rendezvous is open. It must cost nothing: a share-row tap
    /// on an enqueue-only destination is the normal case, and five of them
    /// would otherwise mark the send terminally failed.
    func testARetryStatusDefersTheSendAtNoRetryCost() async {
        let item = readyArticle()
        let destination = destination(
            PluginExportFixtures.export(input: "url", isDestination: true))
        invoker.resultJSON = "{\"status\":\"retry\",\"message\":\"not awake\"}"
        let coordinator = coordinator(destination)

        for _ in 0..<6 {
            await coordinator.send(item, toDestinationID: destination.id)
        }

        let fresh = store.item(withID: item.id)
        XCTAssertEqual(fresh?.sendState(for: destination.id), .queued)
        XCTAssertNil(fresh?.sendNextAttemptDates[destination.id], "a deferral schedules no backoff")
        XCTAssertNil(fresh?.sendFailureCounts[destination.id], "a deferral counts no failure")
        XCTAssertNil(fresh?.sendLastErrors[destination.id])
    }

    /// A `sent` answer's `remoteName` is the name the receiver filed the save
    /// under. Recording it is what later lets Luna ask the receiver to delete
    /// that exact file when the save is finished here.
    func testASentStatusRecordsTheRemoteNameItReported() async {
        let item = readyArticle()
        let destination = destination(
            PluginExportFixtures.export(input: "url", isDestination: true))
        invoker.resultJSON = "{\"status\":\"sent\",\"remoteName\":\"An-Article.epub\"}"

        await coordinator(destination).send(item, toDestinationID: destination.id)

        let fresh = store.item(withID: item.id)
        XCTAssertEqual(fresh?.remoteName(for: destination.id), "An-Article.epub")
        XCTAssertEqual(fresh?.remoteDeleteStatus(for: destination.id), .delivered)
    }

    /// Nothing presents while a queued send is delivered in the background, so
    /// a share-shaped answer reached nobody. Counting it delivered would leave
    /// the save `.sent` and unrecoverable.
    func testAShareShapedAnswerToAnAutomaticSendIsNotADelivery() async {
        let item = readyArticle()
        let destination = destination(
            PluginExportFixtures.export(input: "url", isDestination: true))
        invoker.resultJSON = "{\"url\":\"https://example.com/exported\"}"

        await coordinator(destination).send(item, toDestinationID: destination.id)

        XCTAssertEqual(store.item(withID: item.id)?.sendState(for: destination.id), .failed)
    }

    func testAHardFailureIsTerminalAndASoftOneIsNot() async {
        let soft = readyArticle()
        let destination = destination(
            PluginExportFixtures.export(input: "url", isDestination: true))
        let coordinator = coordinator(destination)

        invoker.resultJSON = "{\"status\":\"failed\",\"message\":\"hiccup\"}"
        await coordinator.send(soft, toDestinationID: destination.id)
        XCTAssertEqual(store.item(withID: soft.id)?.sendState(for: destination.id), .queued)

        let hard = store.saveContent(
            ArticleContent(
                title: "Second",
                blocks: [ArticleContent.Block(kind: .paragraph, text: "More.", links: [])]),
            for: store.add(urlString: "https://example.com/second"))
        invoker.resultJSON = "{\"status\":\"failed\",\"message\":\"rejected\",\"hard\":true}"
        await coordinator.send(hard, toDestinationID: destination.id)
        XCTAssertEqual(store.item(withID: hard.id)?.sendState(for: destination.id), .failed)
    }

    /// A destination plugin that replaces a Swift destination delivers under
    /// that destination's id, so every send state already in the store applies
    /// to it.
    func testTheKindlePluginKeepsTheKindleDestinationID() {
        XCTAssertEqual(
            PluginDestinationLegacyIDs.destinationID(forPluginID: KindlePlugin.pluginID),
            ArticleDestinationID.kindle)
        XCTAssertEqual(
            PluginDestinationLegacyIDs.destinationID(forPluginID: "test.luna.other"),
            "test.luna.other")
    }

    /// The share menu draws its own row per configured destination, and a
    /// plugin destination is left out of that list — its row comes from its
    /// declaration instead, so the menu cannot offer it twice.
    func testAPluginDestinationIsNotAlsoADescriptorRow() {
        let destination = destination(
            PluginExportFixtures.export(input: "url", isDestination: true))
        let coordinator = coordinator(destination)

        XCTAssertTrue(destination.isConfigured)
        XCTAssertTrue(coordinator.configuredDestinations().isEmpty)
        XCTAssertTrue(coordinator.isConfigured(destinationID: destination.id))
    }

    /// A destination declaring `media` delivers a media save: the coordinator
    /// hands it over (an article destination's guard would have refused it) and
    /// the hook is handed the downloaded FILE, which is a media export's only
    /// input.
    func testAMediaDestinationDeliversTheDownloadedFile() async throws {
        let item = readyMedia()
        let downloaded = containerURL.appendingPathComponent("A Video.mp4")
        try Data("movie-bytes".utf8).write(to: downloaded)
        let destination = destination(
            PluginExportFixtures.export(
                kinds: [.media], input: "file", isDestination: true),
            mediaFiles: FixedMediaFileLocator(url: downloaded))
        invoker.resultJSON = "{\"status\":\"sent\"}"

        XCTAssertTrue(destination.accepts(item))
        await coordinator(destination).send(item, toDestinationID: destination.id)

        XCTAssertEqual(store.item(withID: item.id)?.sendState(for: destination.id), .sent)
        let argument = try XCTUnwrap(invoker.argumentJSON.first)
        XCTAssertTrue(argument.contains("\"format\":\"file\""), argument)
        XCTAssertTrue(argument.contains("\"kind\":\"media\""), argument)
        XCTAssertTrue(argument.contains("\"name\":\"A Video.mp4\""), argument)
        XCTAssertTrue(
            argument.contains("\"size\":\(Data("movie-bytes".utf8).count)"), argument)
    }

    /// A media save's row is ready from its post metadata alone, so a `file`
    /// destination must refuse it until the bytes are there — otherwise the
    /// lifecycle sweep queues a save whose input cannot be built and spends the
    /// whole retry budget on it.
    func testAFileDestinationRefusesAMediaSaveWhoseDownloadHasNotLanded() {
        let item = readyMedia()
        let destination = destination(
            PluginExportFixtures.export(
                kinds: [.media], input: "file", isDestination: true),
            mediaFiles: FixedMediaFileLocator(
                url: containerURL.appendingPathComponent("absent.mp4")))

        XCTAssertEqual(item.state, .ready)
        XCTAssertFalse(destination.accepts(item))
    }

    /// The kinds a destination declared are the kinds it is offered. An article
    /// destination beside the media one never sees the download.
    func testADestinationRefusesASaveOfAKindItDidNotDeclare() throws {
        let downloaded = containerURL.appendingPathComponent("Declared.mp4")
        try Data("movie-bytes".utf8).write(to: downloaded)
        let media = destination(
            PluginExportFixtures.export(
                kinds: [.media], input: "file", isDestination: true),
            mediaFiles: FixedMediaFileLocator(url: downloaded))
        let article = destination(
            PluginExportFixtures.export(input: "url", isDestination: true),
            id: "test.luna.article")

        XCTAssertTrue(media.accepts(readyMedia()))
        XCTAssertFalse(media.accepts(readyArticle()))
        XCTAssertFalse(article.accepts(readyMedia()))
        XCTAssertTrue(article.accepts(readyArticle()))
    }
}

/// Where a media save's downloaded file is, for a test that has put one there.
private final class FixedMediaFileLocator: PluginExportMediaFileLocating {
    let url: URL
    init(url: URL) { self.url = url }
    func mediaFileURL(forSaveID saveID: UUID) -> URL? { url }
}
