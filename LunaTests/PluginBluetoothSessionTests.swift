//
//  PluginBluetoothSessionTests.swift
//  LunaTests
//

import LunaPluginKit
import LunaPluginTransport
import LunaStorage
import XCTest

/// `BluetoothSession`'s semantics (§10.2): one call at a time, notifications
/// buffered from `subscribe`, and a disconnect that rejects rather than hangs.
final class PluginBluetoothSessionTests: XCTestCase {

    private var containerURL: URL!
    private var kv: PluginKVStore!
    private var previousSettings: (any PluginSettingsStoring)?
    private var maker: FakePluginTransportMaker!
    private var center: PluginBluetoothCenter!

    private let pluginID = "test.plugin.session"
    private let serviceUUID = "6F9F0A00-9B1D-4D1F-9F53-5B6B8B3D0F10"
    private let statusUUID = "6F9F0A03-9B1D-4D1F-9F53-5B6B8B3D0F10"
    private let device = PluginBluetoothDevice(
        id: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", name: "Reader", serviceUUIDs: [])

    override func setUp() {
        super.setUp()
        containerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: containerURL, withIntermediateDirectories: true)
        kv = PluginKVStore(fileURL: containerURL.appendingPathComponent("saves.sqlite"))
        previousSettings = PluginPlatformServices.settings
        PluginPlatformServices.settings = kv
        maker = FakePluginTransportMaker(
            lockFileURL: containerURL.appendingPathComponent("service.lock"))
        center = PluginBluetoothCenter(
            pluginID: pluginID,
            declaration: PluginBluetoothDeclaration(
                services: [serviceUUID], pairing: .none, standingConnect: false),
            makers: maker,
            pairedDevices: PluginPairedDeviceStore(store: kv),
            invoker: RecordingPluginInvoker())
    }

    override func tearDown() {
        PluginBluetoothSession.readyToWriteTimeout = 5
        PluginPlatformServices.settings = previousSettings
        try? FileManager.default.removeItem(at: containerURL)
        super.tearDown()
    }

    /// A foreground `connect` hands its caller the session and leaves it open:
    /// the caller is a user action in this app, not a sweep.
    private func openSession() -> PluginBluetoothSession {
        var session: PluginBluetoothSession?
        let opened = expectation(description: "connected")
        center.connect(deviceID: device.id, timeout: 2) { result in
            session = try? result.get()
            opened.fulfill()
        }
        maker.transport.fireConnect(device)
        wait(for: [opened], timeout: 3)
        guard let session else {
            XCTFail("no session")
            fatalError("no session")
        }
        return session
    }

    private func pump(_ seconds: TimeInterval = 0.05) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: - Serialization

    /// One device accepts one operation at a time, so a second call waits
    /// rather than interleaving. The device rejects an interleaved transfer;
    /// Luna must not produce one.
    func testASecondCallWaitsForTheFirstToSettle() {
        let session = openSession()
        maker.transport.defersReads = true
        var first: String?
        var second: String?
        session.read(characteristicUUID: statusUUID) { first = try? $0.get() }
        session.read(characteristicUUID: statusUUID) { second = try? $0.get() }
        pump()
        XCTAssertEqual(maker.transport.parkedReadCount, 1, "only one read is in flight")
        maker.transport.answerRead("Zmlyc3Q=")
        pump()
        XCTAssertEqual(first, "Zmlyc3Q=")
        XCTAssertNil(second)
        XCTAssertEqual(maker.transport.parkedReadCount, 1, "the second read started after")
        maker.transport.answerRead("c2Vjb25k")
        pump()
        XCTAssertEqual(second, "c2Vjb25k")
    }

    /// A dropped link rejects every queued and in-flight call. A pending
    /// promise that never settles would hang the plugin for the process's life.
    func testADisconnectRejectsEveryPendingCall() {
        let session = openSession()
        maker.transport.defersReads = true
        var codes: [String] = []
        session.read(characteristicUUID: statusUUID) { result in
            if case .failure(let error) = result { codes.append(error.code) }
        }
        session.read(characteristicUUID: statusUUID) { result in
            if case .failure(let error) = result { codes.append(error.code) }
        }
        pump()
        maker.transport.fireDisconnect(device)
        pump()
        XCTAssertEqual(codes, ["disconnected", "disconnected"])
        XCTAssertFalse(session.isLive)
    }

    func testACallAfterTheLinkDroppedRejectsAtOnce() {
        let session = openSession()
        maker.transport.fireDisconnect(device)
        pump()
        var code: String?
        session.read(characteristicUUID: statusUUID) { result in
            if case .failure(let error) = result { code = error.code }
        }
        pump()
        XCTAssertEqual(code, "disconnected")
    }

    // MARK: - Notifications

    /// A device publishes a status when it likes. Buffering from `subscribe`
    /// means a status that arrived before the plugin asked is still delivered.
    func testNextReturnsAStatusThatArrivedBeforeItWasAskedFor() {
        let session = openSession()
        let subscribed = expectation(description: "subscribed")
        session.subscribe(characteristicUUID: statusUUID) { _ in subscribed.fulfill() }
        wait(for: [subscribed], timeout: 2)
        maker.transport.fireNotification(
            "ZWFybHk=", characteristicUUID: statusUUID, deviceID: device.id)
        var value: String?
        let received = expectation(description: "received")
        session.next(characteristicUUID: statusUUID, timeout: 1) { result in
            value = try? result.get()
            received.fulfill()
        }
        wait(for: [received], timeout: 2)
        XCTAssertEqual(value, "ZWFybHk=")
    }

