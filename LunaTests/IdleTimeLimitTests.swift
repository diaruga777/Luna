//
//  IdleTimeLimitTests.swift
//  LunaTests
//

import LunaModels
import XCTest

final class IdleTimeLimitTests: XCTestCase {

    private func uncancellable<T: Sendable>(
        after seconds: TimeInterval, returning value: T
    ) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                continuation.resume(returning: value)
            }
        }
    }

    func testIdleDeadlineDoesNotDrainUncooperativeWork() async {
        let started = Date()
        let result = await IdleTimeLimit.run(0.1) {
            await self.uncancellable(after: 1, returning: "late")
        }

        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.6)
    }

    func testActivityExtendsTheDeadline() async {
        let result = await IdleTimeLimit.run(0.12) {
            for _ in 0..<4 {
                try? await Task.sleep(nanoseconds: 70_000_000)
                IdleTimeLimit.touch()
            }
            return "finished"
        }

        XCTAssertEqual(result, "finished")
    }

    func testSilenceAfterActivityStillTimesOut() async {
        let started = Date()
        let result = await IdleTimeLimit.run(0.1) {
            IdleTimeLimit.touch()
            return await self.uncancellable(after: 1, returning: "late")
        }

        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.6)
    }
}
