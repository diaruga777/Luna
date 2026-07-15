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
        let entitlement = InteropEntitlement(defaults: defaults)
        XCTAssertFalse(entitlement.isUnlocked)
    }

    func testRecordUnlockedPersists() {
        let (defaults, suiteName) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let entitlement = InteropEntitlement(defaults: defaults)
        entitlement.recordUnlocked()
        XCTAssertTrue(entitlement.isUnlocked)
        // A second reader over the SAME suite (a different Luna app process on
        // this device) sees the same flag.
        XCTAssertTrue(InteropEntitlement(defaults: defaults).isUnlocked)
    }

    func testRecordUnlockedIsIdempotent() {
        let (defaults, suiteName) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let entitlement = InteropEntitlement(defaults: defaults)
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
        InteropEntitlement(defaults: defaultsA).recordUnlocked()
        XCTAssertTrue(InteropEntitlement(defaults: defaultsA).isUnlocked)
        XCTAssertFalse(InteropEntitlement(defaults: defaultsB).isUnlocked)
    }
}
