//
//  XPostExtractorTests.swift
//  LunaTests
//

import XCTest
import LunaModels
@testable import LunaArticleIngest

/// Loads the recorded fxtwitter payloads in `Fixtures/XPosts`. They are real
/// responses, trimmed to the fields the extractor reads, so these tests exercise
/// the true wire shape with no network.
enum XPostFixtures {
    static func payload(
        _ name: String, file: StaticString = #filePath, line: UInt = #line
    ) -> XPostPayload {
        let url = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/XPosts")
            .appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else {
            XCTFail("missing fixture \(name) at \(url.path)", file: file, line: line)
            return XPostPayload()
        }
        do {
            return try JSONDecoder().decode(XPostPayload.self, from: data)
        } catch {
            XCTFail("undecodable fixture \(name): \(error)", file: file, line: line)
            return XPostPayload()
        }
    }
}

final class XPostExtractorTests: XCTestCase {
    private let postURL = URL(string: "https://x.com/random_walker/status/2082163285588107752")!

    private func article(_ fixture: String) -> ArticleContent? {
        XPostExtractor.article(from: XPostFixtures.payload(fixture), url: postURL)
    }

    // MARK: - The length gate

    /// Every payload the extractor must DECLINE — the pipeline is told nil so the
    /// save stays a social item rather than becoming reader content.
    func testDeclinedPayloads() {
        let cases: [(name: String, payload: XPostPayload)] = [
            // A short standalone post is not reader content.
            ("standalone short post", XPostFixtures.payload("standalone-short.json")),
            // A two-post aside totalling 536 characters is still not an article.
            // This is the case that pins the threshold: above one tweet, below reading.
            ("short two-post thread", XPostFixtures.payload("thread-two-posts-short.json")),
            // `is_note_tweet` is decoded but must NOT be the gate — X sets it on posts
            // at the 280-character ordinary limit, so it cannot separate an essay from
            // a quip. A declined post can still carry the flag.
            ("note-tweet flag on a short post", XPostPayload(
                thread: [XPostPayload.Post(
                    id: "1", text: "Short but composed in the note editor.",
                    author: .init(screen_name: "a", id: "1"), is_note_tweet: true)],
                author: .init(screen_name: "a", id: "1"))),
            // A post shared BECAUSE it holds a video stays media — converting it
            // would strip the download the save was for.
            ("long post whose named status carries a video",
             XPostFixtures.payload("video-post.json")),
            // Nothing in it yields nothing, rather than an empty article.
            ("empty payload", XPostPayload()),
        ]

        for testCase in cases {
            XCTAssertNil(
                XPostExtractor.article(from: testCase.payload, url: postURL), testCase.name)
        }
    }

    /// A genuine long-form single post is accepted, with its author attached.
    func testLongNoteTweetBecomesAnArticle() {
        let content = article("note-tweet-long.json")
        XCTAssertNotNil(content)
        XCTAssertGreaterThanOrEqual(
            content?.bodyTextLength ?? 0, XPostExtractor.minimumBodyTextLength)
        XCTAssertEqual(content?.author, "Arvind Narayanan (@random_walker)")
        XCTAssertFalse(content?.title.isEmpty ?? true)
    }

    // MARK: - X Articles (the long-form editor)

    /// An X Article is long-form by construction: it keeps its OWN title and is
    /// accepted without consulting the length threshold.
    func testXArticleUsesItsOwnTitleAndSkipsTheThreshold() {
        let content = article("x-article.json")
        XCTAssertEqual(content?.title, "What's gone wrong with AI & labor — a thought experiment")
        XCTAssertEqual(content?.author, "Arvind Narayanan (@random_walker)")
        XCTAssertEqual(content?.blocks.count, 9)
    }

