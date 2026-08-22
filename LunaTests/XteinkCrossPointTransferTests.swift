//
//  XteinkCrossPointTransferTests.swift
//  LunaTests
//

import Foundation
import XCTest
@testable import LunaSend

final class XteinkCrossPointTransferTests: XCTestCase {
    private final class HTTPStub: URLProtocol {
        struct RecordedRequest { let request: URLRequest; let body: Data }
        static var requests: [RecordedRequest] = []
        static var responses: [String: (Int, Data)] = [:]
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.requests.append(RecordedRequest(request: request, body: Self.body(of: request)))
            let key = request.url!.path + (request.url!.query.map { "?\($0)" } ?? "")
            let response = Self.responses[key] ?? (404, Data())
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: response.0, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.1); client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
        private static func body(of request: URLRequest) -> Data {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return Data() }
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 16_384)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            return data
        }
    }
    override func setUp() { HTTPStub.requests = []; HTTPStub.responses = [:] }
    private final class BLE: XteinkBLETransporting {
        var isRendezvousActive = true
        var sent: [(Data, String)] = []
        var wifiRequests = 0
        var deleted: [String] = []
        let offer = XteinkWiFiOffer(mode: .ap, ssid: "Xteink-X3", passphrase: "secret-pass", host: "192.168.4.1")
        func send(_ epub: Data, fileName: String, title: String,
                  progress: @escaping @Sendable (XteinkSyncProgress) -> Void) async throws {
            sent.append((epub, fileName))
            progress(XteinkSyncProgress(completedBytes: epub.count, totalBytes: epub.count))
        }
        func requestWiFi() async throws -> XteinkWiFiOffer { wifiRequests += 1; return offer }
        func delete(remotePath: String) async throws { deleted.append(remotePath) }
    }
    private final class WiFi: XteinkWiFiJoining, @unchecked Sendable {
        var joined: [XteinkWiFiOffer] = []; var left: [XteinkWiFiOffer] = []
        func join(_ offer: XteinkWiFiOffer) async throws { joined.append(offer) }
        func leave(_ offer: XteinkWiFiOffer) { left.append(offer) }
    }
    private struct Uploader: XteinkHTTPUploading {
        let record: (Data, String, String) -> Void
        func upload(_ data: Data, fileName: String, host: String) async throws { record(data, fileName, host) }
    }
    private final class Notifier: XteinkTransferNotifying, @unchecked Sendable {
        var titles: [String] = []
        func notifyWiFiTransferRequired(title: String) { titles.append(title) }
    }

    func testSmallPayloadUsesBLEAndNeverAsksForWiFi() async throws {
        let ble = BLE(); let wifi = WiFi(); let notifier = Notifier()
        let router = XteinkCrossPointTransferRouter(
            ble: ble, wifi: wifi, uploader: Uploader { _, _, _ in XCTFail("unexpected HTTP upload") },
            notifier: notifier, isForeground: { true })
        let payload = Data(repeating: 5, count: XteinkSyncProtocol.maximumBLEPayloadBytes)
        try await router.send(payload, fileName: "small.epub", title: "Small")
        XCTAssertEqual(ble.sent.count, 1)
        XCTAssertEqual(ble.wifiRequests, 0)
        XCTAssertTrue(wifi.joined.isEmpty)
    }

    func testNoRendezvousDefersSmallPayload() async {
        let ble = BLE(); ble.isRendezvousActive = false
        let router = XteinkCrossPointTransferRouter(ble: ble, wifi: WiFi(), uploader: Uploader { _, _, _ in }, notifier: Notifier(), isForeground: { true })
        do {
            try await router.send(Data("article".utf8), fileName: "a.epub", title: "A")
            XCTFail("The sleeping reader must defer")
        } catch let error as XteinkSyncError { XCTAssertEqual(error, .unavailable) }
        catch { XCTFail("unexpected error \(error)") }
    }

    func testLargeForegroundPayloadRequestsAPUploadsThenForgetsNetwork() async throws {
        let ble = BLE(); let wifi = WiFi(); let notifier = Notifier()
        var uploads: [(Int, String, String)] = []
        let router = XteinkCrossPointTransferRouter(
            ble: ble, wifi: wifi, uploader: Uploader { data, fileName, host in uploads.append((data.count, fileName, host)) },
            notifier: notifier, isForeground: { true })
        let payload = Data(repeating: 9, count: XteinkSyncProtocol.maximumBLEPayloadBytes + 1)
        try await router.send(payload, fileName: "large.epub", title: "Large")
        XCTAssertEqual(ble.wifiRequests, 1)
        XCTAssertEqual(wifi.joined, [ble.offer])
        XCTAssertEqual(wifi.left, [ble.offer])
        XCTAssertEqual(uploads.map(\.1), ["large.epub"])
        XCTAssertEqual(uploads.map(\.2), ["192.168.4.1"])
        XCTAssertTrue(notifier.titles.isEmpty)
    }

    func testLargeBackgroundPayloadNotifiesInsteadOfJoiningAP() async {
        let ble = BLE(); let wifi = WiFi(); let notifier = Notifier()
        let router = XteinkCrossPointTransferRouter(
            ble: ble, wifi: wifi, uploader: Uploader { _, _, _ in XCTFail("must wait for foreground") },
            notifier: notifier, isForeground: { false })
        do {
            try await router.send(Data(repeating: 1, count: XteinkSyncProtocol.maximumBLEPayloadBytes + 1), fileName: "large.epub", title: "Long read")
            XCTFail("must defer")
        } catch let error as XteinkSyncError { XCTAssertEqual(error, .unavailable) }
        catch { XCTFail("unexpected error \(error)") }
        XCTAssertEqual(notifier.titles, ["Long read"])
        XCTAssertTrue(wifi.joined.isEmpty)
    }

    func testLargeSTAOfferUploadsWithoutJoiningAnAccessPoint() async throws {
        let wifi = WiFi()
        // The reader already joined this LAN before it reported Wi-Fi ready.
        // Rebuild the fake with its offer changed rather than invoking hotspot APIs.
        // (Its offer is immutable, so a small alternate fake is clearer.)
        final class STABLE: XteinkBLETransporting {
            var isRendezvousActive = true
            func send(_ epub: Data, fileName: String, title: String, progress: @escaping @Sendable (XteinkSyncProgress) -> Void) async throws {}
            func requestWiFi() async throws -> XteinkWiFiOffer { XteinkWiFiOffer(mode: .sta, host: "192.168.1.30") }
            func delete(remotePath: String) async throws {}
        }
        let staRouter = XteinkCrossPointTransferRouter(ble: STABLE(), wifi: wifi,
            uploader: Uploader { _, _, host in XCTAssertEqual(host, "192.168.1.30") }, notifier: Notifier(), isForeground: { true })
        try await staRouter.send(Data(repeating: 3, count: XteinkSyncProtocol.maximumBLEPayloadBytes + 1), fileName: "sta.epub", title: "STA")
        XCTAssertTrue(wifi.joined.isEmpty)
    }

    func testCrossPointUploadIsMultipartAndAcceptsSuccessfulResponse() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [HTTPStub.self]
        let client = XteinkCrossPointClient(session: URLSession(configuration: configuration))
        HTTPStub.responses["/upload?path=/Books"] = (200, Data())
        let epub = Data("nonempty-epub".utf8)
        try await client.upload(epub, fileName: "book.epub", host: "x3.local")
        XCTAssertEqual(HTTPStub.requests.map { $0.request.httpMethod ?? "" }, ["POST"])
        let request = try XCTUnwrap(HTTPStub.requests.first)
        let contentType = try XCTUnwrap(request.request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(contentType.contains("multipart/form-data"))
        let body = request.body
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("filename=\"book.epub\""))
        XCTAssertTrue(body.range(of: epub) != nil)
        XCTAssertTrue(text.hasSuffix("--\r\n"))
    }

    func testCrossPointUploadRejectsNonSuccessResponse() async {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [HTTPStub.self]
        let client = XteinkCrossPointClient(session: URLSession(configuration: configuration))
        HTTPStub.responses["/upload?path=/Books"] = (500, Data())
        do { try await client.upload(Data("epub".utf8), fileName: "book.epub", host: "x3.local"); XCTFail("must fail") }
        catch { }
    }
}
