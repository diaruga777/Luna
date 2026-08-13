//
//  TimeLimitTests.swift
//  LunaTests
//

import LunaModels
import XCTest

/// The one property that makes `TimeLimit` worth having, and the one the task-group
/// spelling it replaced did not have: it returns at the deadline even when the work
/// cannot be stopped.
///
/// So every case here hands it work that genuinely ignores cancellation — a
/// continuation resumed off a dispatch queue, which is the shape of the real
/// offenders (`evaluateJavaScript`'s completion handler, a WebView render's poll).
/// Sleeping in the cooperative pool would not do: `Task.sleep` throws the moment
/// its task is cancelled, so a `Task.sleep`-based fixture passes under the broken
/// implementation too.
final class TimeLimitTests: XCTestCase {

    /// Resolves to `value` after `seconds`, whatever anyone thinks about it.
    private func uncancellable<T: Sendable>(
        after seconds: TimeInterval, returning value: T
    ) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                continuation.resume(returning: value)
            }
        }
    }

    func testReturnsNilAtTheDeadlineWithoutWaitingForUnstoppableWork() async {
        let started = Date()
        let result = await TimeLimit.run(0.2) {
            await self.uncancellable(after: 3, returning: "too late")
        }
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertNil(result, "the deadline passed, so there is no answer to report")
        XCTAssertLessThan(
            elapsed, 1.5,
            "returned in \(elapsed)s — a 0.2s deadline waited on 3s of uncancellable work")
    }

    func testReturnsTheValueWhenTheWorkBeatsTheDeadline() async {
        let result = await TimeLimit.run(5) {
            await self.uncancellable(after: 0.05, returning: 42)
        }
        XCTAssertEqual(result, 42)
    }

    /// An optional-returning operation nests rather than collapses, which is what
    /// lets a caller keep "the work said no" distinct from "the work said nothing
    /// in time" — every call site in the fan-out flattens it deliberately, with
    /// `?? nil`.
    func testAnOperationsOwnNilIsDistinctFromTheDeadlinesNil() async {
        let answered: String?? = await TimeLimit.run(5) {
            await self.uncancellable(after: 0.05, returning: String?.none)
        }
        XCTAssertTrue(answered != nil, "the work answered — in time")
        XCTAssertNil(answered ?? "flattened", "and its answer was nil")

        let timedOut: String?? = await TimeLimit.run(0.1) {
            await self.uncancellable(after: 3, returning: String?.some("too late"))
        }
        XCTAssertTrue(timedOut == nil, "the deadline's nil is the outer one")
    }

    /// A caller that gives up must not be held by work that will not stop — this
    /// is how cancelling the App Intent's fan-out stops costing wall clock rather
    /// than merely being requested to.
    func testStopsWaitingWhenTheCallerIsCancelled() async {
        let finished = expectation(description: "the awaiting task returned")
        let task = Task {
            _ = await TimeLimit.run(60) {
                await self.uncancellable(after: 5, returning: "never read")
            }
            finished.fulfill()
        }
        // Let the run reach its suspension point before cancelling it.
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        await fulfillment(of: [finished], timeout: 2)
    }

    func testAZeroDeadlineDoesNotHangOnWorkThatNeverArrives() async {
        let result = await TimeLimit.run(0) {
            await self.uncancellable(after: 3, returning: "too late")
        }
        XCTAssertNil(result)
    }
}