    /// Draft.js `entityRanges` become inline links over the right words — the
    /// offsets are UTF-16 code units in both formats, so they transfer directly.
    func testXArticleEntityRangesBecomeInlineLinks() throws {
        let content = try XCTUnwrap(article("x-article.json"))
        let links = content.blocks.flatMap(\.links)
        XCTAssertEqual(links.count, 3)

        // Each link must cover real text in its own block, not run past the end.
        for block in content.blocks {
            let length = (block.text as NSString).length
            for link in block.links {
                XCTAssertGreaterThanOrEqual(link.start, 0)
                XCTAssertLessThanOrEqual(link.start + link.length, length)
            }
        }
        XCTAssertTrue(links.contains {
            $0.urlString == "https://simonwillison.net/2025/Jul/3/table-saws/"
        })

        // The anchor text is the linked phrase, not an offset-shifted neighbour.
        let anchored = content.blocks.first { !$0.links.isEmpty }
        let first = try XCTUnwrap(anchored?.links.first)
        let label = (anchored!.text as NSString)
            .substring(with: NSRange(location: first.start, length: first.length))
        XCTAssertEqual(label, "bunk")
    }

    /// Draft block types map onto the reader's own block kinds.
    func testDraftBlockTypesMapToReaderKinds() {
        let payload = XPostPayload(
            thread: [XPostPayload.Post(
                id: "1", author: .init(screen_name: "a", id: "1"),
                article: .init(title: "T", content: .init(blocks: [
                    .init(type: "header-two", text: "A heading"),
                    .init(type: "blockquote", text: "A quote"),
                    .init(type: "unordered-list-item", text: "An item"),
                    .init(type: "unstyled", text: "A paragraph"),
                    .init(type: "code-block", text: "let x = 1"),
                ])))],
            author: .init(screen_name: "a", id: "1"))
        let content = XPostExtractor.article(from: payload, url: postURL)
        XCTAssertEqual(
            content?.blocks.map(\.kind),
            [.heading, .quote, .listItem, .paragraph, .paragraph])
    }

    /// An entity range that would land outside the trimmed text is dropped rather
    /// than clamped: a wrong range would mislink visible words.
    func testOutOfRangeDraftEntityIsDropped() {
        let payload = XPostPayload(
            thread: [XPostPayload.Post(
                id: "1", author: .init(screen_name: "a", id: "1"),
                article: .init(title: "T", content: .init(
                    blocks: [.init(
                        type: "unstyled", text: "Short text",
                        entityRanges: [.init(offset: 400, length: 9, key: 0)])],
                    entityMap: [.init(key: "0", value: .init(
                        type: "LINK", data: .init(url: "https://example.com")))])))],
            author: .init(screen_name: "a", id: "1"))
        let content = XPostExtractor.article(from: payload, url: postURL)
        XCTAssertEqual(content?.blocks.first?.links.count, 0)
    }

    // MARK: - Threads

    /// A chained self-thread is assembled into ONE article across all its posts.
    func testSelfThreadIsAssembledIntoOneArticle() throws {
        let content = try XCTUnwrap(article("thread-six-posts.json"))
        // All six posts contribute, so the body far exceeds any single post.
        XCTAssertGreaterThan(content.bodyTextLength, 1000)
        XCTAssertTrue(content.blocks.contains { $0.text.contains("types of cheese") })
        XCTAssertTrue(content.blocks.contains { $0.text.contains("how-to-read-a-cheese") })
    }

    /// Attached photos become image blocks, in order, and contribute no text (so
    /// they can never help a short post over the threshold).
    func testPhotosBecomeImageBlocksAndAddNoText() throws {
        let content = try XCTUnwrap(article("thread-six-posts.json"))
        let images = content.blocks.filter { $0.kind == .image }
        XCTAssertFalse(images.isEmpty)
        XCTAssertTrue(images.allSatisfy { $0.text.isEmpty })
        XCTAssertTrue(images.allSatisfy { $0.imageURLString?.isEmpty == false })
    }

    /// Other people's replies are never spliced into someone's saved article,
    /// even if a payload ever carries them.
    func testForeignRepliesAreExcluded() throws {
        let mine = String(repeating: "My own long-form writing continues here. ", count: 20)
        let payload = XPostPayload(
            thread: [
                .init(id: "1", text: mine, author: .init(screen_name: "me", id: "1")),
                .init(id: "2", text: "A stranger butting in.", author: .init(screen_name: "them", id: "2")),
                .init(id: "3", text: mine, author: .init(screen_name: "me", id: "1")),
            ],
            author: .init(screen_name: "me", id: "1"))
        let content = try XCTUnwrap(XPostExtractor.article(from: payload, url: postURL))
        XCTAssertFalse(content.blocks.contains { $0.text.contains("stranger") })
    }

