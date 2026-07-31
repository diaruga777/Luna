//
//  SiblingLunaAppIntentGateTests.swift
//  LunaTests
//

import LunaIntents
import LunaModels
import XCTest

/// All four Luna apps register the same two Action Button intents, so a press
/// made while a SIBLING app owns the screen can reach any of them. Both intents
/// stop there and report the press unhandled — see `AppNamePlatform`.
final class SiblingLunaAppIntentGateTests: XCTestCase {
    func testEveryOtherLunaAppInTheFamilyIsRecognized() {
        for running in LunaApp.allCases {
            for other in LunaApp.allCases where other != running {
                XCTAssertTrue(
                    AppNamePlatform.isSiblingLunaApp(
                        other.displayName, running: running),
                    "\(other.displayName) is a sibling of \(running.displayName)")
            }
        }
    }

    /// The app you're actually holding is not a sibling: a press inside it keeps
    /// whatever its own screen affords.
    func testTheRunningAppIsNotItsOwnSibling() {
        for running in LunaApp.allCases {
            XCTAssertFalse(
                AppNamePlatform.isSiblingLunaApp(
                    running.displayName, running: running))
        }
    }

    /// "Luna" is a prefix of the other three names, so substring matching would
    /// fold the family into one app. Whole-name comparison keeps them distinct.
    func testTheCentralAppsNameDoesNotSwallowTheSingleContentApps() {
        XCTAssertTrue(
            AppNamePlatform.isSiblingLunaApp("Luna", running: .reader))
        XCTAssertFalse(
            AppNamePlatform.isSiblingLunaApp("Luna Reader", running: .reader))
        XCTAssertTrue(
            AppNamePlatform.isSiblingLunaApp("Luna Reader", running: .luna))
    }

    func testNamesAreMatchedLooselyEnoughForShortcutsFormatting() {
        XCTAssertTrue(
            AppNamePlatform.isSiblingLunaApp("  luna   reader ", running: .luna))
        XCTAssertTrue(
            AppNamePlatform.isSiblingLunaApp("LUNA DOWNLOADER", running: .luna))
    }

    func testUnrelatedAndMissingAppNamesAreNotSiblings() {
        XCTAssertFalse(AppNamePlatform.isSiblingLunaApp(nil, running: .luna))
        XCTAssertFalse(AppNamePlatform.isSiblingLunaApp("", running: .luna))
        XCTAssertFalse(AppNamePlatform.isSiblingLunaApp("   ", running: .luna))
        XCTAssertFalse(AppNamePlatform.isSiblingLunaApp("Safari", running: .luna))
        XCTAssertFalse(AppNamePlatform.isSiblingLunaApp("Lunar", running: .luna))
        XCTAssertFalse(
            AppNamePlatform.isSiblingLunaApp("Luna Reader Pro", running: .luna))
    }

    /// A sibling app is unsupported no matter what else about the press looks
    /// actionable — it is not Safari, not Shortcuts, and carries no platform.
    func testASiblingAppLooksLikeNothingElseTheIntentsAccept() {
        for app in LunaApp.allCases {
            let name = app.displayName
            XCTAssertFalse(AppNamePlatform.isSafari(forAppName: name))
            XCTAssertFalse(AppNamePlatform.isShortcuts(forAppName: name))
            XCTAssertNil(AppNamePlatform.platform(forAppName: name))
            XCTAssertFalse(AppNamePlatform.isSupported(forAppName: name))
        }
    }
}
