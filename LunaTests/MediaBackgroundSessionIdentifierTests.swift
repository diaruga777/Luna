//
//  MediaBackgroundSessionIdentifierTests.swift
//  LunaTests
//

import XCTest
@testable import LunaMediaDownload

final class MediaBackgroundSessionIdentifierTests: XCTestCase {
    private let centralApp = "com.hsanabria.luna"
    private let downloaderApp = "com.hsanabria.luna.downloader"

    func testEveryContainingAppAndEmbeddedProcessGetsAUniqueStableIdentifier() {
        let processBundleIdentifiers = [
            centralApp,
            centralApp + ".share",
            centralApp + ".action2",
            centralApp + ".safari",
            centralApp + ".liveactivity",
            downloaderApp,
            downloaderApp + ".share",
            downloaderApp + ".action2",
            downloaderApp + ".safari",
            downloaderApp + ".liveactivity",
        ]

        let identifiers = processBundleIdentifiers.map {
            MediaBackgroundSessionIdentifier.identifier(forBundleIdentifier: $0)
        }

        XCTAssertEqual(Set(identifiers).count, processBundleIdentifiers.count)
        XCTAssertEqual(
            identifiers,
            processBundleIdentifiers.map {
                $0 + ".mediaDownload.background.v2"
            })
    }

    func testContainingAppRoutesItsOwnAndItsEmbeddedProcessSessionsExactly() {
        for containingApp in [centralApp, downloaderApp] {
            let processBundleIdentifiers = [
                containingApp,
                containingApp + ".share",
                containingApp + ".action2",
                containingApp + ".safari",
                containingApp + ".liveactivity",
            ]
            for processBundleIdentifier in processBundleIdentifiers {
                let identifier = MediaBackgroundSessionIdentifier.identifier(
                    forBundleIdentifier: processBundleIdentifier)
                XCTAssertEqual(
                    MediaBackgroundSessionIdentifier.routedIdentifier(
                        identifier,
                        containingAppBundleIdentifier: containingApp),
                    identifier)
            }
        }
    }

    func testContainingAppIsRecoveredFromAnExtensionBundleIdentifier() {
        XCTAssertEqual(
            MediaBackgroundSessionIdentifier.containingAppBundleIdentifier(
                forProcessBundleIdentifier: centralApp + ".share"),
            centralApp)
        XCTAssertEqual(
            MediaBackgroundSessionIdentifier.containingAppBundleIdentifier(
                forProcessBundleIdentifier: downloaderApp + ".liveactivity"),
            downloaderApp)
        XCTAssertEqual(
            MediaBackgroundSessionIdentifier.containingAppBundleIdentifier(
                forProcessBundleIdentifier: downloaderApp),
            downloaderApp)
    }

    func testJobRepairIsScopedToItsOwningSession() {
        let appIdentifier = MediaBackgroundSessionIdentifier.identifier(
            forBundleIdentifier: centralApp)
        let extensionIdentifier = MediaBackgroundSessionIdentifier.identifier(
            forBundleIdentifier: centralApp + ".share")

        XCTAssertTrue(MediaBackgroundSessionIdentifier.includesJob(
            withSessionIdentifier: appIdentifier,
            inSessionIdentifier: appIdentifier))
        XCTAssertFalse(MediaBackgroundSessionIdentifier.includesJob(
            withSessionIdentifier: extensionIdentifier,
            inSessionIdentifier: appIdentifier))
        XCTAssertTrue(MediaBackgroundSessionIdentifier.includesJob(
            withSessionIdentifier: nil,
            inSessionIdentifier: appIdentifier))
    }

    func testCentralAppDoesNotConsumeSiblingAppOrMalformedSessions() {
        let foreignProcessBundleIdentifiers = [
            downloaderApp,
            downloaderApp + ".share",
            downloaderApp + ".action2",
            "com.example.unrelated.share",
        ]
        for processBundleIdentifier in foreignProcessBundleIdentifiers {
            let identifier = MediaBackgroundSessionIdentifier.identifier(
                forBundleIdentifier: processBundleIdentifier)
            XCTAssertNil(
                MediaBackgroundSessionIdentifier.routedIdentifier(
                    identifier,
                    containingAppBundleIdentifier: centralApp))
        }

        XCTAssertNil(
            MediaBackgroundSessionIdentifier.routedIdentifier(
                "com.hsanabria.luna.mediaDownload.background",
                containingAppBundleIdentifier: centralApp),
            "the retired generic session is intentionally not adopted")
        XCTAssertNil(
            MediaBackgroundSessionIdentifier.routedIdentifier(
                centralApp + ".share.not-a-session",
                containingAppBundleIdentifier: centralApp))
    }

    func testRejectedLifecycleCallbackCompletesInsteadOfAttachingForeignSession() {
        let foreignIdentifier = MediaBackgroundSessionIdentifier.identifier(
            forBundleIdentifier: downloaderApp + ".share")
        var completionCount = 0

        let attached = LiveMediaDownloadManager.attachBackgroundCompletionHandler(
            forSessionIdentifier: foreignIdentifier,
            containingAppBundleIdentifier: centralApp
        ) {
            completionCount += 1
        }

        XCTAssertFalse(attached)
        XCTAssertEqual(completionCount, 1)
    }

    func testRecreatedConfigurationUsesLifecycleCallbackIdentifierExactly() {
        let callbackIdentifier = MediaBackgroundSessionIdentifier.identifier(
            forBundleIdentifier: downloaderApp + ".share")

        let configuration = LiveMediaDownloadManager.backgroundSessionConfiguration(
            identifier: callbackIdentifier)

        XCTAssertEqual(configuration.identifier, callbackIdentifier)
        XCTAssertTrue(configuration.sessionSendsLaunchEvents)
    }

    func testManagerRetainsTheSessionIdentifierItWasAskedToAttach() {
        let callbackIdentifier = MediaBackgroundSessionIdentifier.identifier(
            forBundleIdentifier: downloaderApp + ".action2")

        let manager = LiveMediaDownloadManager(
            backgroundSessionIdentifier: callbackIdentifier)

        XCTAssertEqual(manager.backgroundSessionIdentifier, callbackIdentifier)
    }
}
