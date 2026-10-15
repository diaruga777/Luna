import XCTest
import UIKit
@testable import Luna

@MainActor
final class AppLaunchServicesTests: XCTestCase {
    func testBluetoothWakeInstallsAndRestoresBeforeAnyFrame() {
        let services = AppLaunchServices()
        var events: [String] = []
        services.configure { events.append("services") }
        services.restoreBluetoothIfNeeded(
            launchOptions: [.bluetoothCentrals: ["plugin.app.luna.xteink"]]
        ) { events.append("restore central") }
        XCTAssertEqual(events, ["services", "restore central"])
        XCTAssertTrue(services.isReady)
        // A later display callback must not reinstall the plugin registry.
        services.ensureReady()
        XCTAssertEqual(events, ["services", "restore central"])
    }

    func testOrdinaryLaunchStillWaitsForItsFirstFrame() {
        for options: [UIApplication.LaunchOptionsKey: Any]? in [
            nil, [:], [.bluetoothCentrals: [String]()]
        ] {
            let services = AppLaunchServices()
            services.configure { XCTFail("foreground installation must stay deferred") }
            services.restoreBluetoothIfNeeded(launchOptions: options) {
                XCTFail("ordinary launch must not demand Bluetooth restoration")
            }
            XCTAssertFalse(services.isReady)
        }
    }

    func testRootCanBeBuiltBeforeServiceInstallation() {
        let services = AppLaunchServices()
        var events: [String] = []
        services.configure { events.append("services") }
        services.whenReady { events.append("deep link") }
        events.append("root frame")
        XCTAssertEqual(events, ["root frame"])
        XCTAssertFalse(services.isReady)
        services.ensureReady()
        XCTAssertEqual(events, ["root frame", "services", "deep link"])
        XCTAssertTrue(services.isReady)
    }

    func testEarlyActionInstallsExactlyOnceBeforeItRuns() {
        let services = AppLaunchServices()
        var installs = 0
        services.configure { installs += 1 }
        // Touches, background callbacks and intents demand readiness directly.
        services.ensureReady()
        services.whenReady { XCTAssertEqual(installs, 1) }
        // The later first-frame callback must not repeat installation.
        services.ensureReady()
        XCTAssertEqual(installs, 1)
    }

    func testCallbacksRegisteredDuringInstallationWaitUntilItCompletes() {
        let services = AppLaunchServices()
        var events: [String] = []
        services.configure {
            events.append("install begins")
            services.ensureReady()
            services.whenReady { events.append("nested action") }
            events.append("install ends")
        }
        services.whenReady { events.append("queued action") }
        services.ensureReady()
        XCTAssertEqual(events, ["install begins", "install ends", "queued action", "nested action"])
    }

    func testUnconfiguredViewFixturesDoNotWaitForAnAppLaunch() {
        let services = AppLaunchServices()
        var called = false
        services.whenReady { called = true }
        XCTAssertTrue(called)
    }
}
