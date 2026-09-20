//
//  PluginAPIHelpersTests.swift
//  LunaTests
//

import LunaPluginKit
import LunaPluginRuntime
import XCTest

/// The helpers WP4 added to the plugin API, exercised through the shipped
/// JavaScriptCore bridges: `luna.html.article`, the `luna.fetch` sugar, and
/// `luna.text`'s place in the `html` grant.
///
/// The pure answers of `luna.html.meta`/`jsonLD`/`luna.text.*` are specified in
/// `html-subset.spec.js` and run against all three backings by
/// `PluginHTMLSubsetTests`, `PluginHTMLParityTests` and the node harness; this
/// suite covers what those three cannot: native extraction and the network.
final class PluginAPIHelpersTests: XCTestCase {

    private var runner: PluginJSFixtureRunner!

    override func setUp() {
        super.setUp()
        runner = PluginJSFixtureRunner()
    }

    override func tearDown() {
        runner.cleanUp()
        runner = nil
        super.tearDown()
    }

    private struct Answer: Decodable {
        let ok: Bool?
        let code: String?
        let title: String?
        let html: String?
        let text: String?
        let author: String?
        let publishedAt: String?
        let leadImageURL: String?
        let excerpt: String?
        let isNull: Bool?
        let value: String?
        let count: Int?
    }

    private static let articlePage = """
    <html><head><title>Fallback</title>
    <meta property="og:title" content="The Headline">
    <meta property="og:image" content="/lead.png">
    <meta property="og:description" content="A short standfirst.">
    <meta name="author" content="A. Writer">
    <meta property="article:published_time" content="2024-03-04T09:30:00Z">
    </head><body>
    <nav><a href="/section">Section</a></nav>
    <article>
    <p>\(String(repeating: "The first paragraph carries the reporting. ", count: 20))</p>
    <p>\(String(repeating: "The second paragraph carries more of it. ", count: 20))</p>
    <p>A closing line with <a href="/inside">a link</a> in it.</p>
    </article>
    <aside class="related"><a href="/other">Related story</a></aside>
    </body></html>
    """

    /// Runs one expression inside a plugin and decodes its answer.
    private func answer(
        declaring capabilities: String, body: String, id: String = "app.luna.helpers",
        file: StaticString = #filePath, line: UInt = #line
    ) async -> Answer? {
        let source = """
        /* luna-plugin
        { "id": "\(id)", "name": "Helpers", "version": "1.0.0", "api": 1,
          "capabilities": \(capabilities) }
        */
        luna.register({
            async onAction() {
                \(body)
            }
        });
        """
        do {
            try runner.load(source, file: file, line: line)
        } catch {
            XCTFail("the fixture did not load: \(error)", file: file, line: line)
            return nil
        }
        return await runner.invoke(
            .onAction, pluginID: id, as: Answer.self, file: file, line: line)
    }

    // MARK: - luna.html.article

    func testArticleExtractsTheBodyAndTheMetadataAroundIt() async {
        let page = Self.articlePage
        let found = await answer(
            declaring: #"["html"]"#,
            body: """
            const found = await luna.html.article(
                \(Self.jsString(page)), "https://example.com/dir/story.html");
            return found === null ? { isNull: true } : found;
            """)
        guard let found else { return }
        XCTAssertNil(found.isNull)
        XCTAssertEqual(found.title, "The Headline")
        XCTAssertEqual(found.author, "A. Writer")
        XCTAssertEqual(found.publishedAt, "2024-03-04T09:30:00Z")
        XCTAssertEqual(found.leadImageURL, "https://example.com/lead.png")
        XCTAssertEqual(found.excerpt, "A short standfirst.")
        XCTAssertEqual(found.html?.contains("<p>"), true)
        XCTAssertEqual(found.html?.contains("the reporting"), true)
        XCTAssertEqual(found.text?.contains("the reporting"), true)
        XCTAssertEqual(
            found.html?.contains("Related story"), false,
            "the related-links rail reached the article body")
    }

    /// An inline link survives as an anchor, because a plugin's `html` is what
    /// the reader renders.
    func testArticleKeepsAnInlineLinkAsAnAnchor() async {
        let page = Self.articlePage
        let found = await answer(
            declaring: #"["html"]"#,
            body: """
            const found = await luna.html.article(
                \(Self.jsString(page)), "https://example.com/dir/story.html");
            return { ok: true, value: found.html.indexOf('<a href="') >= 0 ? "yes" : "no" };
            """)
        XCTAssertEqual(found?.value, "yes")
    }

    func testArticleAnswersNullWhenThePageHasNoBody() async {
        let found = await answer(
            declaring: #"["html"]"#,
            body: """
            const found = await luna.html.article("<html><body></body></html>",
                                                  "https://example.com/");
            return { isNull: found === null };
            """)
        XCTAssertEqual(found?.isNull, true)
    }

