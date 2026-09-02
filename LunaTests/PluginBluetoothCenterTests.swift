//
//  PluginBluetoothCenterTests.swift
//  LunaTests
//

import LunaPluginKit
import LunaPluginTransport
import LunaStorage
import XCTest

/// The radio's behaviour: what the center does with a link, and the two
/// guarantees §10.4 puts around an `onBluetooth` invocation.
final class PluginBluetoothCenterTests: XCTestCase {

    private var containerURL: URL!
    private var lockFileURL: URL!
    private var kv: PluginKVStore!
    private var previousSettings: (any PluginSettingsStoring)?
    private var maker: FakePluginTransportMaker!
    private var invoker: RecordingPluginInvoker!

    private let pluginID = "test.plugin.radio"
    private let serviceUUID = "6F9F0A00-9B1D-4D1F-9F53-5B6B8B3D0F10"
    private let device = PluginBluetoothDevice(
        id: "11111111-2222-3333-4444-555555555555", name: "Reader", serviceUUIDs: [])

    override func setUp() {
        super.setUp()
        containerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("radio-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: containerURL, withIntermediateDirectories: true)
        lockFileURL = containerURL.appendingPathComponent("service.lock")
        kv = PluginKVStore(fileURL: containerURL.appendingPathComponent("saves.sqlite"))
        previousSettings = PluginPlatformServices.settings
        PluginPlatformServices.settings = kv
        maker = FakePluginTransportMaker(lockFileURL: lockFileURL)
        invoker = RecordingPluginInvoker()
        invoker.rivalLockFileURL = lockFileURL
    }

    override func tearDown() {
        PluginPlatformServices.settings = previousSettings
        try? FileManager.default.removeItem(at: containerURL)
        super.tearDown()
    }

    private func makeCenter(
        standingConnect: Bool = true, settingFields: [PluginSettingField] = []
    ) -> PluginBluetoothCenter {
        PluginBluetoothCenter(
            pluginID: pluginID,
            declaration: PluginBluetoothDeclaration(
                services: [serviceUUID], pairing: .accessorySetupKit,
                standingConnect: standingConnect),
            makers: maker,
            pairedDevices: PluginPairedDeviceStore(store: kv),
            pairedDeviceSettingKey: "device",
            settingFields: settingFields,
            invoker: invoker)
    }

    private func waitUntil(
        _ description: String, timeout: TimeInterval = 3, _ condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("\(description) did not happen within \(timeout)s")
    }

    // MARK: - Event dispatch

    /// A `connected` link is one `onBluetooth` invocation, and the service lock
    /// is held for the WHOLE of it — that is what stops the sibling Luna app
    /// sweeping the same window. The background lease is balanced.
    func testConnectedInvokesTheHookUnderTheServiceLockAndABackgroundLease() {
        let center = makeCenter()
        center.start()
        invoker.hookDuration = 0.05
        maker.transport.fireConnect(device)

        waitUntil("the hook ran") { self.invoker.hooks.count == 1 }
        XCTAssertEqual(invoker.hooks, [.onBluetooth])
        XCTAssertEqual(invoker.eventTypes, ["connected"])
        XCTAssertEqual(
            invoker.lockWasFreeDuringHook, [false],
            "another process must not be able to take the lock while the hook runs")
        XCTAssertEqual(maker.lease.begun.count, 1)
        waitUntil("the lease ended") { self.maker.lease.isBalanced }
        XCTAssertNil(center.liveSession, "the session closes with the invocation")
        // The lock is free again for the next window.
        let rival = BluetoothServiceLock(fileURL: lockFileURL)
        waitUntil("the lock was released") { rival.acquire() }
        rival.release()
    }

    /// A process that loses the lock stays completely silent. It must not even
    /// answer the device: the owner concludes the window.
    func testALostLockInvokesNothing() {
        let owner = BluetoothServiceLock(fileURL: lockFileURL)
        XCTAssertTrue(owner.acquire())
        defer { owner.release() }
        let center = makeCenter()
        center.start()
        maker.transport.fireConnect(device)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(invoker.hooks.isEmpty)
        XCTAssertTrue(maker.lease.begun.isEmpty, "a silent process takes no lease either")
        XCTAssertNotNil(center)
    }

    /// A disconnect is reported too, so a plugin can stand its status dot down.
    /// It takes no lock: there is no window left to arbitrate.
    func testDisconnectInvokesTheHookWithoutTheLock() {
        let center = makeCenter(standingConnect: false)
        center.start()
        maker.transport.fireDisconnect(device, error: "link lost")
        waitUntil("the hook ran") { self.invoker.hooks.count == 1 }
        XCTAssertEqual(invoker.eventTypes, ["disconnected"])
        XCTAssertEqual(invoker.lockWasFreeDuringHook, [true])
        XCTAssertNotNil(center)
    }

    // MARK: - The radio gate

    /// A scan is what raises the system Bluetooth prompt, so a plugin whose
    /// required settings are unfilled must never open one.
    func testAnUnconfiguredPluginOpensNoScan() {
        let fields = [
            PluginSettingField(key: "device", type: .pairedDevice, label: "Reader", isRequired: true)
        ]
        let center = makeCenter(settingFields: fields)
        XCTAssertFalse(center.isPermittedToStart)
        try? kv.setValueJSON("\"Reader\"", pluginID: pluginID, key: "device")
        XCTAssertTrue(center.isPermittedToStart)
    }

    func testAnEnabledToggleTurnedOffStandsTheRadioDown() {
        let fields = [
            PluginSettingField(key: "enabled", type: .toggle, label: "On", defaultJSON: "false")
        ]
        let center = makeCenter(settingFields: fields)
        XCTAssertFalse(center.isPermittedToStart)
        try? kv.setValueJSON("true", pluginID: pluginID, key: "enabled")
        XCTAssertTrue(center.isPermittedToStart)
    }

    /// The standing connect is what saves a short wake window: CoreBluetooth
    /// keeps a pending connect open and completes it the instant the device
    /// advertises, so no scan-discovery race can lose the window.
    func testStartOpensAStandingConnectToEveryPairedDeviceThenScans() {
        let store = PluginPairedDeviceStore(store: kv)
        store.add(device, pluginID: pluginID, settingKey: "device")
        let center = makeCenter()
        center.start()
        XCTAssertEqual(
            maker.transport.calls,
            ["connect(\(device.id))", "startScan(\(serviceUUID))"])
    }

    // MARK: - Pairing

    /// The picker cannot appear while the process holds any live CBManager
    /// (ASErrorDomain 550), and it never lists an accessory it considers
    /// already set up. So the order is fixed, and the manager comes back on
    /// every exit path.
    func testPairStandsDownPriorAuthorizationsAndTheManagerAroundThePicker() {
        maker.pairing.answer = .success(device)
        let center = makeCenter()
        let paired = expectation(description: "paired")
        center.pair(displayName: "Reader") { result in
            XCTAssertEqual(try? result.get(), self.device)
            paired.fulfill()
        }
        wait(for: [paired], timeout: 3)
        XCTAssertEqual(
            maker.transport.calls.prefix(4).map { $0 },
            ["removeSetUpAccessories", "release", "showPicker", "rebuild"])
        XCTAssertEqual(
            PluginPairedDeviceStore(store: kv).devices(pluginID: pluginID), [device],
            "the pairing survives the plugin's context")
    }

    /// A dismissed picker still rebuilds the manager, or the app would be left
    /// with no radio at all.
    func testACancelledPickerRebuildsTheManager() {
        maker.pairing.answer = .success(nil)
        let center = makeCenter()
        let done = expectation(description: "answered")
        center.pair(displayName: "Reader") { result in
            XCTAssertNil(try? result.get() ?? nil)
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        XCTAssertTrue(maker.transport.calls.contains("rebuild"))
    }

    func testUnpairClearsTheStoredDeviceAndTheAuthorization() {
        let store = PluginPairedDeviceStore(store: kv)
        store.add(device, pluginID: pluginID, settingKey: "device")
        let center = makeCenter()
        let done = expectation(description: "unpaired")
        center.unpair(deviceID: device.id) { done.fulfill() }
        wait(for: [done], timeout: 3)
        XCTAssertTrue(store.devices(pluginID: pluginID).isEmpty)
        XCTAssertEqual(maker.pairing.removedAccessories, [device.id])
        XCTAssertNil(kv.valueJSON(pluginID: pluginID, key: "device"))
    }
}
