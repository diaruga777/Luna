//
//  ShareAttachmentRouterTests.swift
//  LunaTests
//

import LunaShareSurface
import LunaURLClassification
import UniformTypeIdentifiers
import XCTest

/// Locks in which incoming attachment the share/action extensions consume, for the
/// provider shapes real hosts deliver. The live share sheet has no test seam, so
/// this asserts the pure `ShareAttachmentRouter` the extension surface routes
/// through — including the regression that motivated it: a host that registers ONE
/// provider for both the link and a plain-text rendering of it (the YouTube share
/// sheet) must still be read as a LINK, not imported as a text document.
final class ShareAttachmentRouterTests: XCTestCase {

    // MARK: - Web links

    func testSafariSharesTwoURLProvidersAndTakesTheFirst() {
        XCTAssertEqual(
            ShareAttachmentRouter.route(providerTypes: [["public.url"], ["public.url"]]),
            .webURL(index: 0))
    }

    /// The reported bug: a YouTube link shared from the YouTube app arrives as ONE
    /// provider advertising the URL *and* a plain-text rendering of it. Treating
    /// that as a text document saved the video as a `.txt` file, which Luna
    /// Downloader then dropped as Reader-owned ("it belongs in Luna Reader") and
    /// Luna / Luna Reader stored as an unreadable document.
    func testLinkThatAlsoAdvertisesPlainTextRoutesAsWebURL() {
        XCTAssertEqual(
            ShareAttachmentRouter.route(
                providerTypes: [["public.url", "public.plain-text"]]),
            .webURL(index: 0))
    }

    func testLinkThatAlsoAdvertisesRichTextRoutesAsWebURL() {
        XCTAssertEqual(
            ShareAttachmentRouter.route(
                providerTypes: [["public.url", "public.utf8-plain-text", "public.text"]]),
            .webURL(index: 0))
    }

    /// A link provider is preferred over a separate text provider for the same
    /// share, whatever order the host delivered them in.
    func testSeparateTextProviderNeverWinsOverALink() {
        XCTAssertEqual(
            ShareAttachmentRouter.route(providerTypes: [["public.plain-text"], ["public.url"]]),
            .webURL(index: 1))
    }

    // MARK: - The link inside a shared text payload

    /// The YouTube share sheet's caption shape: title line, then the link.
    func testCaptionedLinkIsExtractedFromASharedTextPayload() {
        let text = "Avatars Secret Animation Rule\n"
            + "https://youtube.com/shorts/ykm6sGvdUZw?si=APh3fVvqMJfqQNPP"
        XCTAssertNil(ShareTextURL.extract(from: text), "prose before the link fails the strict rule")
        XCTAssertEqual(
            ShareTextURL.firstLink(in: text)?.absoluteString,
            "https://youtube.com/shorts/ykm6sGvdUZw?si=APh3fVvqMJfqQNPP")
    }

    func testSentenceWrappedLinkIsExtracted() {
        XCTAssertEqual(
            ShareTextURL.firstLink(
                in: "Watch “Some Video” on YouTube: https://youtu.be/ykm6sGvdUZw please")?
                .absoluteString,
            "https://youtu.be/ykm6sGvdUZw")
    }

    /// A whole document's worth of prose around a link is a genuine text share and
    /// keeps its document import.
    func testLinkBuriedInLongProseIsNotTheShare() {
        let prose = String(repeating: "This is a shared note about many things. ", count: 12)
        XCTAssertNil(ShareTextURL.firstLink(in: prose + "https://example.com/article"))
    }

    func testTextWithNoLinkHasNoFirstLink() {
        XCTAssertNil(ShareTextURL.firstLink(in: "Just some shared thoughts, no links."))
    }

    // MARK: - The whole text leg against a real provider

