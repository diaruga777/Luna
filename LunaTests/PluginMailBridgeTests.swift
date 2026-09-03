//
//  PluginMailBridgeTests.swift
//  LunaTests
//

import Foundation
import LunaMailAccount
import LunaModels
import LunaPluginExport
import LunaPluginKit
import LunaPluginRuntime
import XCTest

/// `luna.mail` and `luna.notifications` as a plugin sees them (§6.13, §6.14).
///
/// Each case drives the SHIPPED bridge from real plugin JavaScript on the
/// fixture runner, so the assertions are about what a plugin author gets.
final class PluginMailBridgeTests: XCTestCase {

    private var runner: PluginJSFixtureRunner!
    private var sender: RecordingPluginMailSender!
    private var scratch: PluginScratchStore!

    private static let pluginID = "test.luna.mailer"

    override func setUp() {
        super.setUp()
        runner = PluginJSFixtureRunner()
        sender = RecordingPluginMailSender()
        scratch = runner.scratch
    }

    override func tearDown() {
        runner.cleanUp()
        runner = nil
        sender = nil
        scratch = nil
        PluginMailRecipients.picker = nil
        PluginExportMailAccount.readinessOverride = nil
        super.tearDown()
    }

    private static func source(_ body: String, capabilities: String = "[\"mail\"]") -> String {
        """
        /* luna-plugin
        {
          "id": "\(pluginID)",
          "name": "Mailer",
          "version": "1.0.0",
          "api": 1,
          "capabilities": \(capabilities),
          "export": { "kinds": ["article"], "input": "url", "title": "Mail It" }
        }
        */
        luna.register({
            async export(input) {
                \(body)
            }
        });
        """
    }

    private func install(
        _ body: String, processKind: PluginProcessKind = .app,
        picker: (any PluginMailRecipientPicking)? = nil,
        capabilities: String = "[\"mail\"]"
    ) throws {
        runner.capabilities.register(PluginMailBridge(
            processKind: processKind, scheduler: runner.runtime, scratch: scratch,
            recipientPicker: picker, sender: sender))
        try runner.load(Self.source(body, capabilities: capabilities))
    }

    private struct Input: Encodable {
        let kind = "article"
        let saveId = UUID().uuidString
        let url = "https://example.com/a"
        let title = "An Article"
        let format = "url"
        let auto = false
    }

    // MARK: - Sending

    func testANamedRecipientReachesTheTransport() async throws {
        try install("""
            await luna.mail.send({
                to: ["reader@example.com"], subject: input.title, text: "Body" });
            return { status: "sent" };
            """)

        let result = await runner.invoke(
            .export, pluginID: Self.pluginID, argument: Input(), as: StatusAnswer.self)

        XCTAssertEqual(result?.status, "sent")
        XCTAssertEqual(sender.messages.count, 1)
        XCTAssertEqual(sender.messages.first?.recipients, ["reader@example.com"])
        XCTAssertEqual(sender.messages.first?.subject, "An Article")
        XCTAssertEqual(sender.messages.first?.text, "Body")
    }

    /// A message with no recipients asks the user. A cancel rejects with
    /// `cancelled`, so the plugin can stop rather than guess.
    func testAnOmittedRecipientListAsksAndACancelRejects() async throws {
        try install(
            """
            try {
                await luna.mail.send({ subject: "Anything", text: "Body" });
                return { status: "sent" };
            } catch (error) {
                return { status: "failed", message: error.code };
            }
            """,
            picker: CancellingRecipientPicker())

        let result = await runner.invoke(
            .export, pluginID: Self.pluginID, argument: Input(), as: StatusAnswer.self)

        XCTAssertEqual(result?.message, "cancelled")
        XCTAssertTrue(sender.messages.isEmpty, "a cancelled pick sends nothing")
    }

    /// The composition installs `PluginMailRecipients.picker` AFTER the
    /// platform install that builds this bridge, so a bridge that captured the
    /// value at `init` holds nil forever and every recipient-less message is
    /// refused. It must read the witness when the message needs it.
    func testTheInstalledPickerIsReadWhenTheMessageNeedsIt() async throws {
        try install(
            """
            await luna.mail.send({ subject: "Anything", text: "Body" });
            return { status: "sent" };
            """)
        // Assigned after the bridge exists, exactly as `KindWiring+Luna` does.
        PluginMailRecipients.picker = FixedRecipientPicker(["late@example.com"])

        let result = await runner.invoke(
            .export, pluginID: Self.pluginID, argument: Input(), as: StatusAnswer.self)

        XCTAssertEqual(result?.status, "sent")
        XCTAssertEqual(sender.messages.first?.recipients, ["late@example.com"])
    }

