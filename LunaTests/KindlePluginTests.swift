//
//  KindlePluginTests.swift
//  LunaTests
//

import Foundation
import LunaBundledPlugins
import LunaModels
import LunaPluginExport
import LunaPluginKit
import LunaPluginRuntime
import LunaPluginUI
import LunaSend
import XCTest

/// The bundled Kindle plugin (§9.5), run as the app runs it: the shipped
/// `kindle.js` on a real runtime, the shipped `luna.mail` bridge over a
/// recording sender.
///
/// Kindle parity (`claudedocs/send-to-kindle.md`) is what these assert: the
/// EPUB goes to the address the user typed, as an `application/epub+zip`
/// attachment, through the connected account.
final class KindlePluginTests: XCTestCase {

    private var runner: PluginJSFixtureRunner!
    private var sender: KindleRecordingSender!

    override func setUp() {
        super.setUp()
        runner = PluginJSFixtureRunner()
        sender = KindleRecordingSender()
    }

    override func tearDown() {
        runner?.scratch.closeScratchGeneration(
            pluginID: KindlePlugin.pluginID, generationID: "one")
        runner.cleanUp()
        runner = nil
        sender = nil
        super.tearDown()
    }

    /// The plugin's own source, read out of the bundle the app ships.
    private func kindleSource() throws -> String {
        let bundle = try XCTUnwrap(LunaBundledPluginsBundle.bundle)
        let url = try XCTUnwrap(
            bundle.url(forResource: "kindle", withExtension: "js", subdirectory: "Plugins")
                ?? bundle.url(forResource: "kindle", withExtension: "js"),
            "kindle.js is not in the bundled-plugins resource bundle")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func load(address: String?, senderNote: Bool? = nil) throws {
        runner.capabilities.register(PluginMailBridge(
            processKind: .app, scheduler: runner.runtime, scratch: runner.scratch,
            recipientPicker: nil, sender: sender))
        runner.capabilities.register(PluginSettingsBridge(
            processKind: .app, scheduler: runner.runtime))
        try runner.load(try kindleSource())
        _ = runner.scratch.openScratchGeneration(
            pluginID: KindlePlugin.pluginID, generationID: "one")
        if let address {
            try PluginPlatformServices.settings?.setValueJSON(
                "\"\(address)\"", pluginID: KindlePlugin.pluginID,
                key: KindlePlugin.addressSettingKey)
        }
        if let senderNote {
            try PluginPlatformServices.settings?.setValueJSON(
                senderNote ? "true" : "false", pluginID: KindlePlugin.pluginID,
                key: "senderNote")
        }
    }

    private func input(file: PluginFileDescriptor) -> KindleInput {
        KindleInput(
            saveId: UUID().uuidString, url: "https://example.com/article",
            title: "An Article", file: PluginExportFileHandle(file))
    }

    // MARK: - The hook

    func testTheEpubGoesToTheKindleAddressAsAnAttachment() async throws {
        let settings = FakePluginSettingsStore()
        let previous = PluginPlatformServices.settings
        PluginPlatformServices.settings = settings
        defer { PluginPlatformServices.settings = previous }
        try load(address: "reader@kindle.com")
        let epub = try runner.scratch.writeFile(
            Data("epub-bytes".utf8), suggestedName: "An Article.epub",
            mime: "application/epub+zip", pluginID: KindlePlugin.pluginID,
            generation: "one")

        let answer = await runner.invoke(
            .export, pluginID: KindlePlugin.pluginID, argument: input(file: epub),
            as: KindleAnswer.self)

        XCTAssertEqual(answer?.status, "sent")
        let message = try XCTUnwrap(sender.messages.first)
        XCTAssertEqual(message.recipients, ["reader@kindle.com"])
        XCTAssertEqual(message.subject, "An Article")
        XCTAssertEqual(message.attachments.first?.mime, "application/epub+zip")
        XCTAssertEqual(message.attachments.first?.name, "An Article.epub")
        XCTAssertEqual(message.attachments.first?.data, Data("epub-bytes".utf8))
        XCTAssertTrue(
            message.text?.contains("https://example.com/article") == true,
            "the note names the source: \(message.text ?? "nil")")
    }

    func testTheSenderNoteToggleRemovesTheBody() async throws {
        let settings = FakePluginSettingsStore()
        let previous = PluginPlatformServices.settings
        PluginPlatformServices.settings = settings
        defer { PluginPlatformServices.settings = previous }
        try load(address: "reader@kindle.com", senderNote: false)
        let epub = try runner.scratch.writeFile(
            Data("epub-bytes".utf8), suggestedName: "An Article.epub",
            mime: "application/epub+zip", pluginID: KindlePlugin.pluginID,
            generation: "one")

        _ = await runner.invoke(
            .export, pluginID: KindlePlugin.pluginID, argument: input(file: epub),
            as: KindleAnswer.self)

        XCTAssertEqual(sender.messages.first?.text ?? "", "")
    }

    /// No address is terminal: nothing about the article will change on a
    /// retry, and the `hard` code is what tells the coordinator so.
    func testNoAddressThrowsHard() async throws {
        let settings = FakePluginSettingsStore()
        let previous = PluginPlatformServices.settings
        PluginPlatformServices.settings = settings
        defer { PluginPlatformServices.settings = previous }
        try load(address: nil)
        let epub = try runner.scratch.writeFile(
            Data("epub-bytes".utf8), suggestedName: "An Article.epub",
            mime: "application/epub+zip", pluginID: KindlePlugin.pluginID,
            generation: "one")

        let failure = await runner.invokeExpectingFailure(
            .export, pluginID: KindlePlugin.pluginID, argument: input(file: epub),
            as: KindleAnswer.self)

        guard case .exception(let message, _)? = failure else {
            return XCTFail("a missing address throws: \(String(describing: failure))")
        }
        XCTAssertTrue(message.hasPrefix("hard:"), message)
        XCTAssertTrue(sender.messages.isEmpty)
        XCTAssertTrue(
            PluginExportStage.isTerminal(
                .exception(message: message, stack: nil)),
            "the stage reads that code as terminal")
    }

    // MARK: - Migration

    /// The address the Swift destination held moves into the plugin's setting
    /// once, and a later edit through the plugin is not overwritten by it.
    func testTheKindleAddressMigratesOnceAndIsNotOverwritten() throws {
        let settings = FakePluginSettingsStore()

        PluginExportComposition.migrateKindleAddress(
            settings: settings, legacyAddress: "reader@kindle.com")
        XCTAssertEqual(
            settings.valueJSON(
                pluginID: KindlePlugin.pluginID, key: KindlePlugin.addressSettingKey),
            "\"reader@kindle.com\"")

        settings.setString(
            "someone-else@kindle.com", pluginID: KindlePlugin.pluginID,
            key: KindlePlugin.addressSettingKey)
        PluginExportComposition.migrateKindleAddress(
            settings: settings, legacyAddress: "reader@kindle.com")

        XCTAssertEqual(
            settings.valueJSON(
                pluginID: KindlePlugin.pluginID, key: KindlePlugin.addressSettingKey),
            "\"someone-else@kindle.com\"",
            "the plugin's own setting is authoritative after the migration")
    }

    func testNoLegacyAddressWritesNothing() throws {
        let settings = FakePluginSettingsStore()

        PluginExportComposition.migrateKindleAddress(
            settings: settings, legacyAddress: "   ")

        XCTAssertNil(settings.valueJSON(
            pluginID: KindlePlugin.pluginID, key: KindlePlugin.addressSettingKey))
    }
}

// MARK: - Doubles

private struct KindleInput: Encodable {
    let kind = "article"
    let saveId: String
    let url: String
    let title: String
    let format = "epub"
    let auto = false
    let file: PluginExportFileHandle
}

private struct KindleAnswer: Decodable {
    let status: String
}

private final class KindleRecordingSender: PluginMailSending, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [PluginMailMessage] = []

    var messages: [PluginMailMessage] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func sendPluginMail(_ message: PluginMailMessage) async throws {
        lock.lock()
        recorded.append(message)
        lock.unlock()
    }
}
