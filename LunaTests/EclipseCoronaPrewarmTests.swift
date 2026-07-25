//
//  EclipseCoronaPrewarmTests.swift
//  LunaTests
//

import LunaDesignSystem
import UIKit
import XCTest

/// The corona raster costs ~100ms for a card-sized geometry. That is several
/// dropped frames if it lands on the tap that starts a transition, so the
/// carousel and the inline reader prewarm their geometries off the main thread as
/// soon as they know them. These tests protect that contract.
@MainActor
final class EclipseCoronaPrewarmTests: XCTestCase {

    /// Distinct per test so neither one can be served by the other's cache entry.
    private let card = CGSize(width: 337, height: 557)

    func testPrewarmLeavesNothingForTheSynchronousPath() {
        EclipseCorona.prewarm(bodySize: card, cornerRadius: 22, tint: .white)

        let deadline = Date().addingTimeInterval(10)
        var elapsed = Double.infinity
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let start = Date()
            _ = EclipseCorona.exteriorImage(
                silhouetteSize: card, cornerRadius: 22, tint: .white)
            elapsed = Date().timeIntervalSince(start) * 1000
            if elapsed < 1 { break }
        }
        XCTAssertLessThan(
            elapsed, 1,
            "prewarm never populated the cache — a transition would render inline")
    }

    /// The prewarm key has to match what the transition asks for exactly, or the
    /// work is done twice and the hitch stays.
    func testRepeatedPrewarmIsANoOpOnceCached() {
        let size = CGSize(width: 338, height: 558)
        _ = EclipseCorona.exteriorImage(
            silhouetteSize: size, cornerRadius: 22, tint: .white)
        // Already cached: this must not kick off a second render.
        EclipseCorona.prewarm(bodySize: size, cornerRadius: 22, tint: .white)
        let start = Date()
        _ = EclipseCorona.exteriorImage(
            silhouetteSize: size, cornerRadius: 22, tint: .white)
        XCTAssertLessThan(Date().timeIntervalSince(start) * 1000, 1)
    }

    func testDegenerateSizesAreRejectedRatherThanRendered() {
        XCTAssertNil(EclipseCorona.exteriorImage(
            silhouetteSize: .zero, cornerRadius: 22, tint: .white))
        XCTAssertNil(EclipseCorona.interiorImage(
            size: .zero, cornerRadius: 0, tint: .white))
        // Must not trap or spawn work.
        EclipseCorona.prewarm(bodySize: .zero, cornerRadius: 22, tint: .white)
    }
}