    func testAnOmittedRecipientListUsesWhatThePickerChose() async throws {
        try install(
            """
            await luna.mail.send({ subject: "Anything", text: "Body" });
            return { status: "sent" };
            """,
            picker: FixedRecipientPicker(["friend@example.com"]))

        let result = await runner.invoke(
            .export, pluginID: Self.pluginID, argument: Input(), as: StatusAnswer.self)

        XCTAssertEqual(result?.status, "sent")
        XCTAssertEqual(sender.messages.first?.recipients, ["friend@example.com"])
    }

    /// Email cannot leave a share or action extension: the transport lives in
    /// the app. The refusal carries `unavailable-here` rather than failing
    /// halfway through a send.
    func testSendingFromAnExtensionRefusesAsUnavailableHere() async throws {
        try install(
            """
            try {
                await luna.mail.send({ to: ["a@b.com"], subject: "S" });
                return { status: "sent" };
            } catch (error) {
                return { status: "failed", message: error.code };
            }
            """,
            processKind: .share)

        let result = await runner.invoke(
            .export, pluginID: Self.pluginID, argument: Input(), as: StatusAnswer.self)

        XCTAssertEqual(result?.message, "unavailable-here")
        XCTAssertTrue(sender.messages.isEmpty)
    }

    func testAnAttachmentComesOffDiskThroughItsHandle() async throws {
        try install("""
            await luna.mail.send({
                to: ["reader@example.com"],
                subject: input.title,
                attachments: [{ file: input.file, mime: "application/epub+zip" }] });
            return { status: "sent" };
            """)
        _ = scratch.openScratchGeneration(
            pluginID: Self.pluginID, generationID: "one")
        defer {
            scratch.closeScratchGeneration(
                pluginID: Self.pluginID, generationID: "one")
        }
        // Loading a plugin clears the generations a killed process left behind,
        // so the input file is written after the load, as the export stage does.
        let descriptor = try scratch.writeFile(
            Data("book-bytes".utf8), suggestedName: "Article.epub",
            mime: "application/epub+zip", pluginID: Self.pluginID,
            generation: "one")

        let result = await runner.invoke(
            .export, pluginID: Self.pluginID,
            argument: InputWithFile(file: PluginExportFileHandle(descriptor)),
            as: StatusAnswer.self)

        XCTAssertEqual(result?.status, "sent")
        let attachment = try XCTUnwrap(sender.messages.first?.attachments.first)
        XCTAssertEqual(attachment.name, "Article.epub")
        XCTAssertEqual(attachment.mime, "application/epub+zip")
        XCTAssertEqual(attachment.data, Data("book-bytes".utf8))
    }

    func testAMissingAttachmentFileRefuses() async throws {
        try install("""
            try {
                await luna.mail.send({
                    to: ["a@b.com"], subject: "S",
                    attachments: [{ file: { id: "nothing", name: "x.epub", size: 1 } }] });
                return { status: "sent" };
            } catch (error) {
                return { status: "failed", message: error.code };
            }
            """)

        let result = await runner.invoke(
            .export, pluginID: Self.pluginID, argument: Input(), as: StatusAnswer.self)

        XCTAssertEqual(result?.message, "not-found")
        XCTAssertTrue(sender.messages.isEmpty)
    }

    func testIsConfiguredFollowsTheConnectedAccount() async throws {
        try install("""
            return { status: "sent", message: String(await luna.mail.isConfigured()) };
            """)

        PluginExportMailAccount.readinessOverride = false
        let without = await runner.invoke(
            .export, pluginID: Self.pluginID, argument: Input(), as: StatusAnswer.self)
        PluginExportMailAccount.readinessOverride = true
        let with = await runner.invoke(
            .export, pluginID: Self.pluginID, argument: Input(), as: StatusAnswer.self)

        XCTAssertEqual(without?.message, "false")
        XCTAssertEqual(with?.message, "true")
    }

    // MARK: - MIME

