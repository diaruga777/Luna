//
//  InteropGateTests.swift
//  LunaInteropTests
//

import LunaModels
import XCTest
@testable import LunaInterop

final class InteropGateTests: XCTestCase {

    // MARK: - Decision matrix

    func testSameSurfaceIsAlwaysAllowedRegardlessOfPaymentOrInstall() {
        for surface in InteropSurface.allCases {
            for unlocked in [true, false] {
                let decision = InteropGate.evaluate(
                    owner: surface, current: surface, isUnlocked: unlocked,
                    isInstalled: { _ in false })
                XCTAssertEqual(decision, .allowed, "\(surface) unlocked=\(unlocked)")
            }
        }
    }

    func testNoOwnerIsAlwaysAllowed() {
        for unlocked in [true, false] {
            let decision = InteropGate.evaluate(
                owner: nil, current: .reader, isUnlocked: unlocked, isInstalled: { _ in false })
            XCTAssertEqual(decision, .allowed)
        }
    }

    func testCrossSurfacePaidAndInstalledIsAllowed() {
        let decision = InteropGate.evaluate(
            owner: .downloader, current: .reader, isUnlocked: true, isInstalled: { _ in true })
        XCTAssertEqual(decision, .allowed)
    }

    func testCrossSurfacePaidButOwnerUninstalledNeedsInstallPromptAndSaveProceeds() {
        let decision = InteropGate.evaluate(
            owner: .downloader, current: .reader, isUnlocked: true, isInstalled: { _ in false })
        XCTAssertEqual(decision, .allowedNeedsInstall(owner: .downloader))
    }

    func testCrossSurfaceUnpaidIsBlockedRegardlessOfInstall() {
        let installed = InteropGate.evaluate(
            owner: .priceTracker, current: .reader, isUnlocked: false, isInstalled: { _ in true })
        XCTAssertEqual(installed, .blocked(owner: .priceTracker, ownerInstalled: true))

        let notInstalled = InteropGate.evaluate(
            owner: .priceTracker, current: .reader, isUnlocked: false, isInstalled: { _ in false })
        XCTAssertEqual(notInstalled, .blocked(owner: .priceTracker, ownerInstalled: false))
    }

    /// Full 3x3 owner/current matrix, cross-checked against a hand expectation.
    func testFullMatrix() {
        for owner in InteropSurface.allCases {
            for current in InteropSurface.allCases {
                for unlocked in [true, false] {
                    for installed in [true, false] {
                        let decision = InteropGate.evaluate(
                            owner: owner, current: current, isUnlocked: unlocked,
                            isInstalled: { $0 == owner ? installed : false })
                        let expected: InteropGate.Decision
                        if owner == current {
                            expected = .allowed
                        } else if !unlocked {
                            expected = .blocked(owner: owner, ownerInstalled: installed)
                        } else if installed {
                            expected = .allowed
                        } else {
                            expected = .allowedNeedsInstall(owner: owner)
                        }
                        XCTAssertEqual(
                            decision, expected,
                            "owner=\(owner) current=\(current) unlocked=\(unlocked) installed=\(installed)")
                    }
                }
            }
        }
    }

    func testAllowedPathsNeverCallIsInstalled() {
        var calls = 0
        _ = InteropGate.evaluate(
            owner: .reader, current: .reader, isUnlocked: false,
            isInstalled: { _ in calls += 1; return true })
        _ = InteropGate.evaluate(
            owner: nil, current: .reader, isUnlocked: false,
            isInstalled: { _ in calls += 1; return true })
        XCTAssertEqual(calls, 0)
    }

    // MARK: - Source exemption

    func testExemptSourcesAreNeverGated() {
        XCTAssertFalse(InteropGate.isGated(source: .email))
        XCTAssertFalse(InteropGate.isGated(source: .friendShare))
    }

    func testGatedSources() {
        XCTAssertTrue(InteropGate.isGated(source: .shareSheet))
        XCTAssertTrue(InteropGate.isGated(source: .paste))
        XCTAssertTrue(InteropGate.isGated(source: .manual))
        XCTAssertTrue(InteropGate.isGated(source: .appIntent))
    }
}
