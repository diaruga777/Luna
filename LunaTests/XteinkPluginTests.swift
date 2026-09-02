//
//  XteinkPluginTests.swift
//  LunaTests
//

import CryptoKit
import Foundation
import LunaPluginKit
import LunaPluginRuntime
import LunaPluginTransport
import LunaPluginUI
import LunaSend
import LunaStorage
import XCTest

/// The bundled `xteink.js` end to end (`claudedocs/plans/plugin-platform.md`
/// §10.5), against a fake X3 reader that speaks the real CrossPoint protocol.
///
/// The chain under test is production: the shipped runtime and bridges through
/// `PluginJSFixtureRunner`, the shipped `luna.bluetooth` center and session,
/// and the shipped plugin file. Only the radio, the Wi-Fi stack and agent 3A's
/// `luna.exports` / `luna.notifications` are fakes.
///
/// The parity target is `claudedocs/xteink.md`: Luna Reader keeps the Swift
/// path, so a behaviour that differs here is a behaviour that differs between
/// two apps talking to one reader.
final class XteinkPluginTests: XCTestCase {

    private var runner: PluginJSFixtureRunner!
    private var maker: FakeXteinkTransportMaker!
    private var joiner: FakePluginWiFiJoiner!
    private var exports: FakePluginExportsBridge!
    private var notifications: FakePluginNotificationsBridge!
    private var centers: PluginBluetoothCenterStore!
    private var previousSettings: (any PluginSettingsStoring)?

    private let pluginID = "app.luna.xteink"
    private let hostID = "luna-ios"
    private let secret = "8f14e45fceea167a5a36dedd4bea2543"
    private let device = PluginBluetoothDevice(
        id: "DEADBEEF-0000-1111-2222-333344445555", name: "Xteink X3", serviceUUIDs: [])

    override func setUpWithError() throws {
        try super.setUpWithError()
        runner = PluginJSFixtureRunner()
        previousSettings = PluginPlatformServices.settings
        PluginPlatformServices.settings = runner.kv
        maker = FakeXteinkTransportMaker(
            lockFileURL: runner.containerURL.appendingPathComponent("service.lock"))
        joiner = FakePluginWiFiJoiner()
        exports = FakePluginExportsBridge(
            scheduler: runner.runtime, invoker: runner.runtime, pluginID: pluginID)
        notifications = FakePluginNotificationsBridge(scheduler: runner.runtime)
        centers = PluginBluetoothCenterStore(
            makers: maker, pairedDevices: PluginPairedDeviceStore(store: runner.kv),
            invoker: runner.runtime)
        runner.capabilities.register(PluginBluetoothBridge(
            processKind: .app, scheduler: runner.runtime, centers: centers))
        runner.capabilities.register(PluginWiFiBridge(
            processKind: .app, scheduler: runner.runtime, joiner: joiner))
        runner.capabilities.register(PluginSettingsBridge(
            processKind: .app, scheduler: runner.runtime))
        runner.capabilities.register(exports)
        runner.capabilities.register(notifications)

        PluginSecretsStore.shared.setSecret(secret, pluginID: pluginID, key: "pairingSecret")
        let source = try String(
            contentsOf: MediaPluginHarness.pluginsDirectory
                .appendingPathComponent("xteink.js"), encoding: .utf8)
        try runner.load(source)
        XCTAssertEqual(runner.runtime.loadedPlugins.first?.id, pluginID)
    }

    override func tearDown() {
        PluginSecretsStore.shared.removeSecret(pluginID: pluginID, key: "pairingSecret")
        PluginPlatformServices.settings = previousSettings
        runner?.cleanUp()
        super.tearDown()
    }

    // MARK: - Helpers