    func testNextWaitsForTheNextStatusAndTimesOutWithoutOne() {
        let session = openSession()
        let subscribed = expectation(description: "subscribed")
        session.subscribe(characteristicUUID: statusUUID) { _ in subscribed.fulfill() }
        wait(for: [subscribed], timeout: 2)

        var value: String?
        let received = expectation(description: "received")
        session.next(characteristicUUID: statusUUID, timeout: 2) { result in
            value = try? result.get()
            received.fulfill()
        }
        pump()
        maker.transport.fireNotification(
            "bGF0ZQ==", characteristicUUID: statusUUID, deviceID: device.id)
        wait(for: [received], timeout: 3)
        XCTAssertEqual(value, "bGF0ZQ==")

        var code: String?
        let timedOut = expectation(description: "timed out")
        session.next(characteristicUUID: statusUUID, timeout: 0.2) { result in
            if case .failure(let error) = result { code = error.code }
            timedOut.fulfill()
        }
        wait(for: [timedOut], timeout: 3)
        XCTAssertEqual(code, "timed-out")
    }

    /// A plugin writes whichever spelling of a UUID it likes and the peripheral
    /// publishes its own. Both sides key through one normalisation, or a
    /// notification silently reaches no waiter at all.
    func testANotificationMatchesTheSpellingThePluginSubscribedWith() {
        let session = openSession()
        let subscribed = expectation(description: "subscribed")
        session.subscribe(characteristicUUID: statusUUID.lowercased()) { _ in
            subscribed.fulfill()
        }
        wait(for: [subscribed], timeout: 2)

        var value: String?
        let received = expectation(description: "received")
        session.next(characteristicUUID: statusUUID.lowercased(), timeout: 2) { result in
            value = try? result.get()
            received.fulfill()
        }
        pump()
        maker.transport.fireNotification(
            "c3BlbGxpbmc=", characteristicUUID: statusUUID, deviceID: device.id)
        wait(for: [received], timeout: 3)
        XCTAssertEqual(value, "c3BlbGxpbmc=")
    }

    /// The timeout of a `next` that was already answered must not cancel the
    /// waiter of the `next` that followed it — inside a 15 s control loop that
    /// costs a whole wasted window.
    func testAnAnsweredNextsTimeoutLeavesTheFollowingWaiterAlone() {
        let session = openSession()
        let subscribed = expectation(description: "subscribed")
        session.subscribe(characteristicUUID: statusUUID) { _ in subscribed.fulfill() }
        wait(for: [subscribed], timeout: 2)

        let first = expectation(description: "first")
        session.next(characteristicUUID: statusUUID, timeout: 0.2) { _ in first.fulfill() }
        pump()
        maker.transport.fireNotification(
            "Zmlyc3Q=", characteristicUUID: statusUUID, deviceID: device.id)
        wait(for: [first], timeout: 2)

        var value: String?
        let second = expectation(description: "second")
        session.next(characteristicUUID: statusUUID, timeout: 5) { result in
            value = try? result.get()
            second.fulfill()
        }
        // Past the first call's deadline, so its timer has fired.
        pump(0.5)
        maker.transport.fireNotification(
            "c2Vjb25k", characteristicUUID: statusUUID, deviceID: device.id)
        wait(for: [second], timeout: 2)
        XCTAssertEqual(value, "c2Vjb25k")
    }

    // MARK: - Writes

    /// A write-without-response waits for controller room. Without that the
    /// phone drops frames the device never sees.
    func testAWriteWithoutResponseWaitsForControllerRoom() {
        let session = openSession()
        maker.transport.canWrite = false
        var written = false
        session.write(base64: "AAAA", characteristicUUID: statusUUID, withResponse: false) { _ in
            written = true
        }
        pump()
        XCTAssertFalse(written, "no room yet")
        XCTAssertTrue(maker.transport.writes.isEmpty)
        maker.transport.canWrite = true
        maker.transport.fireReadyToWrite(deviceID: device.id)
        pump()
        XCTAssertTrue(written)
        XCTAssertEqual(maker.transport.writes.first?.withResponse, false)
    }

    /// Controller room that never comes must fail the write rather than hold
    /// the queue: every other operation is behind it, and only a disconnect
    /// would ever free it.
    func testAWriteWithNoControllerRoomTimesOutAndTheQueueMovesOn() {
        PluginBluetoothSession.readyToWriteTimeout = 0.2
        let session = openSession()
        maker.transport.canWrite = false
        var code: String?
        let failed = expectation(description: "failed")
        session.write(base64: "AAAA", characteristicUUID: statusUUID, withResponse: false) {
            result in
            if case .failure(let error) = result { code = error.code }
            failed.fulfill()
        }
        wait(for: [failed], timeout: 3)
        XCTAssertEqual(code, "timed-out")
        XCTAssertTrue(maker.transport.writes.isEmpty)

        var read: String?
        let answered = expectation(description: "answered")
        session.read(characteristicUUID: statusUUID) { result in
            read = try? result.get()
            answered.fulfill()
        }
        wait(for: [answered], timeout: 3)
        XCTAssertEqual(read, "", "the next operation runs once the write gave up")
    }

    /// The device's own limit sizes a data frame, so the session reports it.
    func testTheSessionReportsTheDevicesWriteLimit() {
        maker.transport.writeLength = 244
        XCTAssertEqual(openSession().mtu, 244)
    }
}