    func testArticleRejectsEmptyInput() async {
        let found = await answer(
            declaring: #"["html"]"#,
            body: """
            try { await luna.html.article(""); } catch (e) { return { code: e.code }; }
            return { code: "no error" };
            """)
        XCTAssertEqual(found?.code, "bad-argument")
    }

    // MARK: - luna.text under the html grant

    /// A manifest declaring `html` and nothing else must LOAD with `luna.text`
    /// present. The runtime compares what a plugin can see against what it
    /// declared, so a companion namespace the check does not know about fails
    /// the load outright.
    func testTextRidesOnTheHTMLGrantWithoutBeingDeclared() async {
        let found = await answer(
            declaring: #"["html"]"#,
            body: """
            return { value: typeof luna.text.clean("  a  b ") + ":" + luna.text.clean(" a  b ") };
            """)
        XCTAssertEqual(found?.value, "string:a b")
    }

    func testAPluginThatDeclaresTextAsACapabilityDoesNotLoad() throws {
        let source = """
        /* luna-plugin
        { "id": "app.luna.textcap", "name": "Text", "version": "1.0.0", "api": 1,
          "capabilities": ["text"] }
        */
        luna.register({ async onAction() { return {}; } });
        """
        // `text` is not a capability name, so the manifest never parses.
        switch PluginManifestParser.parse(source: source) {
        case .success:
            XCTFail("a manifest declaring \"text\" as a capability was accepted")
        case .failure:
            break
        }
    }

    // MARK: - luna.fetch sugar

    func testFetchTextAnswersTheBody() async {
        runner.fetcher.respond(to: "https://example.com/page", body: "<p>hello</p>")
        let found = await answer(
            declaring: #"["fetch"]"#,
            body: #"return { value: await luna.fetch.text("https://example.com/page") };"#)
        XCTAssertEqual(found?.value, "<p>hello</p>")
        XCTAssertEqual(runner.fetcher.requests.first?.method, "GET")
    }

    func testFetchTextRejectsANon2xxWithTheStatusInTheMessage() async {
        runner.fetcher.respond(to: "https://example.com/gone", status: 404, body: "nope")
        let found = await answer(
            declaring: #"["fetch"]"#,
            body: """
            try { await luna.fetch.text("https://example.com/gone"); }
            catch (e) { return { code: e.code, value: e.message }; }
            return { code: "no error" };
            """)
        XCTAssertEqual(found?.code, "fetch-failed")
        XCTAssertEqual(found?.value?.contains("404"), true)
    }

    func testFetchJSONParsesTheBody() async {
        runner.fetcher.respond(to: "https://example.com/api", body: #"{"title":"Clip"}"#)
        let found = await answer(
            declaring: #"["fetch"]"#,
            body: """
            const info = await luna.fetch.json("https://example.com/api");
            return { value: info.title };
            """)
        XCTAssertEqual(found?.value, "Clip")
    }

    func testFetchJSONRejectsABodyThatIsNotJSON() async {
        runner.fetcher.respond(to: "https://example.com/api", body: "<html>")
        let found = await answer(
            declaring: #"["fetch"]"#,
            body: """
            try { await luna.fetch.json("https://example.com/api"); }
            catch (e) { return { code: e.code }; }
            return { code: "no error" };
            """)
        XCTAssertEqual(found?.code, "fetch-failed")
    }

    /// `doc` parses against the FINAL URL, so a relative link on a redirected
    /// page resolves where the page actually came from.
    func testFetchDocParsesAgainstTheFinalURL() async {
        runner.fetcher.respond(
            to: "https://example.com/short", body: "<a href='x.html'>a</a>",
            finalURL: "https://example.com/dir/long.html")
        let found = await answer(
            declaring: #"["fetch","html"]"#,
            body: """
            const doc = await luna.fetch.doc("https://example.com/short");
            return { value: doc.querySelector("a").absoluteURL("href") };
            """)
        XCTAssertEqual(found?.value, "https://example.com/dir/long.html")
    }

    func testFetchDocRefusesWhenTheManifestDidNotDeclareHTML() async {
        runner.fetcher.respond(to: "https://example.com/page", body: "<p>x</p>")
        let found = await answer(
            declaring: #"["fetch"]"#,
            body: """
            try { await luna.fetch.doc("https://example.com/page"); }
            catch (e) { return { code: e.code }; }
            return { code: "no error" };
            """)
        XCTAssertEqual(found?.code, "capability-not-declared")
    }

    /// The sugar is installed ON the callable, so the plain form still works.
    func testFetchStaysCallable() async {
        runner.fetcher.respond(to: "https://example.com/page", status: 404, body: "nope")
        let found = await answer(
            declaring: #"["fetch"]"#,
            body: """
            const response = await luna.fetch("https://example.com/page");
            return { value: response.status + ":" + response.text };
            """)
        XCTAssertEqual(found?.value, "404:nope")
    }

    /// A JS string literal for arbitrary text.
    private static func jsString(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: text, options: [.fragmentsAllowed])
        else { return "\"\"" }
        return String(decoding: data, as: UTF8.self)
    }
}