    /// The message Luna builds carries the plugin's subject and body and the
    /// attachment as its own part. A plugin never writes a header.
    func testTheBuiltMIMECarriesTheBodyAndTheAttachment() throws {
        let mime = PluginMailMIME.build(
            PluginMailMessage(
                recipients: ["reader@example.com"], subject: "An Article",
                text: "Sent by Luna.", html: nil,
                attachments: [PluginMailAttachment(
                    name: "Article.epub", mime: "application/epub+zip",
                    data: Data("book".utf8))]),
            from: "me@example.com")
        let text = String(decoding: mime, as: UTF8.self)

        XCTAssertTrue(text.contains("From: <me@example.com>"), text)
        XCTAssertTrue(text.contains("To: reader@example.com"), text)
        XCTAssertTrue(text.contains("Subject: An Article"), text)
        XCTAssertTrue(text.contains("Content-Type: multipart/mixed"), text)
        XCTAssertTrue(
            text.contains("Content-Disposition: attachment; filename=\"Article.epub\""), text)
        XCTAssertTrue(
            text.contains(Data("book".utf8).base64EncodedString()),
            "the attachment's bytes ride the message")
    }

    func testAMessageWithNoAttachmentIsTheSharePlusHTMLShape() throws {
        let mime = PluginMailMIME.build(
            PluginMailMessage(
                recipients: ["reader@example.com"], subject: "Hello", text: "Plain <one>",
                html: nil, attachments: []),
            from: "me@example.com")
        let text = String(decoding: mime, as: UTF8.self)

        XCTAssertTrue(text.contains("multipart/related"), text)
        XCTAssertTrue(text.contains("multipart/alternative"), text)
        XCTAssertTrue(
            text.contains(EmailMIMEBase64.of("Plain <one>")),
            "the plain part carries the plugin's text")
        XCTAssertTrue(
            text.contains(EmailMIMEBase64.of("<html><body><p>Plain &lt;one&gt;</p></body></html>")),
            "the HTML part escapes it")
    }

    /// A message with both bodies keeps its plain-text alternative when a file
    /// rides along: the same message loses nothing merely because it gained an
    /// attachment.
    func testAMessageWithBothBodiesAndAnAttachmentNestsAnAlternative() throws {
        let mime = String(decoding: PluginMailMIME.build(
            PluginMailMessage(
                recipients: ["reader@example.com"], subject: "S", text: "Plain words",
                html: "<p>Rich words</p>",
                attachments: [PluginMailAttachment(
                    name: "Book.epub", mime: "application/epub+zip",
                    data: Data("bytes".utf8))]),
            from: "me@example.com"), as: UTF8.self)

        XCTAssertTrue(mime.contains("multipart/mixed"))
        XCTAssertTrue(mime.contains("multipart/alternative"))
        XCTAssertTrue(mime.contains(EmailMIMEBase64.of("Plain words")))
        XCTAssertTrue(mime.contains(EmailMIMEBase64.of("<p>Rich words</p>")))
    }

    /// The plugin chooses the attachment name, so a quote in it must not end
    /// the quoted parameter and let the rest of the name become headers.
    func testAQuoteInAnAttachmentNameCannotEscapeItsParameter() throws {
        let mime = String(decoding: PluginMailMIME.build(
            PluginMailMessage(
                recipients: ["reader@example.com"], subject: "S", text: "Body", html: nil,
                attachments: [PluginMailAttachment(
                    name: "a\"; x=\"b.epub", mime: "application/epub+zip",
                    data: Data("bytes".utf8))]),
            from: "me@example.com"), as: UTF8.self)

        XCTAssertFalse(mime.contains("; x=\"b.epub\""), mime)
        XCTAssertTrue(mime.contains("\\\""), "the quote is escaped rather than dropped")
    }

    // MARK: - Notifications (§6.14)

    /// The bridge can only ASK whether Luna is authorized. Nothing in the
    /// protocol requests authorization, and an unauthorized post answers
    /// `posted: false` instead of prompting.
    func testAnUnauthorizedNotificationAnswersPostedFalse() async throws {
        let center = RecordingNotificationCenter(authorized: false)
        runner.capabilities.register(PluginNotificationsBridge(
            processKind: .app, scheduler: runner.runtime, center: center))
        try runner.load(Self.source(
            """
            const answer = await luna.notifications.post({ title: "Done", body: "Sent" });
            return { status: "sent", message: String(answer.posted) };
            """,
            capabilities: "[\"notifications\"]"))

        let result = await runner.invoke(
            .export, pluginID: Self.pluginID, argument: Input(), as: StatusAnswer.self)

        XCTAssertEqual(result?.message, "false")
        XCTAssertTrue(center.posted.isEmpty)
        XCTAssertEqual(center.authorizationChecks, 1)
    }

