//
//  IntentIngestSurfaceTests.swift
//  LunaTests
//

import LunaModels
import LunaReadingList
import XCTest
@testable import LunaIntents

final class IntentIngestSurfaceTests: XCTestCase {

    private func item(
        _ urlString: String, state: ReadingListItem.State
    ) -> ReadingListItem {
        var item = ReadingListItem(urlString: urlString)
        item.state = state
        return item
    }

    // MARK: - Outcome mapping

    func testUnsupportedKindResultSurvivesIntentOutcomeMapping() {
        let mapped = IntentIngestHelper.verifiedOutcome(
            from: .unsupportedKind(owner: .downloader),
            pressedURLString: "https://example.com/post", storedItem: nil)

        guard case let .unsupportedKind(owner) = mapped else {
            return XCTFail("expected unsupportedKind result, got \(mapped)")
        }
        XCTAssertEqual(owner, .downloader)
    }

    func testTimeoutStillMapsToIndeterminateCompletion() {
        let mapped = IntentIngestHelper.verifiedOutcome(
            from: nil, pressedURLString: "https://example.com/post", storedItem: nil)

        guard case let .completed(savedURLString) = mapped else {
            return XCTFail("expected completion, got \(mapped)")
        }
        XCTAssertNil(savedURLString)
    }

    func testIgnoredMapsToCompletedWithTheStoredURL() {
        let url = "https://example.com/already-saved"
        let mapped = IntentIngestHelper.verifiedOutcome(
            from: .ignored, pressedURLString: url, storedItem: item(url, state: .ready))

        guard case let .completed(savedURLString) = mapped else {
            return XCTFail("expected completion, got \(mapped)")
        }
        XCTAssertEqual(savedURLString, url)
    }

    func testFriendPromptSurvivesVerification() {
        let url = "https://example.com/post"
        let mapped = IntentIngestHelper.verifiedOutcome(
            from: .friendPromptRequested(item(url, state: .ready)),
            pressedURLString: url, storedItem: item(url, state: .ready))

        guard case let .friendPromptRequested(savedURLString) = mapped else {
            return XCTFail("expected friend prompt, got \(mapped)")
        }
        XCTAssertEqual(savedURLString, url)
    }

    // MARK: - Verification (never report success over nothing)

    func testPressThatSavedNothingAtAllIsAFailure() {
        // `.ignored` with no item anywhere: an unusable URL, or a duplicate
        // whose item is gone. Nothing is in the app — never report success.
        let mapped = IntentIngestHelper.verifiedOutcome(
            from: .ignored, pressedURLString: "https://example.com/post", storedItem: nil)

        guard case .saveFailed(.nothingSaved) = mapped else {
            return XCTFail("expected nothingSaved failure, got \(mapped)")
        }
    }

    func testSavedPlaceholderDedupedIntoAnExistingItemIsASuccess() {
        // An `apple.news` wrapper that resolved to an article already in the
        // list (or a store URL merged into an existing tracker) deletes the
        // placeholder — the content is in the app under the surviving item.
        let wrapper = "https://apple.news/AbCdEf"
        let mapped = IntentIngestHelper.verifiedOutcome(
            from: .saved(item(wrapper, state: .pending)),
            pressedURLString: wrapper, storedItem: nil)

        guard case let .completed(savedURLString) = mapped else {
            return XCTFail("expected completion for a deduped save, got \(mapped)")
        }
        XCTAssertEqual(savedURLString, wrapper)
    }

    func testSavedButFailedIngestIsAFailure() {
        let url = "https://example.com/post"
        let mapped = IntentIngestHelper.verifiedOutcome(
            from: .saved(item(url, state: .pending)),
            pressedURLString: url, storedItem: item(url, state: .failed))

        guard case .saveFailed(.contentUnavailable) = mapped else {
            return XCTFail("expected contentUnavailable failure, got \(mapped)")
        }
    }

    func testDuplicatePressOnAFailedItemIsAFailure() {
        let url = "https://example.com/post"
        let mapped = IntentIngestHelper.verifiedOutcome(
            from: .ignored, pressedURLString: url,
            storedItem: item(url, state: .failed))

        guard case .saveFailed(.contentUnavailable) = mapped else {
            return XCTFail("expected contentUnavailable failure, got \(mapped)")
        }
    }

    func testLockedArticleAwaitingUnlockIsASuccessfulSave() {
        let url = "https://www.wsj.com/articles/locked"
        let mapped = IntentIngestHelper.verifiedOutcome(
            from: .saved(item(url, state: .pending)),
            pressedURLString: url, storedItem: item(url, state: .needsCaptcha))

        guard case let .completed(savedURLString) = mapped else {
            return XCTFail("expected completion for a needs-unlock save, got \(mapped)")
        }
        XCTAssertEqual(savedURLString, url)
    }

    func testStillPendingSaveIsReportedAsHandled() {
        let url = "https://example.com/post"
        let mapped = IntentIngestHelper.verifiedOutcome(
            from: .saved(item(url, state: .pending)),
            pressedURLString: url, storedItem: item(url, state: .pending))

        guard case .completed = mapped else {
            return XCTFail("expected completion for a pending save, got \(mapped)")
        }
    }

    func testResolvedURLFromTheStoreWinsOverThePressedWrapperURL() {
        // The placeholder carries the wrapper URL; ingest repointed the item at
        // the publisher article, and the media/handoff legs must use that.
        let wrapper = "https://apple.news/AbCdEf"
        let resolved = "https://example.com/post/123"
        let mapped = IntentIngestHelper.verifiedOutcome(
            from: .saved(item(wrapper, state: .pending)),
            pressedURLString: wrapper, storedItem: item(resolved, state: .ready))

        guard case let .completed(savedURLString) = mapped else {
            return XCTFail("expected completion, got \(mapped)")
        }
        XCTAssertEqual(savedURLString, resolved)
    }

    // MARK: - The state table itself

    func testVerificationStateTable() {
        XCTAssertEqual(IntentSaveVerification.failure(forState: nil), .nothingSaved)
        XCTAssertEqual(IntentSaveVerification.failure(forState: .failed), .contentUnavailable)
        XCTAssertNil(IntentSaveVerification.failure(forState: .ready))
        XCTAssertNil(IntentSaveVerification.failure(forState: .pending))
        XCTAssertNil(IntentSaveVerification.failure(forState: .needsCaptcha))
    }
}
