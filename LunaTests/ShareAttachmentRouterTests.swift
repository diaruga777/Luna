//
//  ShareAttachmentRouterTests.swift
//  LunaTests
//

import LunaShareSurface
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

    func testTextOnlyShareRoutesToADocumentImportOfThatText() {
        XCTAssertEqual(
            ShareAttachmentRouter.route(providerTypes: [["public.plain-text"]]),
            .document(index: 0, type: .plainText))
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
