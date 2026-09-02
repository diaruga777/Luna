//
//  PluginNotificationDeepLinkTests.swift
//  LunaTests
//

import LunaPluginExport
import XCTest
@testable import Luna

/// `Luna/AppDelegate.swift` compiles into all four apps and only the central
/// one links the plugin tier, so the `userInfo` key it reads is a hand-copy of
/// the one the bridge writes. Nothing but this pins the two together, and a
/// drift is silent: the notification just opens the app where it was.
final class PluginNotificationDeepLinkTests: XCTestCase {

    func testTheAppDelegateReadsTheKeyTheNotificationBridgeWrites() {
        XCTAssertEqual(
            AppDelegate.pluginDeepLinkUserInfoKey,
            SystemPluginNotificationCenter.deepLinkKey)
    }
}
