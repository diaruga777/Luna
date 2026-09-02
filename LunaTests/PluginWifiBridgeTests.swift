//
//  PluginWifiBridgeTests.swift
//  LunaTests
//

import LunaPluginKit
import LunaPluginRuntime
import LunaPluginTransport
import XCTest

/// `luna.wifi` (§10.3) as a plugin sees it, through an injected joiner.
final class PluginWifiBridgeTests: XCTestCase {

    private var runner: PluginJSFixtureRunner!
    private var joiner: FakePluginWiFiJoiner!

    private let pluginID = "test.plugin.wifi"

    private func source(capabilities: String = "\"wifi\"") -> String {
        """
        /* luna-plugin
        {
          "id": "\(pluginID)",
          "name": "Wi-Fi",
          "version": "1.0.0",
          "api": 1,
          "capabilities": [\(capabilities)]
        }
        */
        luna.register({
            async onAction(input) {
                const key = input && input.key;
                if (key === "join") {
                    return luna.wifi.join({ ssid: "X3-AP", passphrase: "secret", joinOnce: true });
                }
                if (key === "forget") { return luna.wifi.forget("X3-AP"); }
                if (key === "probe") {
                    return { joined: await luna.wifi.isReachable("192.168.4.1", 80) };
                }
                if (key === "joinNoSSID") { return luna.wifi.join({}); }
                return null;
            },
        });
        """
    }

    private func boot(processKind: PluginProcessKind = .app) throws {
        joiner = FakePluginWiFiJoiner()
        runner = PluginJSFixtureRunner(processKind: processKind)
        runner.capabilities.register(
            PluginWiFiBridge(
                processKind: processKind, scheduler: runner.runtime, joiner: joiner))
        try runner.load(source())
    }

    override func tearDown() {
        runner?.cleanUp()
        // XCTest keeps every test-case instance alive for the whole run, so a
        // fixture left in a property outlives its test. The runner owns a
        // JSVirtualMachine; a run's worth of them exhausts JavaScriptCore.
        runner = nil
        joiner = nil
        super.tearDown()
    }

    private func call(_ key: String) async -> PluginInvocationFailure? {
        await runner.runtime.invoke(
            .onAction, pluginID: pluginID, argument: ActionArgument(key: key),
            timeout: 5, decode: JoinAnswer?.self
        ).failureOrNil
    }

    private struct ActionArgument: Encodable { let key: String }
    private struct JoinAnswer: Decodable { let joined: Bool? }

    func testJoinReachesTheJoinerWithTheDeclaredNetwork() async throws {
        try boot()
        let joinFailure = await call("join")
        XCTAssertNil(joinFailure)
        XCTAssertEqual(joiner.joined.count, 1)
        XCTAssertEqual(joiner.joined.first?.ssid, "X3-AP")
        XCTAssertEqual(joiner.joined.first?.passphrase, "secret")
        XCTAssertEqual(joiner.joined.first?.joinOnce, true)
    }

    /// iOS applies a hotspot configuration only in the foreground. The bridge
    /// answers that with its own code so the plugin can notify instead of
    /// guessing why the join failed.
    func testJoinInTheBackgroundRefusesWithTheBackgroundCode() async throws {
        try boot()
        joiner.isForeground = false
        let failure = await call("join")
        XCTAssertEqual(failure?.exceptionCodePrefix, "background")
        XCTAssertTrue(joiner.joined.isEmpty, "no configuration is applied")
    }

    func testForgetRemovesTheConfiguration() async throws {
        try boot()
        let forgetFailure = await call("forget")
        XCTAssertNil(forgetFailure)
        XCTAssertEqual(joiner.forgotten, ["X3-AP"])
    }

    func testIsReachableProbesTheHostAndPort() async throws {
        try boot()
        let probeFailure = await call("probe")
        XCTAssertNil(probeFailure)
        XCTAssertEqual(joiner.probes.first?.host, "192.168.4.1")
        XCTAssertEqual(joiner.probes.first?.port, 80)
    }

    func testJoinWithoutAnSSIDIsARejectedArgument() async throws {
        try boot()
        let badArgument = await call("joinNoSSID")
        XCTAssertEqual(badArgument?.exceptionCodePrefix, "bad-argument")
        XCTAssertTrue(joiner.joined.isEmpty)
    }

    // MARK: - The shipped joiner