    /// Which posts of a payload count as the author's own chain.
    func testAuthorThreadMembership() {
        let mine = String(repeating: "Long-form writing that keeps going. ", count: 20)
        let cases: [(name: String, payload: XPostPayload, count: Int)] = [
            // A handle rename must not split one author's thread: identity is by id
            // when both sides carry one.
            ("renamed handle, same id", XPostPayload(
                thread: [
                    .init(id: "1", text: mine, author: .init(screen_name: "old_handle", id: "7")),
                    .init(id: "2", text: mine, author: .init(screen_name: "new_handle", id: "7")),
                ],
                author: .init(screen_name: "new_handle", id: "7")), 2),
            // A duplicated post id contributes once.
            ("duplicate post id", XPostPayload(
                thread: [
                    .init(id: "1", text: "a", author: .init(screen_name: "me", id: "1")),
                    .init(id: "1", text: "a", author: .init(screen_name: "me", id: "1")),
                ],
                author: .init(screen_name: "me", id: "1")), 1),
        ]

        for testCase in cases {
            XCTAssertEqual(
                XPostExtractor.authorThread(in: testCase.payload).count,
                testCase.count,
                testCase.name)
        }
    }

    // MARK: - The video guard
    //
    // The decline half (a post shared BECAUSE it holds a video stays media) is a
    // row in `testDeclinedPayloads`.

    /// A clip further down a long essay thread does not disqualify the essay: the
    /// decision is made on the post the URL actually named.
    func testMotionMediaLaterInThreadDoesNotDisqualify() {
        let long = String(repeating: "Essay prose that continues at length. ", count: 20)
        let root = XPostPayload.Post(id: "1", text: long, author: .init(screen_name: "me", id: "1"))
        let payload = XPostPayload(
            status: root,
            thread: [root, .init(
                id: "2", text: long, author: .init(screen_name: "me", id: "1"),
                media: .init(all: [.init(type: "video", url: "https://video.example/v.mp4")]))],
            author: .init(screen_name: "me", id: "1"))
        XCTAssertNotNil(XPostExtractor.article(from: payload, url: postURL))
    }

    // MARK: - Thread counter stripping

    private func threadBlocks(_ texts: [String]) -> [String] {
        let payload = XPostPayload(
            thread: texts.enumerated().map { index, text in
                .init(id: "\(index)", text: text, author: .init(screen_name: "me", id: "1"))
            },
            author: .init(screen_name: "me", id: "1"))
        return XPostExtractor.article(from: payload, url: postURL)?.blocks.map(\.text) ?? []
    }

    /// Padding long enough that ONE padded post clears the length gate on its own,
    /// so these tests isolate the stripping rules from the threshold.
    private let pad = String(repeating: "Sentence of body text to clear the gate. ", count: 16)

    private struct CounterCase {
        let name: String
        let posts: [String]
        /// The first assembled block must start with this.
        var firstBlockPrefix: String?
        /// Some assembled block must start with each of these.
        var blockPrefixes: [String] = []
        /// Some assembled block must contain each of these.
        var survives: [String] = []
        /// No assembled block may contain any of these.
        var stripped: [String] = []
        /// Stripping must never consume a whole post.
        var rejectsEmptyBlocks = false
    }