    /// Writes an EPUB into the plugin's scratch store and queues it for
    /// delivery, the way agent 3A's export stage will.
    @discardableResult
    private func queueSend(
        bytes: Int, saveID: String = "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
        queuedRemaining: Int = 3
    ) throws -> Data {
        let data = Data((0..<bytes).map { UInt8($0 % 251) })
        let descriptor = try runner.scratch.writeFile(
            data, suggestedName: "Article.epub", mime: "application/epub+zip",
            invocationID: "fixture")
        exports.queued.append(FakePluginExportsBridge.QueuedSend(
            saveId: saveID, url: "https://example.com/article", title: "An Article",
            file: .init(
                id: descriptor.id, name: descriptor.name, size: descriptor.size,
                mime: "application/epub+zip"),
            queuedRemaining: queuedRemaining))
        return data
    }

    /// Opens a rendezvous and waits for the sweep to conclude the window.
    private func runRendezvous(
        timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let center = centers.existingCenter(pluginID: pluginID) else {
            return XCTFail("the bluetooth bridge built no center", file: file, line: line)
        }
        center.start()
        maker.transport.fireConnect(device)
        runner.awaitCondition(
            "the sweep concluded the window", timeout: timeout, file: file, line: line
        ) { self.maker.transport.operationNames.contains("no_work") }
    }

    private var chunkSize: Int { maker.transport.writeLength - 4 }

    // MARK: - Authentication

