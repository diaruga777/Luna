//
//  XteinkCrossPointTransferTests.swift
//  LunaTests
//

import Foundation
import LunaStorage
import XCTest
@testable import LunaSend

final class XteinkCrossPointTransferTests: XCTestCase {
    private var group: UserDefaults!
    private var legacy: UserDefaults!
    private var groupSuite: String!
    private var legacySuite: String!

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
    override func setUp() {
        HTTPStub.requests = []; HTTPStub.responses = [:]
        groupSuite = "XteinkCrossPointTransferTests.group.\(UUID().uuidString)"
        legacySuite = "XteinkCrossPointTransferTests.legacy.\(UUID().uuidString)"
        group = UserDefaults(suiteName: groupSuite)
        legacy = UserDefaults(suiteName: legacySuite)
        XteinkSendSettings.testDefaultsOverride = MigratingAppGroupDefaults(group: group, legacy: legacy)
    }

    override func tearDown() {
        XteinkSendSettings.testDefaultsOverride = nil
        group.removePersistentDomain(forName: groupSuite)
        legacy.removePersistentDomain(forName: legacySuite)
        group = nil; legacy = nil
    }

    private final class BLE: XteinkBLETransporting {
        var isRendezvousActive = true
        var sent: [(Data, String)] = []
        var wifiRequests = 0
        var deleted: [String] = []
        private(set) var scanCount = 0
        let offer = XteinkWiFiOffer(mode: .ap, ssid: "Xteink-X3", passphrase: "secret-pass", host: "192.168.4.1")
        func beginRendezvousScan() { scanCount += 1 }
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
        /// Optional ordering recorder shared with the uploader fake, so a test
        /// can assert join happens before upload happens before leave.
        var events: OrderRecorder?
        func join(_ offer: XteinkWiFiOffer) async throws {
            joined.append(offer); events?.record("joined")
        }
        func leave(_ offer: XteinkWiFiOffer) {
            left.append(offer); events?.record("left")
        }
    }
    private struct Uploader: XteinkHTTPUploading {
        let record: (Data, String, String) throws -> Void
        func upload(_ data: Data, fileName: String, host: String) async throws { try record(data, fileName, host) }
    }
    private final class Notifier: XteinkTransferNotifying, @unchecked Sendable {
        var titles: [String] = []
        func notifyWiFiTransferRequired(title: String) { titles.append(title) }
    }
    /// Thread-safe append-only event log, used to pin operation ordering
    /// (join → upload → leave) across fakes that don't otherwise share state.
    private final class OrderRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var events: [String] = []
        func record(_ event: String) { lock.withLock { events.append(event) } }
    }
    private struct LANProber: XteinkLANProbing {
        let host: String?
        func reachableHost() async -> String? { host }
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
        let order = OrderRecorder()
        wifi.events = order
        var uploads: [(Int, String, String)] = []
        let router = XteinkCrossPointTransferRouter(
            ble: ble, wifi: wifi,
            uploader: Uploader { data, fileName, host in
                order.record("uploaded")
                uploads.append((data.count, fileName, host))
            },
            notifier: notifier, isForeground: { true })
        let payload = Data(repeating: 9, count: XteinkSyncProtocol.maximumBLEPayloadBytes + 1)
        try await router.send(payload, fileName: "large.epub", title: "Large")
        XCTAssertEqual(ble.wifiRequests, 1)
        XCTAssertEqual(wifi.joined, [ble.offer])
        XCTAssertEqual(wifi.left, [ble.offer])
        XCTAssertEqual(uploads.map(\.1), ["large.epub"])
        XCTAssertEqual(uploads.map(\.2), ["192.168.4.1"])
        XCTAssertTrue(notifier.titles.isEmpty)
        // Regression: the hotspot config must not be removed before the
        // upload actually runs against it.
        XCTAssertEqual(order.events, ["joined", "uploaded", "left"])
    }

    /// The upload throwing must still leave the hotspot configuration removed
    /// — `defer` at function scope, not scoped inside the join `if`.
    func testAPIsLeftEvenWhenUploadFails() async {
        let ble = BLE(); let wifi = WiFi(); let notifier = Notifier()
        let order = OrderRecorder()
        wifi.events = order
        struct UploadFailure: Error {}
        let router = XteinkCrossPointTransferRouter(
            ble: ble, wifi: wifi,
            uploader: Uploader { _, _, _ in order.record("uploaded"); throw UploadFailure() },
            notifier: notifier, isForeground: { true })
        do {
            try await router.send(
                Data(repeating: 2, count: XteinkSyncProtocol.maximumBLEPayloadBytes + 1),
                fileName: "large.epub", title: "Large")
            XCTFail("must propagate the upload failure")
        } catch is UploadFailure {
        } catch { XCTFail("unexpected error \(error)") }
        XCTAssertEqual(wifi.joined, [ble.offer])
        XCTAssertEqual(wifi.left, [ble.offer])
        XCTAssertEqual(order.events, ["joined", "uploaded", "left"])
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
            func beginRendezvousScan() {}
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

    // MARK: - sendNow (WiFi-first "send now" routing)

    func testSendNowUsesLANProbeHitOverBLE() async throws {
        XteinkSendSettings.isEnabled = true
        let ble = BLE(); let wifi = WiFi(); let notifier = Notifier()
        var uploads: [(String, String)] = []
        let router = XteinkCrossPointTransferRouter(
            ble: ble, wifi: wifi,
            uploader: Uploader { _, fileName, host in uploads.append((fileName, host)) },
            notifier: notifier, lanProber: LANProber(host: "crosspoint.local"),
            isForeground: { true }, rendezvousWaitTimeout: 0.05, rendezvousPollInterval: 0.01)
        try await router.sendNow(Data("article".utf8), fileName: "a.epub", title: "A")
        XCTAssertEqual(uploads.map(\.0), ["a.epub"])
        XCTAssertEqual(uploads.map(\.1), ["crosspoint.local"])
        XCTAssertTrue(ble.sent.isEmpty)
        XCTAssertEqual(ble.wifiRequests, 0)
        XCTAssertEqual(ble.scanCount, 0)
    }

    func testSendNowIgnoresLANProbeWhenXteinkNotEnabled() async throws {
        XteinkSendSettings.isEnabled = false
        let ble = BLE(); ble.isRendezvousActive = true
        let router = XteinkCrossPointTransferRouter(
            ble: ble, wifi: WiFi(),
            uploader: Uploader { _, _, _ in XCTFail("must not upload while disabled") },
            notifier: Notifier(), lanProber: LANProber(host: "crosspoint.local"),
            isForeground: { true }, rendezvousWaitTimeout: 0.05, rendezvousPollInterval: 0.01)
        try await router.sendNow(Data("article".utf8), fileName: "a.epub", title: "A")
        XCTAssertEqual(ble.sent.count, 1)
    }

    func testSendNowFallsBackToBLEWhenAlreadyRendezvousedAfterProbeMiss() async throws {
        XteinkSendSettings.isEnabled = true
        let ble = BLE(); ble.isRendezvousActive = true
        let router = XteinkCrossPointTransferRouter(
            ble: ble, wifi: WiFi(),
            uploader: Uploader { _, _, _ in XCTFail("small payload must go over BLE") },
            notifier: Notifier(), lanProber: LANProber(host: nil),
            isForeground: { true }, rendezvousWaitTimeout: 0.05, rendezvousPollInterval: 0.01)
        try await router.sendNow(Data("article".utf8), fileName: "a.epub", title: "A")
        XCTAssertEqual(ble.sent.count, 1)
        // Already active: no need to kick a fresh scan.
        XCTAssertEqual(ble.scanCount, 0)
    }

    func testSendNowThrowsUnavailableWhenNeitherLANNorRendezvousArrive() async {
        XteinkSendSettings.isEnabled = true
        let ble = BLE(); ble.isRendezvousActive = false
        let router = XteinkCrossPointTransferRouter(
            ble: ble, wifi: WiFi(),
            uploader: Uploader { _, _, _ in XCTFail("nothing is reachable") },
            notifier: Notifier(), lanProber: LANProber(host: nil),
            isForeground: { true }, rendezvousWaitTimeout: 0.05, rendezvousPollInterval: 0.01)
        do {
            try await router.sendNow(Data("article".utf8), fileName: "a.epub", title: "A")
            XCTFail("must throw when nothing answers")
        } catch let error as XteinkSyncError {
            XCTAssertEqual(error, .unavailable)
        } catch { XCTFail("unexpected error \(error)") }
        // A scan was kicked off to give BLE a chance before giving up.
        XCTAssertGreaterThanOrEqual(ble.scanCount, 1)
    }
}