    /// End-to-end over the pieces `handleText` chains, driven by a REAL
    /// `NSItemProvider` in the shape a text-only host delivers: route → the
    /// identifier the payload is loaded with → the value's string → the link. Only
    /// the UIKit presentation is left out.
    func testTextOnlyProviderYieldsItsLinkThroughTheWholeTextLeg() async throws {
        let shared = "Avatars Secret Animation Rule\nhttps://youtu.be/ykm6sGvdUZw"
        let provider = NSItemProvider(
            item: NSString(string: shared), typeIdentifier: UTType.plainText.identifier)

        XCTAssertEqual(
            ShareAttachmentRouter.route(providerTypes: [provider.registeredTypeIdentifiers]),
            .text(index: 0))

        let identifier = ShareAttachmentRouter.textTypeIdentifier(
            among: provider.registeredTypeIdentifiers)
        XCTAssertEqual(identifier, UTType.plainText.identifier)

        let value: NSSecureCoding? = try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: identifier) { value, error in
                if let error { continuation.resume(throwing: error) } else {
                    continuation.resume(returning: value)
                }
            }
        }
        let text = (value as? String)
            ?? (value as? NSString) as String?
            ?? (value as? NSAttributedString)?.string
            ?? (value as? Data).flatMap { String(data: $0, encoding: .utf8) }
        XCTAssertEqual(text, shared)
        XCTAssertEqual(
            text.flatMap { ShareTextURL.firstLink(in: $0) }?.absoluteString,
            "https://youtu.be/ykm6sGvdUZw")
    }

    // MARK: - Files

    /// A shared FILE advertises its file URL; it must import as a document, not be
    /// grabbed by the URL branch (which would see a non-http `file://` URL).
    func testSharedPDFRoutesAsDocument() {
        XCTAssertEqual(
            ShareAttachmentRouter.route(providerTypes: [["public.file-url", "com.adobe.pdf"]]),
            .document(index: 0, type: .pdf))
    }

    func testSharedTextFileRoutesAsDocument() {
        XCTAssertEqual(
            ShareAttachmentRouter.route(
                providerTypes: [["public.file-url", "public.plain-text"]]),
            .document(index: 0, type: .plainText))
    }

    /// A file URL with no recognized content type still goes down the URL leg,
    /// whose `isFileURL` branch imports it as a document.
    func testBareFileURLRoutesAsWebURLForTheFileLeg() {
        XCTAssertEqual(
            ShareAttachmentRouter.route(providerTypes: [["public.file-url"]]),
            .webURL(index: 0))
    }

    // MARK: - Text and nothing

    /// The live YouTube-share shape: the link arrives as an in-memory TEXT payload
    /// with no `public.url` at all. It must route to `.text` (where the link inside
    /// wins), NOT to a document import — that import is what saved the video as
    /// `lunadoc://…` titled "text".
    func testInMemoryPlainTextRoutesAsTextNotADocument() {
        XCTAssertEqual(
            ShareAttachmentRouter.route(providerTypes: [["public.plain-text"]]),
            .text(index: 0))
    }

    func testInMemoryUTF8TextRoutesAsText() {
        XCTAssertEqual(
            ShareAttachmentRouter.route(
                providerTypes: [["public.utf8-plain-text", "public.text"]]),
            .text(index: 0))
    }

    /// Rich text keeps its document import — formatting a link extraction would
    /// throw away.
    func testInMemoryRichTextStaysADocument() {
        XCTAssertEqual(
            ShareAttachmentRouter.route(providerTypes: [["public.rtf"]]),
            .document(index: 0, type: .rtf))
    }

    /// An in-memory PDF (data, no file URL) is still a document.
    func testInMemoryPDFStaysADocument() {
        XCTAssertEqual(
            ShareAttachmentRouter.route(providerTypes: [["com.adobe.pdf"]]),
            .document(index: 0, type: .pdf))
    }

    func testUnreadableShareIsUnsupported() {
        XCTAssertEqual(
            ShareAttachmentRouter.route(providerTypes: [["public.png"], []]),
            .unsupported)
    }

    func testNoAttachmentsIsUnsupported() {
        XCTAssertEqual(ShareAttachmentRouter.route(providerTypes: []), .unsupported)
    }
}