    /// `clear()` with no identifier removes everything this plugin posted and
    /// nothing else — the prefix is the whole containment.
    func testClearWithoutAnIdentifierSweepsOnlyThisPluginsPrefix() async throws {
        let center = RecordingNotificationCenter(authorized: true)
        runner.capabilities.register(PluginNotificationsBridge(
            processKind: .app, scheduler: runner.runtime, center: center))
        try runner.load(Self.source(
            """
            await luna.notifications.clear();
            await luna.notifications.clear("mine");
            return { status: "sent" };
            """,
            capabilities: "[\"notifications\"]"))

        _ = await runner.invoke(
            .export, pluginID: Self.pluginID, argument: Input(), as: StatusAnswer.self)

        let prefix = PluginNotificationsBridge.identifierPrefix(Self.pluginID)
        XCTAssertEqual(center.clears.count, 2)
        XCTAssertNil(center.clears.first?.identifier, "no identifier means the whole prefix")
        XCTAssertEqual(center.clears.first?.prefix, prefix)
        XCTAssertEqual(center.clears.last?.identifier, prefix + "mine")
    }

    /// An authorized post lands, under an identifier namespaced by plugin, so
    /// one plugin can never clear another's notification.
    func testAnAuthorizedNotificationPostsUnderThePluginsOwnIdentifier() async throws {
        let center = RecordingNotificationCenter(authorized: true)
        runner.capabilities.register(PluginNotificationsBridge(
            processKind: .app, scheduler: runner.runtime, center: center))
        try runner.load(Self.source(
            """
            const answer = await luna.notifications.post({
                title: "Done", body: "Sent", identifier: "mine" });
            return { status: "sent", message: String(answer.posted) };
            """,
            capabilities: "[\"notifications\"]"))

        let result = await runner.invoke(
            .export, pluginID: Self.pluginID, argument: Input(), as: StatusAnswer.self)

        XCTAssertEqual(result?.message, "true")
        XCTAssertEqual(center.posted.map(\.title), ["Done"])
        XCTAssertEqual(
            center.posted.first?.identifier,
            PluginNotificationsBridge.identifierPrefix(Self.pluginID) + "mine")
    }
}

// MARK: - Doubles

private struct StatusAnswer: Decodable {
    let status: String
    let message: String?
}

private struct InputWithFile: Encodable {
    let kind = "article"
    let saveId = UUID().uuidString
    let url = "https://example.com/a"
    let title = "An Article"
    let format = "epub"
    let auto = false
    let file: PluginExportFileHandle
}

/// Records the messages the bridge asked to send.
private final class RecordingPluginMailSender: PluginMailSending, @unchecked Sendable {
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

private final class CancellingRecipientPicker: PluginMailRecipientPicking {
    @MainActor
    func pickMailRecipients(subject: String) async -> [String]? { nil }
}

private final class FixedRecipientPicker: PluginMailRecipientPicking {
    private let addresses: [String]
    init(_ addresses: [String]) { self.addresses = addresses }

    @MainActor
    func pickMailRecipients(subject: String) async -> [String]? { addresses }
}

/// A notification centre that can only be ASKED about authorization — the
/// shape that makes "never requests it" structural rather than remembered.
private final class RecordingNotificationCenter: PluginNotificationPosting, @unchecked Sendable {
    struct Posted: Equatable {
        let title: String
        let body: String?
        let identifier: String
        let deepLink: String?
    }

    private let authorized: Bool
    private let lock = NSLock()
    private var recorded: [Posted] = []
    private var checks = 0
    private(set) var clears: [(identifier: String?, prefix: String)] = []

    init(authorized: Bool) { self.authorized = authorized }

    var posted: [Posted] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var authorizationChecks: Int {
        lock.lock()
        defer { lock.unlock() }
        return checks
    }

    func isAuthorizedForPluginNotifications() async -> Bool {
        lock.lock()
        checks += 1
        lock.unlock()
        return authorized
    }

    func postPluginNotification(
        title: String, body: String?, identifier: String, deepLink: String?
    ) {
        lock.lock()
        recorded.append(Posted(
            title: title, body: body, identifier: identifier, deepLink: deepLink))
        lock.unlock()
    }

    func clearPluginNotifications(identifier: String?, prefix: String) {
        clears.append((identifier, prefix))
    }
}

/// The base64 an `EmailMIMEBuilder` part carries, for an assertion about the
/// body rather than the wrapping.
private enum EmailMIMEBase64 {
    static func of(_ text: String) -> String {
        Data(text.utf8).base64EncodedString(
            options: [.lineLength76Characters, .endLineWithCarriageReturn,
                      .endLineWithLineFeed])
    }
}