    /// The hello HMAC must equal what the Swift path computes for the same
    /// nonce, host id and secret: the reader stores ONE trusted host, and Luna
    /// Reader still authenticates with the Swift copy.
    func testTheHelloHMACEqualsTheSwiftComputation() throws {
        runRendezvous()
        let hello = try XCTUnwrap(maker.transport.operation("hello"))
        XCTAssertEqual(hello["host_id"] as? String, hostID)
        XCTAssertEqual(hello["version"] as? Int, 1)
        XCTAssertNil(hello["pair_secret"], "an authenticated hello carries no secret")

        let message = Data("\(maker.transport.nonce)|\(hostID)|1".utf8)
        let expected = HMAC<SHA256>
            .authenticationCode(for: message, using: SymmetricKey(data: Data(secret.utf8)))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hello["response"] as? String, expected)
    }

    /// Without a secret the plugin never authenticates, so it never occupies a
    /// window as a client that cannot prove itself.
    func testNoPairingSecretMeansNoAuthenticatedHello() {
        PluginSecretsStore.shared.removeSecret(pluginID: pluginID, key: "pairingSecret")
        guard let center = centers.existingCenter(pluginID: pluginID) else {
            return XCTFail("no center")
        }
        center.start()
        maker.transport.fireConnect(device)
        runner.awaitCondition("the plugin gave up") { self.maker.transport.operation("hello") == nil }
        XCTAssertTrue(maker.transport.operationNames.isEmpty)
    }

    // MARK: - The BLE transfer

    /// A book at or under 200 KiB goes over BLE frames, and the stream stays
    /// inside the reader's own confirmation stride. An unpaced stream outruns
    /// the X3's SD writes and starves its allocator.
    func testASmallEpubGoesOverBLEFramesPacedToTheReadersCheckpointStride() throws {
        let epub = try queueSend(bytes: 20 * 1024)
        runRendezvous()

        XCTAssertEqual(exports.results, ["sent"])
        XCTAssertEqual(maker.transport.assembled, epub, "the reader assembled the whole book")
        XCTAssertEqual(
            maker.transport.operationNames,
            ["hello", "start_put", "commit", "no_work"])
        let ceiling = maker.transport.checkpointIntervalBytes + 1024 + chunkSize
        XCTAssertLessThanOrEqual(
            maker.transport.maximumUnconfirmedBytes, ceiling,
            "the sender must stay within one checkpoint interval plus its margin")
    }

    /// `article_id` and `queue_remaining` ride along on `start_put` so the
    /// reader can show "book i of n". An older reader ignores them.
    func testStartPutCarriesTheArticleIDAndTheRemainingQueue() throws {
        let saveID = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
        try queueSend(bytes: 4096, saveID: saveID, queuedRemaining: 2)
        runRendezvous()
        let startPut = try XCTUnwrap(maker.transport.operation("start_put"))
        XCTAssertEqual(startPut["article_id"] as? String, saveID.lowercased())
        XCTAssertEqual(startPut["queue_remaining"] as? Int, 2)
        XCTAssertEqual(startPut["resume"] as? Bool, true)
        XCTAssertEqual(startPut["chunk_size"] as? Int, chunkSize)
    }

    /// The reader refuses to overwrite a file already in /Books, so the book
    /// IS on the device: a retry could only fail the same way.
    func testStartPutAnsweredWithExistsCountsAsDelivered() throws {
        maker.transport.startPutError = "exists"
        try queueSend(bytes: 4096)
        runRendezvous()
        XCTAssertEqual(exports.results, ["sent"])
    }

    // MARK: - The Wi-Fi transfer

    /// A larger book asks the reader for a network and uploads over it. The
    /// custom fork offers its own access point by default, so a remembered but
    /// unreachable home network cannot strand a travelling phone.
    func testALargeEpubRequestsWiFiJoinsTheAccessPointAndUploadsMultipart() throws {
        maker.transport.wifiOffer = [
            "mode": "ap", "ssid": "CrossPoint-X3", "password": "sekrit", "ip": "192.168.4.1",
        ]
        runner.fetcher.respond(
            to: "http://192.168.4.1/upload?path=/Books", status: 200, body: "ok")
        let epub = try queueSend(bytes: 210 * 1024)
        runRendezvous()

        XCTAssertEqual(exports.results, ["sent"])
        XCTAssertTrue(maker.transport.assembled.isEmpty, "no book goes over BLE")
        XCTAssertEqual(maker.transport.operation("wifi_request")?["prefer_ap"] as? Bool, true)
        XCTAssertEqual(joiner.joined.first?.ssid, "CrossPoint-X3")
        XCTAssertEqual(joiner.joined.first?.passphrase, "sekrit")
        XCTAssertEqual(
            joiner.forgotten, ["CrossPoint-X3"],
            "the configuration is removed so the phone rejoins its own network")

        let upload = try XCTUnwrap(runner.fetcher.requests.last)
        XCTAssertEqual(upload.method, "POST")
        XCTAssertEqual(
            upload.url.absoluteString, "http://192.168.4.1/upload?path=/Books")
        let body = try XCTUnwrap(upload.body)
        XCTAssertTrue(body.count > epub.count, "the multipart body carries the whole book")
        XCTAssertTrue(
            body.range(of: Data("filename=\"Article.epub\"".utf8)) != nil,
            "the reader's filename validator gets an ASCII basename")
        XCTAssertTrue(body.range(of: epub) != nil, "the EPUB bytes are in the body")
    }

    /// iOS joins a network only in the foreground. A background offer becomes
    /// a local notification and the send stays queued.
    func testABackgroundAccessPointOfferPostsANotificationAndStaysQueued() throws {
        joiner.isForeground = false
        maker.transport.wifiOffer = [
            "mode": "ap", "ssid": "CrossPoint-X3", "password": "sekrit", "ip": "192.168.4.1",
        ]
        try queueSend(bytes: 210 * 1024)
        runRendezvous()
        XCTAssertEqual(exports.results, ["retry"])
        XCTAssertEqual(notifications.postedTitles, ["Xteink is ready"])
        XCTAssertTrue(joiner.joined.isEmpty)
    }

    /// A station offer needs no join at all: the phone is already on that
    /// network.
    func testAStationOfferUploadsWithoutJoiningAnything() throws {
        maker.transport.wifiOffer = ["mode": "sta", "ip": "10.0.0.42"]
        runner.fetcher.respond(
            to: "http://10.0.0.42/upload?path=/Books", status: 200, body: "ok")
        try queueSend(bytes: 210 * 1024)
        runRendezvous()
        XCTAssertEqual(exports.results, ["sent"])
        XCTAssertTrue(joiner.joined.isEmpty)
        XCTAssertTrue(joiner.forgotten.isEmpty)
        XCTAssertEqual(
            runner.fetcher.requests.last?.url.absoluteString,
            "http://10.0.0.42/upload?path=/Books")
    }

    func testANonSuccessUploadIsAFailedSend() throws {
        maker.transport.wifiOffer = ["mode": "sta", "ip": "10.0.0.42"]
        runner.fetcher.respond(
            to: "http://10.0.0.42/upload?path=/Books", status: 500, body: "no")
        try queueSend(bytes: 210 * 1024)
        runRendezvous()
        XCTAssertEqual(exports.results, ["failed"])
    }

    // MARK: - Enqueue-only

    /// A share-row tap runs `export` with no window open. It must answer
    /// `retry`, which keeps the item queued at no retry cost — the reader is
    /// what opens the window.
    func testExportWithoutALiveSessionAnswersRetry() async throws {
        let data = Data(repeating: 7, count: 2048)
        let descriptor = try runner.scratch.writeFile(
            data, suggestedName: "Article.epub", mime: "application/epub+zip",
            invocationID: "fixture")
        let send = FakePluginExportsBridge.QueuedSend(
            saveId: "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
            url: "https://example.com/a", title: "An Article",
            file: .init(
                id: descriptor.id, name: descriptor.name, size: descriptor.size,
                mime: "application/epub+zip"),
            queuedRemaining: 0)
        let answer = await runner.invoke(
            .export, pluginID: pluginID, argument: send, timeout: 10,
            as: FakePluginExportsBridge.ExportAnswer?.self)
        XCTAssertEqual(answer??.status, "retry")
        XCTAssertTrue(maker.transport.operationNames.isEmpty, "nothing is put on the wire")
    }

    // MARK: - Reconciliation

    /// The reader hands back the ids it finished reading. Luna clears those
    /// sends so a finished book is never delivered again, and acks so the
    /// reader stops re-reporting them.
    func testTheReadersFinishedIDsAreMarkedSentAndAcked() throws {
        let ids = ["3f2504e0-4f89-11d3-9a0c-0305e82c3301",
                   "b1c2d3e4-f5a6-4b7c-8d9e-0f1a2b3c4d5e"]
        maker.transport.readIDs = ids
        runRendezvous()
        XCTAssertEqual(exports.sentIDs, ids)
        let ack = try XCTUnwrap(maker.transport.operation("read_ack"))
        XCTAssertEqual(ack["ids"] as? [String], ids)
    }

    /// A read-report window exists purely to hand ids back. It has no send
    /// capacity, so the sweep only answers `no_work` and the reader closes it
    /// instead of idling to its cap.
    func testAReadReportWindowOnlyAnswersNoWork() throws {
        maker.transport.isReadReportWindow = true
        maker.transport.readIDs = ["3f2504e0-4f89-11d3-9a0c-0305e82c3301"]
        try queueSend(bytes: 4096)
        runner.kv.putDocument(
            PluginCollectionDocument(id: "old", json: "{\"remoteName\":\"Old.epub\"}"),
            collection: "pendingDeletes", pluginID: pluginID)
        runRendezvous()
        XCTAssertEqual(maker.transport.operationNames, ["hello", "read_ack", "no_work"])
        XCTAssertTrue(exports.results.isEmpty, "no book is delivered in a read-report window")
    }

    /// A pending delete is not gated behind "is there also a send": the delete
    /// op is cheap and the reader is already awake for it.
    func testAPendingDeleteIsDrainedBeforeAnyDelivery() throws {
        runner.kv.putDocument(
            PluginCollectionDocument(id: "gone", json: "{\"remoteName\":\"Read.epub\"}"),
            collection: "pendingDeletes", pluginID: pluginID)
        try queueSend(bytes: 4096)
        runRendezvous()
        XCTAssertEqual(
            maker.transport.operationNames,
            ["hello", "delete", "start_put", "commit", "no_work"],
            "one hello per window: `export` inherits the rendezvous's link")
        XCTAssertEqual(maker.transport.operation("delete")?["name"] as? String, "Read.epub")
        XCTAssertNil(
            runner.kv.document(id: "gone", collection: "pendingDeletes", pluginID: pluginID),
            "a drained delete is not retried next window")
    }

    /// A delivery records the exact basename that went on the wire, so a later
    /// remote delete can target the same file.
    func testADeliveryRecordsTheRemoteName() throws {
        let saveID = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
        try queueSend(bytes: 4096, saveID: saveID)
        runRendezvous()
        let recorded = runner.kv.document(
            id: saveID, collection: "deliveries", pluginID: pluginID)
        XCTAssertNotNil(recorded)
        XCTAssertTrue(recorded?.json.contains("Article.epub") == true)
    }

    /// The rendezvous dot follows the link.
    func testTheStatusSettingFollowsTheLink() throws {
        runRendezvous()
        XCTAssertEqual(runner.kv.valueJSON(pluginID: pluginID, key: "_status"), "\"live\"")
        maker.transport.fireDisconnect(device)
        runner.awaitCondition("the status stood down") {
            self.runner.kv.valueJSON(pluginID: self.pluginID, key: "_status") == "\"off\""
        }
    }
}

