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

final class XteinkRendezvousSweepLockTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sweep-lock-\(UUID().uuidString).lock")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    func testSecondAcquireFailsUntilReleased() {
        let lock = XteinkRendezvousSweepLock(fileURL: fileURL)
        XCTAssertTrue(lock.acquire())
        XCTAssertFalse(lock.acquire(), "re-acquire while held must fail")
        lock.release()
        XCTAssertTrue(lock.acquire())
        lock.release()
    }

    /// Two instances on the same file model the two Luna processes: the
    /// `flock` is per open-file-description, so the second loses even inside
    /// one process.
    func testSeparateInstancesExcludeEachOther() {
        let owner = XteinkRendezvousSweepLock(fileURL: fileURL)
        let rival = XteinkRendezvousSweepLock(fileURL: fileURL)
        XCTAssertTrue(owner.acquire())
        XCTAssertFalse(rival.acquire())
        owner.release()
        XCTAssertTrue(rival.acquire())
        rival.release()
    }

    /// With no shared container to arbitrate through the lock degrades to a
    /// per-process flag — a sweep still runs exactly once.
    func testNilFileURLStillExcludesWithinTheProcess() {
        let lock = XteinkRendezvousSweepLock(fileURL: nil)
        XCTAssertTrue(lock.acquire())
        XCTAssertFalse(lock.acquire())
        lock.release()
        XCTAssertTrue(lock.acquire())
        lock.release()
    }
}