    func testThreadCounterStripping() {
        let cases: [CounterCase] = [
            // A hand-numbered thread reads as continuous prose: "1/5", "2/5", "3/5"
            // come off both ends.
            .init(name: "consistent closed counters are stripped",
                  posts: ["1/5 First. " + pad, "2/5 Second. " + pad, pad + " 3/5"],
                  firstBlockPrefix: "First.", blockPrefixes: ["Second."],
                  stripped: ["1/5", "2/5", "3/5"]),
            // An open-ended counter has no denominator to mistake for a fraction, so
            // it is stripped even from a single post.
            .init(name: "open-ended counters are stripped",
                  posts: ["1/ Kickoff. " + pad, "2/n Next. " + pad],
                  firstBlockPrefix: "Kickoff.", stripped: ["1/", "2/n"]),
            // Bare ordinal prefixes ("1." / "2)") are markers too, under the same
            // consistent-scheme rule.
            .init(name: "bare ordinal prefixes are stripped",
                  posts: ["1. First. " + pad, "2) Second. " + pad],
                  firstBlockPrefix: "First.", blockPrefixes: ["Second."]),
            // An ordinary fraction in a lone post is prose, not a counter. Nothing in
            // a single post establishes a numbering scheme, so it survives verbatim.
            .init(name: "a lone fraction is not a counter",
                  posts: ["1/2 cup of flour, then stir. " + pad],
                  firstBlockPrefix: "1/2 cup of flour"),
            // A fraction mid-sentence is never a position marker.
            .init(name: "mid-sentence fraction survives",
                  posts: ["Only 3/5 of respondents agreed with the premise. " + pad],
                  survives: ["3/5 of respondents"]),
            // Counters are only stripped where a scheme exists: two posts whose
            // numbers do NOT ascend are not a numbered thread.
            .init(name: "non-ascending closed counters are left alone",
                  posts: ["Mix 1/2 cup water. " + pad, "Add 1/4 cup sugar. " + pad],
                  survives: ["1/2 cup", "1/4 cup"]),
            // Thread furniture — the 🧵 emoji and an explicit end marker — carries no
            // meaning once the chain is one document.
            .init(name: "thread ornaments are stripped",
                  posts: ["🧵 Opening. " + pad, pad + " Closing. /end"],
                  firstBlockPrefix: "Opening.", stripped: ["🧵", "/end"]),
            .init(name: "stripping never empties a post",
                  posts: ["1/", pad + pad], rejectsEmptyBlocks: true),
        ]

        for testCase in cases {
            let blocks = threadBlocks(testCase.posts)
            if let prefix = testCase.firstBlockPrefix {
                XCTAssertEqual(
                    blocks.first?.hasPrefix(prefix), true,
                    "\(testCase.name): first block should start with \"\(prefix)\"")
            }
            for prefix in testCase.blockPrefixes {
                XCTAssertTrue(
                    blocks.contains { $0.hasPrefix(prefix) },
                    "\(testCase.name): no block starts with \"\(prefix)\"")
            }
            for text in testCase.survives {
                XCTAssertTrue(
                    blocks.contains { $0.contains(text) },
                    "\(testCase.name): \"\(text)\" should have survived")
            }
            for marker in testCase.stripped {
                XCTAssertFalse(
                    blocks.contains { $0.contains(marker) },
                    "\(testCase.name): \"\(marker)\" should have been stripped")
            }
            if testCase.rejectsEmptyBlocks {
                XCTAssertFalse(blocks.contains(""), "\(testCase.name): produced an empty block")
            }
        }
    }

    // MARK: - Titles and links

    /// A post has no title, so the opening sentence becomes one.
    func testTitleComesFromTheOpeningSentence() {
        let payload = XPostPayload(
            thread: [.init(
                id: "1", text: "A clear opening statement. Then detail. " + pad,
                author: .init(screen_name: "me", id: "1"))],
            author: .init(screen_name: "me", id: "1"))
        XCTAssertEqual(
            XPostExtractor.article(from: payload, url: postURL)?.title,
            "A clear opening statement")
    }

    /// An over-long opening is cut on a word boundary and ellipsized, never
    /// mid-word.
    func testOverLongTitleIsClippedOnAWordBoundary() throws {
        let sentence = String(repeating: "elaborate ", count: 40)
        let payload = XPostPayload(
            thread: [.init(id: "1", text: sentence + pad, author: .init(screen_name: "me", id: "1"))],
            author: .init(screen_name: "me", id: "1"))
        let title = try XCTUnwrap(XPostExtractor.article(from: payload, url: postURL)?.title)
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertLessThanOrEqual(title.count, 91)
        XCTAssertFalse(title.dropLast().hasSuffix("elabo"))
    }

    /// Bare URLs in post text become inline links without swallowing the
    /// punctuation that follows them.
    func testInlineLinksExcludeTrailingPunctuation() throws {
        let links = XPostExtractor.inlineLinks(in: "See https://example.com/a, then stop.")
        let link = try XCTUnwrap(links.first)
        XCTAssertEqual(link.urlString, "https://example.com/a")
    }
}
