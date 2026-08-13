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
        _ urlString: String, state: SavedItem.State
    ) -> SavedItem {
        var item = SavedItem(urlString: urlString)
        item.state = state
        return item
    }

    // MARK: - The gate at this surface

    /// The ONE call-site wiring proof for App Intents: the drop survives
    /// verification as `.unsupportedKind`, carrying the owner the error dialog
    /// names. Which (app, kind) pairs drop is `SurfaceSupportTests`' matrix.
    func testUnsupportedKindResultSurvivesIntentOutcomeMapping() {
        let mapped = IntentIngestHelper.verifiedOutcome(
            from: .unsupportedKind(owner: .downloader),
            pressedURLString: "https://example.com/post", storedItem: nil)

        guard case let .unsupportedKind(owner) = mapped else {
            return XCTFail("expected unsupportedKind result, got \(mapped)")
        }
        XCTAssertEqual(owner, .downloader)
    }

    // MARK: - Outcome mapping (what the intent reports back)

    func testVerifiedOutcomeMapping() {
        // A timeout: the save may still be running, so completion is indeterminate.
        guard case let .completed(timedOut) = IntentIngestHelper.verifiedOutcome(
            from: nil, pressedURLString: "https://example.com/post", storedItem: nil)
        else { return XCTFail("expected completion for a timeout") }
        XCTAssertNil(timedOut)

        // A duplicate press on a healthy item completes with the stored URL.
        let duplicate = "https://example.com/already-saved"
        guard case let .completed(duplicateURL) = IntentIngestHelper.verifiedOutcome(
            from: .ignored, pressedURLString: duplicate,
            storedItem: item(duplicate, state: .ready))
        else { return XCTFail("expected completion for a duplicate press") }
        XCTAssertEqual(duplicateURL, duplicate)

        // A friend prompt survives verification.
        let shared = "https://example.com/post"
        guard case let .friendPromptRequested(promptURL) = IntentIngestHelper.verifiedOutcome(
            from: .friendPromptRequested(item(shared, state: .ready)),
            pressedURLString: shared, storedItem: item(shared, state: .ready))
        else { return XCTFail("expected friend prompt") }
        XCTAssertEqual(promptURL, shared)

        // The placeholder carries the wrapper URL; ingest repointed the item at
        // the publisher article, and the media/handoff legs must use THAT.
        let wrapper = "https://apple.news/AbCdEf"
        let resolved = "https://example.com/post/123"
        guard case let .completed(resolvedURL) = IntentIngestHelper.verifiedOutcome(
            from: .saved(item(wrapper, state: .pending)),
            pressedURLString: wrapper, storedItem: item(resolved, state: .ready))
        else { return XCTFail("expected completion for a resolved save") }
        XCTAssertEqual(resolvedURL, resolved, "the store's resolved URL wins over the pressed one")
    }

    // MARK: - Verification (never report success over nothing)

    func testVerificationNeverReportsSuccessOverNothing() {
        // `.ignored` with no item anywhere: an unusable URL, or a duplicate
        // whose item is gone. Nothing is in the app — never report success.
        guard case .saveFailed(.nothingSaved) = IntentIngestHelper.verifiedOutcome(
            from: .ignored, pressedURLString: "https://example.com/post", storedItem: nil)
        else { return XCTFail("expected nothingSaved failure") }

        // Saved, but ingest failed — and the same for a duplicate press on a
        // failed item: the content is not readable, so the intent must say so.
        let url = "https://example.com/post"
        guard case .saveFailed(.contentUnavailable) = IntentIngestHelper.verifiedOutcome(
            from: .saved(item(url, state: .pending)),
            pressedURLString: url, storedItem: item(url, state: .failed))
        else { return XCTFail("expected contentUnavailable for a failed ingest") }
        guard case .saveFailed(.contentUnavailable) = IntentIngestHelper.verifiedOutcome(
            from: .ignored, pressedURLString: url, storedItem: item(url, state: .failed))
        else { return XCTFail("expected contentUnavailable for a duplicate on a failed item") }
    }

    func testVerificationAcceptsTheSavesThatReallyLanded() {
        // An `apple.news` wrapper that resolved to an article already in the list
        // (or a store URL merged into an existing tracker) deletes the placeholder
        // — the content IS in the app, under the surviving item.
        let wrapper = "https://apple.news/AbCdEf"
        guard case let .completed(dedupedURL) = IntentIngestHelper.verifiedOutcome(
            from: .saved(item(wrapper, state: .pending)),
            pressedURLString: wrapper, storedItem: nil)
        else { return XCTFail("expected completion for a deduped save") }
        XCTAssertEqual(dedupedURL, wrapper)

        // A locked article awaiting unlock is saved, not failed.
        let locked = "https://www.wsj.com/articles/locked"
        guard case let .completed(lockedURL) = IntentIngestHelper.verifiedOutcome(
            from: .saved(item(locked, state: .pending)),
            pressedURLString: locked, storedItem: item(locked, state: .needsCaptcha))
        else { return XCTFail("expected completion for a needs-unlock save") }
        XCTAssertEqual(lockedURL, locked)

        // So is one still being ingested.
        let pending = "https://example.com/post"
        guard case .completed = IntentIngestHelper.verifiedOutcome(
            from: .saved(item(pending, state: .pending)),
            pressedURLString: pending, storedItem: item(pending, state: .pending))
        else { return XCTFail("expected completion for a pending save") }
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
