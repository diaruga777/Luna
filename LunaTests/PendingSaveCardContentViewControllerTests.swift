//
//  PendingSaveCardContentViewControllerTests.swift
//  LunaTests
//

import LunaModels
import XCTest
@testable import Luna

/// The pending card's status line comes from `PendingSaveStatus.provider` when
/// one names the save's step, and is the generic loading line otherwise.
@MainActor
final class PendingSaveCardContentViewControllerTests: XCTestCase {

    private var previousProvider: (any PendingSaveStatusProviding)?
    private let provider = FakeStatusProvider()

    override func setUp() {
        super.setUp()
        previousProvider = PendingSaveStatus.provider
        PendingSaveStatus.provider = provider
    }

    override func tearDown() {
        PendingSaveStatus.provider = previousProvider
        super.tearDown()
    }

    func testTheProvidersStatusReplacesTheLoadingLine() {
        let id = UUID()
        provider.statuses[id] = "Transcribing…"

        let card = PendingSaveCardContentViewController(itemID: id)
        card.loadViewIfNeeded()

        XCTAssertEqual(card.loadingTextForTesting, "Transcribing…")
        XCTAssertTrue(card.isSpinnerAnimatingForTesting)
    }

    func testASaveWithNoStatusShowsTheLoadingLine() {
        let card = PendingSaveCardContentViewController(itemID: UUID())
        card.loadViewIfNeeded()
        XCTAssertEqual(card.loadingTextForTesting, L10n.string("Common_loadingEllipsis"))

        let anonymous = PendingSaveCardContentViewController()
        anonymous.loadViewIfNeeded()
        XCTAssertEqual(anonymous.loadingTextForTesting, L10n.string("Common_loadingEllipsis"))
    }

    func testTheLineFollowsTheStatusAsTheJobMoves() {
        let id = UUID()
        provider.statuses[id] = "Waiting to transcribe…"
        let card = PendingSaveCardContentViewController(itemID: id)
        card.loadViewIfNeeded()

        provider.statuses[id] = "Downloading audio…"
        card.refreshStatus()
        XCTAssertEqual(card.loadingTextForTesting, "Downloading audio…")

        provider.statuses[id] = nil
        card.refreshStatus()
        XCTAssertEqual(card.loadingTextForTesting, L10n.string("Common_loadingEllipsis"))
    }
}

private final class FakeStatusProvider: PendingSaveStatusProviding {
    var statuses: [UUID: String] = [:]

    func status(forSaveID id: UUID) -> String? { statuses[id] }
}