extension FakeXteinkReaderTransport {
    func fireDisconnect(_ device: PluginBluetoothDevice) {
        transportDelegate?.bluetoothTransportDidDisconnect(device, error: nil)
    }
}

/// The one-time move of the Swift Xteink pairing into the plugin's own state.
final class XteinkPluginMigrationTests: XCTestCase {

    private final class InMemoryPairingStore: XteinkPairingStoring {
        private let lock = NSLock()
        private var credentials: [String: String] = [:]
        init(_ credentials: [String: String]) { self.credentials = credentials }
        func credential(for deviceID: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            return credentials[deviceID]
        }
        func save(_ credential: String, for deviceID: String) {
            lock.lock(); credentials[deviceID] = credential; lock.unlock()
        }
        func removeCredential(for deviceID: String) {
            lock.lock(); credentials[deviceID] = nil; lock.unlock()
        }
    }

    private var containerURL: URL!
    private var kv: PluginKVStore!
    private var previousSettings: (any PluginSettingsStoring)?
    private let pluginID = "app.luna.xteink"

    override func setUp() {
        super.setUp()
        containerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("xteink-migration-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: containerURL, withIntermediateDirectories: true)
        kv = PluginKVStore(fileURL: containerURL.appendingPathComponent("saves.sqlite"))
        previousSettings = PluginPlatformServices.settings
        PluginPlatformServices.settings = kv
    }

    override func tearDown() {
        PluginPlatformServices.settings = previousSettings
        PluginSecretsStore.shared.removeSecret(pluginID: pluginID, key: "pairingSecret")
        XteinkSendSettings.pairedPeripheralID = nil
        try? FileManager.default.removeItem(at: containerURL)
        super.tearDown()
    }

    /// A user who already paired a reader must not be asked to pair again: the
    /// secret is a Keychain item under a service the plugin cannot read, and
    /// the peripheral identifier lives in the App-Group defaults.
    func testTheSwiftPairingReachesThePluginAndRunsOnce() {
        let identifier = "CAFEBABE-0000-1111-2222-333344445555"
        XteinkSendSettings.pairedPeripheralID = identifier
        let devices = PluginPairedDeviceStore(store: kv)
        PluginTransportComposition.install(
            keyValueStore: kv,
            pairingStore: InMemoryPairingStore(["luna-ios": "the-secret"]),
            pairedDevices: devices)

        XCTAssertEqual(
            PluginSecretsStore.shared.secret(pluginID: pluginID, key: "pairingSecret"),
            "the-secret")
        XCTAssertEqual(devices.devices(pluginID: pluginID).map(\.id), [identifier])
        XCTAssertNotNil(kv.valueJSON(pluginID: pluginID, key: "device"))

        // A second run must not overwrite what the plugin has since changed.
        PluginSecretsStore.shared.setSecret(
            "a-newer-secret", pluginID: pluginID, key: "pairingSecret")
        PluginTransportComposition.install(
            keyValueStore: kv,
            pairingStore: InMemoryPairingStore(["luna-ios": "the-secret"]),
            pairedDevices: devices)
        XCTAssertEqual(
            PluginSecretsStore.shared.secret(pluginID: pluginID, key: "pairingSecret"),
            "a-newer-secret")
    }
}