    /// A device publishes its credentials over BLE, releases BLE, and only then
    /// brings its access point up, so the first apply can race the SSID's
    /// appearance. One re-apply after the pause is what makes the join land.
    func testAFailedJoinIsAppliedAgainAfterThePause() {
        let configurator = FakeHotspotConfigurator()
        configurator.answers = [
            .failure(PluginTransportError(code: "join-failed", message: "no such network")),
            .success(()),
        ]
        let joiner = SystemPluginWiFiJoiner(configurator: configurator, reapplyPause: 0.05)
        var failure: PluginTransportError?
        let answered = expectation(description: "answered")
        joiner.join(ssid: "X3-AP", passphrase: "secret", joinOnce: true) { result in
            if case .failure(let error) = result { failure = error }
            answered.fulfill()
        }
        wait(for: [answered], timeout: 3)
        XCTAssertNil(failure, "the second apply answers the join")
        XCTAssertEqual(configurator.applyCount, 2)
        XCTAssertEqual(configurator.applied.last?.ssid, "X3-AP")
        XCTAssertEqual(configurator.applied.last?.passphrase, "secret")
    }

    func testAJoinThatLandsFirstTimeIsNotAppliedTwice() {
        let configurator = FakeHotspotConfigurator()
        let joiner = SystemPluginWiFiJoiner(configurator: configurator, reapplyPause: 0.05)
        let answered = expectation(description: "answered")
        joiner.join(ssid: "X3-AP", passphrase: nil, joinOnce: true) { _ in answered.fulfill() }
        wait(for: [answered], timeout: 3)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(configurator.applyCount, 1)
    }

    func testForgetRemovesTheNetworkThroughTheConfigurator() {
        let configurator = FakeHotspotConfigurator()
        SystemPluginWiFiJoiner(configurator: configurator).forget(ssid: "X3-AP")
        XCTAssertEqual(configurator.removed, ["X3-AP"])
    }

    /// Two failures are the network really not being there; the plugin gets the
    /// second failure rather than a promise that never settles.
    func testAJoinThatFailsTwiceAnswersTheSecondFailure() {
        let configurator = FakeHotspotConfigurator()
        configurator.answers = [
            .failure(PluginTransportError(code: "join-failed", message: "no such network")),
        ]
        let joiner = SystemPluginWiFiJoiner(configurator: configurator, reapplyPause: 0.05)
        var code: String?
        let answered = expectation(description: "answered")
        joiner.join(ssid: "X3-AP", passphrase: nil, joinOnce: true) { result in
            if case .failure(let error) = result { code = error.code }
            answered.fulfill()
        }
        wait(for: [answered], timeout: 3)
        XCTAssertEqual(code, "join-failed")
        XCTAssertEqual(configurator.applyCount, 2)
    }

    /// Outside the app the namespace is present but every call refuses, so a
    /// plugin's declared capability stays visible and its rejection carries a
    /// code it can branch on.
    func testAShareExtensionRefusesEveryCall() async throws {
        try boot(processKind: .share)
        let refused = await call("join")
        XCTAssertEqual(refused?.exceptionCodePrefix, "unavailable-here")
        XCTAssertTrue(joiner.joined.isEmpty)
    }
}

/// A hotspot stack a test drives. Each `apply` answers the oldest unused entry
/// in `answers`; the last one repeats.
final class FakeHotspotConfigurator: PluginHotspotConfiguring, @unchecked Sendable {

    var answers: [Result<Void, PluginTransportError>] = [.success(())]

    private let lock = NSLock()
    private(set) var applied: [(ssid: String, passphrase: String?, joinOnce: Bool)] = []
    private(set) var removed: [String] = []

    func apply(
        ssid: String, passphrase: String?, joinOnce: Bool,
        completion: @escaping (Result<Void, PluginTransportError>) -> Void
    ) {
        lock.lock()
        applied.append((ssid, passphrase, joinOnce))
        let answer = answers.count > 1 ? answers.removeFirst() : (answers.first ?? .success(()))
        lock.unlock()
        completion(answer)
    }

    func remove(ssid: String) {
        lock.lock()
        removed.append(ssid)
        lock.unlock()
    }

    var applyCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return applied.count
    }
}

extension Result {
    /// The failure, for a test that asserts on one without unwrapping success.
    var failureOrNil: Failure? {
        guard case .failure(let failure) = self else { return nil }
        return failure
    }
}

extension PluginInvocationFailure {
    /// The `LunaError` code a rejected bridge call carries. `PluginContext`
    /// formats a coded rejection as "<code>: <message>".
    var exceptionCodePrefix: String? {
        guard case .exception(let message, _) = self else { return nil }
        return message.split(separator: ":").first.map(String.init)
    }
}
