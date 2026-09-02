//
//  XteinkRendezvousSweepPolicyTests.swift
//  LunaTests
//

import XCTest
@testable import LunaSend

final class XteinkRendezvousSweepPolicyTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var events: [String] = []
        func record(_ event: String) { lock.withLock { events.append(event) } }
    }

    /// A read-report-only window never reconciles, drains, or sweeps — it
    /// just answers `reportNoWork()`, then releases the sweep lock.
    func testReadReportOnlyWindowSkipsEverythingButNoWork() async throws {
        let recorder = Recorder()
        let released = expectation(description: "lock released")
        XteinkRendezvousSweepPolicy.rendezvousBecameReady(
            isReadReportOnlyWindow: true,
            acquireSweepLock: { recorder.record("lock"); return true },
            releaseSweepLock: { recorder.record("unlock"); released.fulfill() },
            reconcileReadState: { recorder.record("reconcile") },
            drainPendingDeletes: { recorder.record("drain") },
            deliverQueuedSends: { recorder.record("deliver") },
            reportNoWork: { recorder.record("noWork") })
        await fulfillment(of: [released], timeout: 2)
        XCTAssertEqual(recorder.events, ["lock", "noWork", "unlock"])
    }

    /// A normal window runs the whole pipeline in order — reconcile, drain
    /// deletes, deliver queued sends — and ALWAYS concludes with `no_work` so
    /// the reader closes its window instead of idling to its cap.
    func testNormalWindowRunsPipelineThenAlwaysReportsNoWork() async throws {
        let recorder = Recorder()
        let released = expectation(description: "lock released")
        XteinkRendezvousSweepPolicy.rendezvousBecameReady(
            isReadReportOnlyWindow: false,
            acquireSweepLock: { recorder.record("lock"); return true },
            releaseSweepLock: { recorder.record("unlock"); released.fulfill() },
            reconcileReadState: { recorder.record("reconcile") },
            drainPendingDeletes: { recorder.record("drain") },
            deliverQueuedSends: { recorder.record("deliver") },
            reportNoWork: { recorder.record("noWork") })
        await fulfillment(of: [released], timeout: 2)
        XCTAssertEqual(recorder.events, ["lock", "reconcile", "drain", "deliver", "noWork", "unlock"])
    }

    /// Losing the sweep lock means another Luna process owns this rendezvous:
    /// this one must stay completely silent — not even `no_work`, which the
    /// owner sends when it concludes the window.
    func testDeniedSweepLockRunsNothing() async throws {
        let recorder = Recorder()
        XteinkRendezvousSweepPolicy.rendezvousBecameReady(
            isReadReportOnlyWindow: false,
            acquireSweepLock: { false },
            releaseSweepLock: { recorder.record("unlock") },
            reconcileReadState: { recorder.record("reconcile") },
            drainPendingDeletes: { recorder.record("drain") },
            deliverQueuedSends: { recorder.record("deliver") },
            reportNoWork: { recorder.record("noWork") })
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(recorder.events, [])
    }

    /// `reportNoWork` throwing (the link dropped first) must still release
    /// the sweep lock, or the process could never sweep a later window.
    func testFailedNoWorkStillReleasesLock() async throws {
        struct LinkDropped: Error {}
        let released = expectation(description: "lock released")
        XteinkRendezvousSweepPolicy.rendezvousBecameReady(
            isReadReportOnlyWindow: false,
            acquireSweepLock: { true },
            releaseSweepLock: { released.fulfill() },
            reconcileReadState: {},
            drainPendingDeletes: {},
            deliverQueuedSends: {},
            reportNoWork: { throw LinkDropped() })
        await fulfillment(of: [released], timeout: 2)
    }
}
