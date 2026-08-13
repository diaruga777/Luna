//
//  LunaAppClipInvocationURLTests.swift
//  LunaTests
//

import LunaURLClassification
import XCTest

/// What each App Clip will accept as "the link I was launched for".
///
/// Both clips read a `url`/`source`/`sourceURL`/`u` query item first and take it
/// on sight. They differ on the two looser forms, and both differences are the
/// Downloader's: a fragment counts only on its own `/download` path, and the
/// invocation URL itself may not stand in as the source when it is a Luna host
/// (that is the invocation page, not something to download).
final class LunaAppClipInvocationURLTests: XCTestCase {

    private func source(
        _ urlString: String, for destination: LunaAppClipInvocationURL.Destination
    ) -> String? {
        LunaAppClipInvocationURL
            .sourceURL(from: URL(string: urlString)!, for: destination)?.absoluteString
    }

    // MARK: - Shared by both clips

    func testEveryQueryItemNameIsRead() {
        for name in ["url", "source", "sourceURL", "u"] {
            let invocation = "https://clip.luna.example/read?\(name)=https://news.example/story"
            XCTAssertEqual(source(invocation, for: .reader), "https://news.example/story")
            XCTAssertEqual(source(invocation, for: .downloader), "https://news.example/story")
        }
    }

    /// A query item that is not a web URL is not a source, and the looser forms
    /// still get their turn.
    func testANonWebQueryValueFallsThroughToTheOtherForms() {
        let invocation = "https://clip.example/read?url=ftp://files.example/x"
        XCTAssertEqual(source(invocation, for: .reader), "https://clip.example/read?url=ftp://files.example/x")
        XCTAssertEqual(
            source(invocation, for: .downloader),
            "https://clip.example/read?url=ftp://files.example/x")
    }

    func testANonWebInvocationURLHasNoSource() {
        XCTAssertNil(source("mailto:someone@example.com", for: .reader))
        XCTAssertNil(source("mailto:someone@example.com", for: .downloader))
    }

    // MARK: - The fragment

    func testTheReaderTakesAFragmentOnAnyPath() {
        XCTAssertEqual(
            source("https://clip.example/read#https%3A%2F%2Fnews.example%2Fstory", for: .reader),
            "https://news.example/story")
        XCTAssertEqual(
            source("https://clip.example/anything#https%3A%2F%2Fnews.example%2Fstory", for: .reader),
            "https://news.example/story")
    }

    func testTheDownloaderTakesAFragmentOnlyOnItsDownloadPath() {
        XCTAssertEqual(
            source(
                "https://clip.example/download#https%3A%2F%2Fvideos.example%2Fclip",
                for: .downloader),
            "https://videos.example/clip")
        // Off that path the fragment is ignored — and this invocation URL is a
        // web URL on a non-Luna host, so it stands in for itself, fragment and all.
        XCTAssertEqual(
            source(
                "https://clip.example/elsewhere#https%3A%2F%2Fvideos.example%2Fclip",
                for: .downloader),
            "https://clip.example/elsewhere#https%3A%2F%2Fvideos.example%2Fclip")
    }

    /// The path rule is about the fragment only: a Luna host's own `/download`
    /// invocation is exactly where a fragment is expected.
    func testTheDownloaderTakesAFragmentFromALunaHostsDownloadPath() {
        XCTAssertEqual(
            source(
                "https://luna.example/download#https%3A%2F%2Fvideos.example%2Fclip",
                for: .downloader),
            "https://videos.example/clip")
    }

    // MARK: - The invocation URL standing in for itself

    func testTheReaderReadsTheInvocationURLItselfWhateverItsHost() {
        XCTAssertEqual(
            source("https://news.example/story", for: .reader), "https://news.example/story")
        XCTAssertEqual(
            source("https://luna.example/story", for: .reader), "https://luna.example/story")
    }

    func testTheDownloaderRefusesToDownloadALunaHostsOwnPage() {
        XCTAssertEqual(
            source("https://videos.example/clip", for: .downloader), "https://videos.example/clip")
        XCTAssertNil(source("https://luna.example/clip", for: .downloader))
        XCTAssertNil(source("https://LUNA.example/clip", for: .downloader))
        XCTAssertNil(source("https://clip.getluna.app/x", for: .downloader))
    }
}
