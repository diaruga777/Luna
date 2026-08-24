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
    /// just answers `reportNoWork()`.
    func testReadReportOnlyWindowSkipsEverythingButNoWork() async throws {
        let recorder = Recorder()
        let reported = expectation(description: "reportNoWork called")
        XteinkRendezvousSweepPolicy.rendezvousBecameReady(
            isReadReportOnlyWindow: true,
            reconcileReadState: { recorder.record("reconcile") },
            drainPendingDeletes: { recorder.record("drain") },
            hasQueuedSend: { recorder.record("hasQueuedSend"); return true },
            retryPendingSends: { recorder.record("retry") },
            reportNoWork: { recorder.record("noWork"); reported.fulfill() })
        await fulfillment(of: [reported], timeout: 2)
        XCTAssertEqual(recorder.events, ["noWork"])
    }

    /// Pending deletes are drained REGARDLESS of whether there is a queued
    /// send — draining is not gated behind "has work", so a delivery that
    /// finished reading gets its remote copy removed even on a window with
    /// nothing left to send.
    func testNormalWindowDrainsDeletesEvenWithNoQueuedSend() async throws {
        let recorder = Recorder()
        let reported = expectation(description: "reportNoWork called")
        XteinkRendezvousSweepPolicy.rendezvousBecameReady(
            isReadReportOnlyWindow: false,
            reconcileReadState: { recorder.record("reconcile") },
            drainPendingDeletes: { recorder.record("drain") },
            hasQueuedSend: { false },
            retryPendingSends: { recorder.record("retry") },
            reportNoWork: { recorder.record("noWork"); reported.fulfill() })
        await fulfillment(of: [reported], timeout: 2)
        XCTAssertEqual(recorder.events, ["reconcile", "drain", "noWork"])
    }

    func testNormalWindowWithAQueuedSendSweepsInsteadOfReportingNoWork() async throws {
        let recorder = Recorder()
        let retried = expectation(description: "retryPendingSends called")
        XteinkRendezvousSweepPolicy.rendezvousBecameReady(
            isReadReportOnlyWindow: false,
            reconcileReadState: { recorder.record("reconcile") },
            drainPendingDeletes: { recorder.record("drain") },
            hasQueuedSend: { true },
            retryPendingSends: { recorder.record("retry"); retried.fulfill() },
            reportNoWork: { recorder.record("noWork") })
        await fulfillment(of: [retried], timeout: 2)
        XCTAssertEqual(recorder.events, ["reconcile", "drain", "retry"])
    }
}
