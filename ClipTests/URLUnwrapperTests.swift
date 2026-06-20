//
//  URLUnwrapperTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

/// Intercepts URLSession requests for the `URLUnwrapper` fetch handlers and returns
/// canned responses. For the shortener HEAD-redirect case the response URL can be
/// overridden so the resolver sees a cross-host final URL.
private final class UnwrapMockProtocol: URLProtocol {
    /// path-substring → (statusCode, body, finalURL?). `finalURL` overrides the
    /// response's `url` (so a shortener appears to redirect off-host).
    static var routes: [(match: String, status: Int, body: Data, finalURL: URL?)] = []
    static var requestedURLs: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let urlString = request.url?.absoluteString ?? ""
        Self.requestedURLs.append(urlString)
        let route = Self.routes.first { urlString.contains($0.match) }
        let status = route?.status ?? 404
        let body = route?.body ?? Data()
        let responseURL = route?.finalURL ?? request.url
        let response = HTTPURLResponse(
            url: responseURL ?? URL(fileURLWithPath: "/"),
            statusCode: status, httpVersion: nil, headerFields: nil)
        if let response {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UnwrapMockProtocol.self]
        return URLSession(configuration: config)
    }

    static func reset() {
        routes = []
        requestedURLs = []
    }
}

/// Covers the `URLUnwrapper` registry: offline (`unwrapOffline`) for Facebook +
/// Google-News-classic, and network (`unwrap`) for Apple News, Google-News
/// new-style, and link shorteners (via a mock session). Also asserts tracking
/// params are stripped from the result.
final class URLUnwrapperTests: XCTestCase {

    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else { fatalError("bad test URL: \(string)") }
        return url
    }

    override func setUp() {
        super.setUp()
        UnwrapMockProtocol.reset()
    }

    // MARK: - Offline fast path

    func testUnwrapOfflineResolvesFacebookMessengerLink() {
        let fbrpc = url("fbrpc://nativethirdparty/f?app_id=123"
            + "&target_url=https%3A%2F%2Ftechcrunch.com%2F2026%2F06%2F09%2Fstory%2F")
        let result = URLUnwrapper.unwrapOffline(fbrpc)
        XCTAssertTrue(result.didUnwrap)
        XCTAssertEqual(result.wrapper, .facebook)
        XCTAssertEqual(result.url.absoluteString, "https://techcrunch.com/2026/06/09/story/")
    }

    func testUnwrapOfflineResolvesFacebookLinkShim() {
        let shim = url("https://l.facebook.com/l.php?u=https%3A%2F%2Fwww.theverge.com%2Fstory&h=AT1")
        let result = URLUnwrapper.unwrapOffline(shim)
        XCTAssertTrue(result.didUnwrap)
        XCTAssertEqual(result.url.absoluteString, "https://www.theverge.com/story")
    }

    func testUnwrapOfflineLeavesFacebookTargetUnchanged() {
        let shim = url("https://l.facebook.com/l.php?u=https%3A%2F%2Fwww.facebook.com%2Fgroups%2F42")
        let result = URLUnwrapper.unwrapOffline(shim)
        XCTAssertFalse(result.didUnwrap)
    }

    func testUnwrapOfflineResolvesGoogleNewsClassicOffline() {
        // A classic CBMi… id base64-decodes to a blob embedding the publisher URL.
        let publisher = "https://www.example.com/news/story-123"
        var bytes: [UInt8] = [0x08, 0x13, 0x22, UInt8(publisher.utf8.count)]
        bytes += Array(publisher.utf8)
        bytes += [0xd2, 0x01, 0x00]
        let id = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let result = URLUnwrapper.unwrapOffline(url("https://news.google.com/rss/articles/\(id)?oc=5"))
        XCTAssertTrue(result.didUnwrap)
        XCTAssertEqual(result.wrapper, .googleNews)
        XCTAssertEqual(result.url.absoluteString, publisher)
    }

    func testUnwrapOfflineLeavesAppleNewsAndShortenerUntouched() {
        // .fetch wrappers are not resolved offline.
        let appleNews = URLUnwrapper.unwrapOffline(url("https://apple.news/AONYnIYXuSh"))
        XCTAssertFalse(appleNews.didUnwrap)
        let shortener = URLUnwrapper.unwrapOffline(url("https://nyti.ms/abc"))
        XCTAssertFalse(shortener.didUnwrap)
    }

    func testUnwrapOfflineLeavesOrdinaryURLUnchanged() {
        let ordinary = url("https://www.nytimes.com/2026/06/20/world/story.html")
        let result = URLUnwrapper.unwrapOffline(ordinary)
        XCTAssertFalse(result.didUnwrap)
        XCTAssertNil(result.wrapper)
        XCTAssertEqual(result.url.absoluteString, ordinary.absoluteString)
    }

    func testUnwrapOfflineStringConvenience() {
        let fbrpc = "fbrpc://nativethirdparty/f?target_url=https%3A%2F%2Fexample.org%2Fa"
        XCTAssertEqual(URLUnwrapper.unwrapOffline(fbrpc), "https://example.org/a")
        XCTAssertEqual(URLUnwrapper.unwrapOffline("plain string"), "plain string")
    }

    // MARK: - Tracking-param stripping

    func testUnwrapStripsTrackingParamsFromResult() async {
        let fbrpc = url("fbrpc://nativethirdparty/f?target_url="
            + "https%3A%2F%2Ftechcrunch.com%2Fstory%2F%3Ffbclid%3DAbCdEf123")
        let result = await URLUnwrapper.unwrap(fbrpc, session: UnwrapMockProtocol.session())
        XCTAssertTrue(result.didUnwrap)
        XCTAssertFalse(result.url.absoluteString.contains("fbclid"))
        XCTAssertEqual(result.url.absoluteString, "https://techcrunch.com/story/")
    }

    // MARK: - Network handlers (mock session)

    func testUnwrapAppleNewsFetchesPublisherURL() async {
        let html = #"redirectToUrlAfterTimeout("https://www.weatherzone.com.au/news/story/1", 3000);"#
        UnwrapMockProtocol.routes = [("apple.news", 200, Data(html.utf8), nil)]
        let result = await URLUnwrapper.unwrap(url("https://apple.news/AONYnIYXuSh"), session: UnwrapMockProtocol.session())
        XCTAssertTrue(result.didUnwrap)
        XCTAssertEqual(result.wrapper, .appleNews)
        XCTAssertEqual(result.url.absoluteString, "https://www.weatherzone.com.au/news/story/1")
    }

    func testUnwrapAppleNewsPlusExclusiveStaysUnchanged() async {
        let html = "<html><body>Open in the News app.</body></html>"
        UnwrapMockProtocol.routes = [("apple.news", 200, Data(html.utf8), nil)]
        let input = url("https://apple.news/AONYnIYXuSh")
        let result = await URLUnwrapper.unwrap(input, session: UnwrapMockProtocol.session())
        XCTAssertFalse(result.didUnwrap)
        XCTAssertEqual(result.url.absoluteString, input.absoluteString)
    }

    func testUnwrapGoogleNewsNewStyleViaBatchExecute() async {
        // A new-style id (no embedded URL → offline decode fails) needs the RPC.
        let id = "AU_yqL_NEW_STYLE_ID"
        let page = #"<div data-n-a-sg="sig123" data-n-a-ts="999"></div>"#
        let rpc = #"[["wrb.fr","Fbv4je","[\"garturlres\",\"https://real.example.com/article-42\",[\"en\"]]"]]"#
        UnwrapMockProtocol.routes = [
            ("/rss/articles/\(id)", 200, Data(page.utf8), nil),
            ("batchexecute", 200, Data(rpc.utf8), nil),
        ]
        let result = await URLUnwrapper.unwrap(url("https://news.google.com/read/\(id)"), session: UnwrapMockProtocol.session())
        XCTAssertTrue(result.didUnwrap)
        XCTAssertEqual(result.wrapper, .googleNews)
        XCTAssertEqual(result.url.absoluteString, "https://real.example.com/article-42")
    }

    func testUnwrapShortenerFollowsCrossHostRedirect() async {
        let finalURL = url("https://www.nytimes.com/2026/06/20/world/story.html")
        UnwrapMockProtocol.routes = [("nyti.ms", 200, Data(), finalURL)]
        let result = await URLUnwrapper.unwrap(url("https://nyti.ms/abc"), session: UnwrapMockProtocol.session())
        XCTAssertTrue(result.didUnwrap)
        XCTAssertEqual(result.wrapper, .shortener)
        XCTAssertEqual(result.url.absoluteString, finalURL.absoluteString)
    }

    func testUnwrapShortenerStayingOnHostIsNotUnwrapped() async {
        // Final URL resolves back to the same shortener host → not an unwrap.
        let sameHost = url("https://t.co/landing")
        UnwrapMockProtocol.routes = [("t.co", 200, Data(), sameHost)]
        let result = await URLUnwrapper.unwrap(url("https://t.co/abc"), session: UnwrapMockProtocol.session())
        XCTAssertFalse(result.didUnwrap)
    }

    func testUnwrapOrdinaryURLDoesNoNetwork() async {
        let ordinary = url("https://www.nytimes.com/2026/06/20/world/story.html")
        let result = await URLUnwrapper.unwrap(ordinary, session: UnwrapMockProtocol.session())
        XCTAssertFalse(result.didUnwrap)
        XCTAssertTrue(UnwrapMockProtocol.requestedURLs.isEmpty, "ordinary URL must not hit the network")
    }
}
