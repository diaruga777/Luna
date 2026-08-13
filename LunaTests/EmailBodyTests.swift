//
//  EmailBodyTests.swift
//  LunaTests
//

import XCTest
import LunaMailTransport
import LunaModels
@testable import LunaMailAccount

final class EmailBodyTests: XCTestCase {

    func testSubjectFormatting() {
        XCTAssertEqual(
            EmailContentRenderer.subject(title: "Hello", url: "https://x.com"),
            "\(FilterGuide.subjectPrefix)Hello")
        XCTAssertEqual(
            EmailContentRenderer.subject(title: "  ", url: "https://x.com"),
            "\(FilterGuide.subjectPrefix)https://x.com")
        XCTAssertEqual(
            EmailContentRenderer.subject(title: nil, url: "https://x.com"),
            "\(FilterGuide.subjectPrefix)https://x.com")
    }

    func testArticleRenderCarriesMarkerAndImages() {
        let blocks = [
            ArticleContent.Block(kind: .paragraph, text: "Hello world", links: []),
            ArticleContent.Block(kind: .image, text: "", links: [],
                                 imageFileName: "pic.jpg"),
            ArticleContent.Block(kind: .heading, text: "A <b> heading", links: []),
        ]
        let content = ArticleContent(title: "My Article", author: "Jane", blocks: blocks)
        let marker = LunaShareMarker(
            url: "https://ex.com/a", title: "My Article", kind: "article", sender: "Bob")

        let body = EmailContentRenderer.renderArticle(
            content, originalURL: "https://ex.com/a", marker: marker)

        XCTAssertEqual(body.subject, "\(FilterGuide.subjectPrefix)My Article")
        XCTAssertTrue(body.html.contains("My Article"))
        XCTAssertTrue(body.html.contains("https://ex.com/a"))
        XCTAssertTrue(body.html.contains("Jane"))
        // HTML is escaped.
        XCTAssertTrue(body.html.contains("A &lt;b&gt; heading"))
        // Image block became a CID ref.
        XCTAssertEqual(body.imageRefs, [EmailImageRef(contentID: "img-0", imageFileName: "pic.jpg")])
        XCTAssertTrue(body.html.contains("cid:img-0"))
        // Marker recoverable from the hidden body block.
        XCTAssertEqual(LunaShareMarker.from(htmlBody: body.html), marker)
        // Plain-text alternative present.
        XCTAssertTrue(body.plain.contains("Hello world"))
    }

    func testInlineLinkAnchoring() {
        // "Read more" — link over "more" (UTF-16 offset 5, length 4).
        let block = ArticleContent.Block(
            kind: .paragraph, text: "Read more here", links: [
                .init(start: 5, length: 4, urlString: "https://l.com")
            ])
        let html = EmailContentRenderer.inlineHTML(block)
        XCTAssertTrue(html.contains("<a href=\"https://l.com\""))
        XCTAssertTrue(html.contains(">more</a>"))
        XCTAssertTrue(html.hasPrefix("Read "))
        XCTAssertTrue(html.hasSuffix(" here"))
    }

    func testCardRender() {
        let marker = LunaShareMarker(url: "https://v.com/x", title: "Vid", kind: "video")
        let body = EmailContentRenderer.renderCard(
            title: "Vid", originalURL: "https://v.com/x", marker: marker,
            heroImageCID: "hero", detailLines: ["A great clip"])
        XCTAssertTrue(body.html.contains("cid:hero"))
        XCTAssertTrue(body.html.contains("A great clip"))
        XCTAssertEqual(LunaShareMarker.from(htmlBody: body.html), marker)
    }

    func testMIMEBuilderStructure() throws {
        let marker = LunaShareMarker(url: "https://ex.com/a", title: "T", kind: "article")
        let subject = "\(FilterGuide.subjectPrefix)T"
        let raw = EmailMIMEBuilder.build(
            from: "\"Me\" <me@ex.com>", to: ["you@ex.com"], subject: subject,
            plainBody: "plain text", htmlBody: "<html><body>hi</body></html>",
            inlineImages: [InlineImage(contentID: "img-0", mimeType: "image/jpeg",
                                       data: Data([0xFF, 0xD8, 0xFF]))],
            headers: [LunaShareMarker.headerName: marker.headerValue()])
        let text = String(decoding: raw, as: UTF8.self)

        XCTAssertTrue(text.contains("Subject: \(MIMEHeaderEncoding.encodedHeaderText(subject))"))
        XCTAssertTrue(text.contains("To: you@ex.com"))
        XCTAssertTrue(text.contains("multipart/related"))
        XCTAssertTrue(text.contains("multipart/alternative"))
        XCTAssertTrue(text.contains("text/plain; charset=utf-8"))
        XCTAssertTrue(text.contains("text/html; charset=utf-8"))
        XCTAssertTrue(text.contains("Content-ID: <img-0>"))

        // The marker survives the trip the RECEIVER makes. Its base64 payload is
        // 88 characters — past `MIMEHeaderEncoding.maxLineLength`, so the builder
        // folds it onto a continuation line and no single line of the raw message
        // carries the whole value. Reading it back therefore has to unfold, which
        // is exactly what the IMAP reader does before handing the value to
        // `LunaShareMarker`; asserting on one raw line instead would only pin the
        // send side to a folding threshold it is free to change.
        let headers = GmailIMAPClient.parseHeaders(GmailIMAPClient.splitMessage(text).headers)
        let value = try XCTUnwrap(headers[LunaShareMarker.headerName.lowercased()])
        XCTAssertEqual(LunaShareMarker.from(headerValue: value), marker)
    }
}
