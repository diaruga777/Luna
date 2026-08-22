//
//  XteinkDeviceClientTests.swift
//  LunaTests
//

import Foundation
import XCTest
@testable import LunaSend

/// Serves scripted responses for the Xteink firmware endpoints and records
/// every request (with its body reassembled from the stream URLSession hands
/// a protocol instead of `httpBody`).
private final class XteinkStubProtocol: URLProtocol {

    struct RecordedRequest {
        let method: String
        let url: URL
        let body: Data
    }

    /// URL path+query → (status, body), or nil to fail with this URLError code.
    static var responses: [String: (status: Int, body: Data)] = [:]
    static var connectionFailures: [String: URLError.Code] = [:]
    static var recorded: [RecordedRequest] = []
    private static let lock = NSLock()

    static func reset() {
        lock.withLock {
            responses = [:]
            connectionFailures = [:]
            recorded = []
        }
    }

    static func record(_ request: RecordedRequest) {
        lock.withLock { recorded.append(request) }
    }

    static func requests(matching predicate: (RecordedRequest) -> Bool) -> [RecordedRequest] {
        lock.withLock { recorded.filter(predicate) }
    }

    /// The stub key for a request: host + path (+ query), so two fake hosts can
    /// answer differently.
    static func key(host: String, pathAndQuery: String) -> String {
        host + pathAndQuery
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let body = Self.drainBody(of: request)
        Self.record(RecordedRequest(
            method: request.httpMethod ?? "GET", url: url, body: body))

        var pathAndQuery = url.path
        if let query = url.query { pathAndQuery += "?" + query }
        let key = Self.key(host: url.host ?? "", pathAndQuery: pathAndQuery)

        if let code = Self.lock.withLock({ Self.connectionFailures[key] }) {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        guard let response = Self.lock.withLock({ Self.responses[key] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let http = HTTPURLResponse(
            url: url, statusCode: response.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/json"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession strips `httpBody` into a stream before the protocol sees it.
    private static func drainBody(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 16_384
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

final class XteinkDeviceClientTests: XCTestCase {

    private var client: XteinkDeviceClient!

    override func setUp() {
        super.setUp()
        XteinkStubProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [XteinkStubProtocol.self]
        client = XteinkDeviceClient(
            session: XteinkDeviceClient.makeSession(configuration: configuration))
    }

    override func tearDown() {
        XteinkStubProtocol.reset()
        super.tearDown()
    }

    private func stubStatus(host: String, deviceType: String) {
        let body = try! JSONSerialization.data(withJSONObject: [
            "device_type": deviceType, "usedBytes": 1, "totalBytes": 2,
        ])
        XteinkStubProtocol.responses["\(host)/status"] = (200, body)
    }

    private func stubListing(host: String, entries: [[String: Any]]) {
        let body = try! JSONSerialization.data(withJSONObject: entries)
        XteinkStubProtocol.responses["\(host)/list?dir=/Pushed%20Books"] = (200, body)
    }

    // MARK: - Discovery

    func testFindDevicePicksFirstHostAnsweringAsESP32() async {
        stubStatus(host: "live.local", deviceType: "ESP32-C3")
        let found = await client.findDevice(among: ["dead.local", "live.local"])
        XCTAssertEqual(found, "live.local")
    }

    func testFindDeviceRejectsNonXteinkHTTPServers() async {
        stubStatus(host: "printer.local", deviceType: "LaserJet")
        let found = await client.findDevice(among: ["printer.local"])
        XCTAssertNil(found)
    }

    // MARK: - Upload

    func testUploadSendsMultipartWithDestinationPathAsFilename() async throws {
        let host = "e.local"
        let payload = Data("epub-bytes".utf8)
        XteinkStubProtocol.responses["\(host)/edit"] = (200, Data())
        stubListing(host: host, entries: [
            ["type": "file", "name": "Book.epub", "size": payload.count],
        ])

        try await client.uploadBook(payload, fileName: "Book.epub", host: host)

        let uploads = XteinkStubProtocol.requests { $0.method == "POST" }
        XCTAssertEqual(uploads.count, 1)
        let body = String(decoding: uploads[0].body, as: UTF8.self)
        XCTAssertTrue(body.contains(
            "Content-Disposition: form-data; name=\"data\"; filename=\"/Pushed Books/Book.epub\""))
        XCTAssertTrue(body.contains("epub-bytes"))

        // The shelf directory is created (or confirmed) before the upload.
        let mkdirs = XteinkStubProtocol.requests { $0.method == "PUT" }
        XCTAssertEqual(mkdirs.count, 1)
        XCTAssertTrue(String(decoding: mkdirs[0].body, as: UTF8.self)
            .contains("path=%2FPushed%20Books%2F"))
    }

    func testTruncatedUploadIsDeletedFromDeviceAndThrows() async {
        let host = "e.local"
        let payload = Data(repeating: 7, count: 1_000)
        XteinkStubProtocol.responses["\(host)/edit"] = (200, Data())
        stubListing(host: host, entries: [
            ["type": "file", "name": "Book.epub", "size": 400],
        ])

        do {
            try await client.uploadBook(payload, fileName: "Book.epub", host: host)
            XCTFail("A size mismatch must throw")
        } catch let error as XteinkDeviceClient.UploadError {
            guard case .verificationFailed(let expected, let actual) = error else {
                return XCTFail("Wrong upload error: \(error)")
            }
            XCTAssertEqual(expected, 1_000)
            XCTAssertEqual(actual, 400)
        } catch {
            XCTFail("Wrong error: \(error)")
        }

        let deletes = XteinkStubProtocol.requests { $0.method == "DELETE" }
        XCTAssertEqual(deletes.count, 1)
        XCTAssertTrue(String(decoding: deletes[0].body, as: UTF8.self)
            .contains("path=%2FPushed%20Books%2FBook.epub"))
    }

    func testConnectionLevelUploadFailureThrowsUnreachable() async {
        let host = "e.local"
        XteinkStubProtocol.connectionFailures["\(host)/edit"] = .cannotConnectToHost

        do {
            try await client.uploadBook(Data("x".utf8), fileName: "Book.epub", host: host)
            XCTFail("A dead connection must throw")
        } catch is XteinkDeviceClient.UnreachableError {
            // An asleep device defers the send instead of failing it.
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    // MARK: - Transfer queue

    /// Counts how many operations run at once, to pin serialization.
    private actor OverlapCounter {
        private var active = 0
        private(set) var maxConcurrent = 0
        func enter() {
            active += 1
            maxConcurrent = max(maxConcurrent, active)
        }
        func exit() { active -= 1 }
    }

    func testTransferQueueSerializesOperationsAndSharesOneProbe() async throws {
        stubStatus(host: "e.local", deviceType: "ESP32-C3")
        let queue = XteinkTransferQueue()
        let counter = OverlapCounter()
        let transfer: @Sendable (String) async throws -> Void = { _ in
            await counter.enter()
            // A window wide enough that a second, wrongly-parallel transfer
            // would be observed inside it.
            try? await Task.sleep(nanoseconds: 50_000_000)
            await counter.exit()
        }
        async let first: Void = queue.run(client: client, hosts: ["e.local"], transfer)
        async let second: Void = queue.run(client: client, hosts: ["e.local"], transfer)
        _ = try await (first, second)

        let maxConcurrent = await counter.maxConcurrent
        XCTAssertEqual(maxConcurrent, 1)
        XCTAssertEqual(
            XteinkStubProtocol.requests { $0.url.path == "/status" }.count, 1,
            "Transfers behind one probe answer must not probe again")
    }

    func testTransferQueueCachesNegativeProbeAcrossASweep() async {
        // No stub answers: every probe dies on connection.
        let queue = XteinkTransferQueue()
        for _ in 0..<3 {
            do {
                try await queue.run(client: client, hosts: ["gone.local"]) { _ in }
                XCTFail("An absent device must throw")
            } catch is XteinkDeviceClient.UnreachableError {
            } catch {
                XCTFail("Wrong error: \(error)")
            }
        }
        XCTAssertEqual(
            XteinkStubProtocol.requests { $0.url.path == "/status" }.count, 1,
            "A sweep against an absent device costs one probe, not one per item")
    }
}
