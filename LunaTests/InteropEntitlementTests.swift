//
//  InteropEntitlementTests.swift
//  LunaTests
//

import XCTest
@testable import LunaInterop

final class InteropEntitlementTests: XCTestCase {

    private func scratchDefaults() -> (UserDefaults, String) {
        let suiteName = "InteropEntitlementTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }

    func testStartsLocked() {
        let (defaults, suiteName) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let entitlement = InteropEntitlement(defaults: defaults, buildGrant: { nil })
        XCTAssertFalse(entitlement.isUnlocked)
    }

    func testRecordUnlockedPersists() {
        let (defaults, suiteName) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let entitlement = InteropEntitlement(defaults: defaults, buildGrant: { nil })
        entitlement.recordUnlocked()
        XCTAssertTrue(entitlement.isUnlocked)
        // A second reader over the SAME suite (a different Luna app process on
        // this device) sees the same flag.
        XCTAssertTrue(InteropEntitlement(defaults: defaults, buildGrant: { nil }).isUnlocked)
    }

    func testRecordUnlockedIsIdempotent() {
        let (defaults, suiteName) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let entitlement = InteropEntitlement(defaults: defaults, buildGrant: { nil })
        entitlement.recordUnlocked()
        entitlement.recordUnlocked()
        XCTAssertTrue(entitlement.isUnlocked)
    }

    func testDistinctSuitesAreIsolated() {
        let (defaultsA, suiteA) = scratchDefaults()
        let (defaultsB, suiteB) = scratchDefaults()
        defer {
            defaultsA.removePersistentDomain(forName: suiteA)
            defaultsB.removePersistentDomain(forName: suiteB)
        }
        InteropEntitlement(defaults: defaultsA, buildGrant: { nil }).recordUnlocked()
        XCTAssertTrue(InteropEntitlement(defaults: defaultsA, buildGrant: { nil }).isUnlocked)
        XCTAssertFalse(InteropEntitlement(defaults: defaultsB, buildGrant: { nil }).isUnlocked)
    }

    func testBuildGrantUnlocksWithoutRecordingPurchase() {
        let (defaults, suiteName) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let entitlement = InteropEntitlement(
            defaults: defaults, buildGrant: { .testFlight })

        XCTAssertEqual(entitlement.status, .testFlight)
        XCTAssertTrue(entitlement.isUnlocked)
        XCTAssertFalse(defaults.bool(forKey: InteropEntitlement.unlockedKey))
    }

    func testPurchasedStatusWinsOverBuildGrant() {
        let (defaults, suiteName) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: InteropEntitlement.unlockedKey)
        let entitlement = InteropEntitlement(
            defaults: defaults, buildGrant: { .debugBuild })

        XCTAssertEqual(entitlement.status, .purchased)
    }

    func testContainingAppBundleIsFoundFromExtensionBundle() {
        let extensionURL = URL(fileURLWithPath:
            "/private/var/containers/Bundle/Application/ABC/Luna.app/PlugIns/LunaShare.appex")
        XCTAssertEqual(
            InteropBuildGrant.containingAppBundleURL(for: extensionURL)?.path,
            "/private/var/containers/Bundle/Application/ABC/Luna.app")
    }

    func testContainingAppBundleReturnsNilOutsideAnApp() {
        XCTAssertNil(InteropBuildGrant.containingAppBundleURL(
            for: URL(fileURLWithPath: "/tmp/LunaShare.appex")))
    }
}
