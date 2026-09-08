import Foundation
import XCTest
import LunaVaultBackend
import LunaVaultUI

/// Regression pins for the Vault UI/shell review pass (work package H).
/// These cover the seams that stayed cheap to test without a UI host — the
/// scheduler's submit-vs-run split behind the BGTask register-once fix, the
/// sync runtime's task-identifier contract, and the iCloud eviction
/// aggregation — rather than the presentation/alert flows, which the review
/// plan explicitly excludes from this bar.
final class VaultUIShellReviewFixTests: XCTestCase {
    private final class RecordingSubmitter: VaultBackgroundTaskSubmitting, @unchecked Sendable {
        private let lock = NSLock()
        private var _submittedIdentifiers: [String] = []
        var submittedIdentifiers: [String] { lock.withLock { _submittedIdentifiers } }

        func submit(identifier: String, requiresNetworkConnectivity: Bool,
                    requiresExternalPower: Bool, earliestBeginDate: Date?) throws {
            lock.withLock { _submittedIdentifiers.append(identifier) }
        }
        func cancel(identifier: String) {}
    }

    private final class RanFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = false
        var value: Bool { lock.withLock { _value } }
        func set() { lock.withLock { _value = true } }
    }

    // MARK: - VaultBackgroundTaskScheduler.submit (backgrounding fix)

    /// `applicationDidEnterBackground` must only submit the system request,
    /// never start the operation in-process — starting it opportunistically
    /// raced the real delivery and left the later system task completing
    /// immediately without doing anything (finding: KindWiring+Vault
    /// `applicationDidEnterBackground`). `submit(kind:)` is the seam that
    /// keeps that true.
    func testSubmitDoesNotRunTheOperation() throws {
        let submitter = RecordingSubmitter()
        let scheduler = VaultBackgroundTaskScheduler(identifierPrefix: "test.vault.submit", submitter: submitter)
        let ran = RanFlag()
        scheduler.register(kind: .index) {
            ran.set()
            return true
        }

        try scheduler.submit(kind: .index, earliestBeginDate: nil)

        XCTAssertEqual(submitter.submittedIdentifiers, ["test.vault.submit.index"])
        XCTAssertFalse(ran.value, "submit(kind:) must not start the registered operation")
        XCTAssertFalse(scheduler.isRunning(.index))
    }

    /// `submit(kind:)` still reaches the injected submitter with the same
    /// identifier format `run`/`schedule` use, so a request submitted at
    /// backgrounding is answered by the same system delivery.
    func testSubmitUsesTheSameIdentifierFormatAsSchedule() throws {
        let submitter = RecordingSubmitter()
        let scheduler = VaultBackgroundTaskScheduler(identifierPrefix: "test.vault.format", submitter: submitter)
        scheduler.register(kind: .thumbnailMaintenance) { true }

        try scheduler.submit(kind: .thumbnailMaintenance, earliestBeginDate: nil)

        XCTAssertEqual(submitter.submittedIdentifiers, [scheduler.identifier(for: .thumbnailMaintenance)])
    }

    // MARK: - VaultSyncRuntimeController.taskIdentifier (register-once seam)

    /// The app registers this exact string once at launch
    /// (`VaultAppDelegate.registerBackgroundTasks`), independently of this
    /// controller's own construction. Pin the `.sync` suffix so the two
    /// stay matched.
    func testSyncRuntimeTaskIdentifierAppendsSyncSuffix() {
        let bundle = Bundle(for: VaultUIShellReviewFixTests.self)
        let identifier = VaultSyncRuntimeController.taskIdentifier(bundle: bundle)
        XCTAssertEqual(identifier, (bundle.bundleIdentifier ?? "") + ".sync")
    }

    // MARK: - VaultICloudLocalState.aggregating (eviction fix)

    /// Every evictable object confirming eviction reports the aggregate as
    /// fully evicted.
    func testAggregatingAllEvictedReportsEvicted() {
        let outcomes: [Result<VaultEvictionOutcome, Error>] = [.success(.evicted), .success(.evicted)]
        XCTAssertEqual(VaultICloudLocalState.aggregating(outcomes), .evicted)
    }

    /// One object still pending keeps the whole request "requested" even
    /// though a sibling object already confirmed eviction — the aggregate
    /// must not report done early.
    func testAggregatingAnyPendingKeepsEvictionRequested() {
        let outcomes: [Result<VaultEvictionOutcome, Error>] = [.success(.evicted), .success(.pending)]
        XCTAssertEqual(VaultICloudLocalState.aggregating(outcomes), .evictionRequested)
    }

    /// A failure on any one object fails the whole aggregate rather than
    /// reporting partial success.
    func testAggregatingAnyFailureReportsFailed() {
        struct Boom: Error {}
        let outcomes: [Result<VaultEvictionOutcome, Error>] = [.success(.evicted), .failure(Boom())]
        XCTAssertEqual(VaultICloudLocalState.aggregating(outcomes), .failed)
    }

    /// Every object reporting not-evictable is not the same as success; the
    /// aggregate must not claim eviction happened.
    func testAggregatingAllNotEvictableReportsUnavailable() {
        let outcomes: [Result<VaultEvictionOutcome, Error>] = [.success(.notEvictable), .success(.notEvictable)]
        XCTAssertEqual(VaultICloudLocalState.aggregating(outcomes), .unavailable)
    }

    /// No evictable object at all (the old single-arbitrary-object behavior
    /// this replaces) reports unavailable rather than a false success.
    func testAggregatingEmptyReportsUnavailable() {
        XCTAssertEqual(VaultICloudLocalState.aggregating([]), .unavailable)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
