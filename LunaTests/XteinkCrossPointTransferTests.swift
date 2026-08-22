//
//  XteinkCrossPointTransferTests.swift
//  LunaTests
//

import Foundation
import XCTest
@testable import LunaSend

final class XteinkCrossPointTransferTests: XCTestCase {
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
}
