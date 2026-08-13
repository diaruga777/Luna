//
//  SellerComparisonRunner.swift
//  LunaPriceUI
//

import Foundation
import LunaModels
import LunaPriceCompare
import LunaStorage

/// One fan-out run, whoever runs it. `onResult` is called as each verified
/// seller lands, which is what lets the store list fill in front of the user
/// instead of all at once at the end.
///
/// It is a contract rather than a call because every surface asks
/// `SellerComparisonRunner.installed`, and a process that did not compose the
/// product kind installs nothing — "no comparison ran" and "no other seller
/// sells this" are different answers and must stay so.
public protocol SellerFanOutRunning: Sendable {
    func run(
        _ request: SellerFanOutRequest, onResult: SellerFanOut.OnResult?
    ) async -> SellerFanOutOutcome?
}

/// The live run: the full profile against `PipelineSellerNetworking`, bounded by
/// an outer hard cap and logged per candidate.
public struct LiveSellerFanOutRunner: SellerFanOutRunning {
    public init() {}

    public func run(
        _ request: SellerFanOutRequest, onResult: SellerFanOut.OnResult?
    ) async -> SellerFanOutOutcome? {
        await SellerComparisonRunner.liveRun(request, onResult: onResult)
    }
}

/// The alternative-seller fan-out as the APP surfaces run it: the lean engine
/// (`LunaPriceCompare`) wired to real networking and to the whole shared ingest
/// pipeline.
///
/// The engine deliberately makes no request of its own, because the same
/// orchestration also has to run inside a Safari appex that can link almost
/// nothing (`claudedocs/price-comparison.md`). This type is the OTHER end of
/// that trade: it runs the full profile against `PipelineSellerNetworking`, the
/// conformer that has every leg the engine offers.
///
/// **It is installed rather than called.** `ProductKindComposition.install()`
/// fills `installed`, so a process that did not compose the product kind has no
/// fan-out at all and every surface skips the comparison instead of guessing
/// (the same shape as `ActionButtonIntentSupport`'s media seams).
public enum SellerComparisonRunner {

    /// The installed runner. Written ONLY by `ProductKindComposition.install()`
    /// in production; tests substitute a stub. Nil where the product kind is not
    /// composed, and that nil is load-bearing — `SellerComparison` refuses to
    /// stamp a pending marker for a run that can never happen.
    public static var installed: (any SellerFanOutRunning)?

    /// Installs the live fan-out. Idempotent.
    public static func install() {
        installed = LiveSellerFanOutRunner()
    }

    /// Where fan-out results are recorded as product snapshots. Test seam; nil
    /// disables recording.
    public static var snapshotStore: ProductSnapshotStore? = .shared

    /// Runs the fan-out if one is installed. Nil means "no comparison ran" —
    /// which is not the same as "no other seller sells this", and callers must
    /// keep the distinction (nothing is seeded from a nil).
    ///
    /// **Every result is recorded as a product snapshot on the way past** —
    /// each one is a named product at a price on one retailer's page, which is
    /// exactly what a snapshot is. That includes the results the caller will
    /// DROP (a retailer the tracker already has, a foreign currency): they are
    /// still observations, and a later save of that product deserves them.
    /// The Safari appex's own fan-out has always done this
    /// (`ComparableSellerFinder`); this is the app-side half.
    public static func run(
        _ request: SellerFanOutRequest, onResult: SellerFanOut.OnResult? = nil
    ) async -> SellerFanOutOutcome? {
        guard let installed else { return nil }
        let store = snapshotStore
        guard store != nil || onResult != nil else {
            return await installed.run(request, onResult: nil)
        }
        let recording: SellerFanOut.OnResult = { result in
            store?.record(payload: result.snapshotPayload)
            await onResult?(result)
        }
        return await installed.run(request, onResult: recording)
    }

    // MARK: - The live wiring

    /// The profile every app surface uses. The Safari appex's `.constrained`
    /// profile is B3's; nothing here may quietly become the other one.
    public static let profile: SellerFanOutProfile = .full

    /// Slack over the engine's own `totalBudget` before the OUTER cap fires.
    /// The engine checks its budget between candidates, so a single fetch that
    /// somehow outlives its `URLRequest` timeout could otherwise hold a save
    /// surface open indefinitely.
    public static let hardCapGrace: TimeInterval = 5

    static func liveRun(
        _ request: SellerFanOutRequest, onResult: SellerFanOut.OnResult?
    ) async -> SellerFanOutOutcome? {
        // Refuse the WHOLE run up front in a test process rather than letting a
        // dozen candidate fetches each be refused individually. `installed` is
        // filled at launch and the test host is the central Luna app, so any
        // test that drives a product save reaches this — see `LiveNetworkPolicy`.
        guard LiveNetworkPolicy.allows(
            request.sourceURL, context: "SellerComparisonRunner.liveRun") else { return nil }
        guard let directory = try? SellerDirectory.bundled() else { return nil }
        let fanOut = SellerFanOut(
            directory: directory,
            profile: profile,
            networking: PipelineSellerNetworking(profile: profile),
            onResult: onResult,
            onAttempt: { attempt in
                DiagnosticLog.shared.record(attempt.logLine, category: logCategory)
            })
        let outcome = await withDeadline(profile.totalBudget + hardCapGrace) {
            await fanOut.run(request)
        }
        DiagnosticLog.shared.record(
            outcome.map(\.logSummary)
                ?? "fan-out for \(request.sourceURL.host ?? "?") hit the hard cap",
            category: logCategory)
        return outcome
    }

    /// Everything the fan-out does goes to the app's shareable diagnostic log
    /// under one category, because answering "it found nothing, why?" needs
    /// the whole run: which retailers were chosen, what each answered, and
    /// what became of every link.
    public static let logCategory = "SellerComparison"

    /// Returns `operation`'s value, or nil at `seconds`. Never throws, because
    /// every caller treats "no comparison" and "a comparison that found nothing"
    /// the same way at the surface — the save still lands.
    ///
    /// `TimeLimit.run` races `operation` directly instead of through a task
    /// group, so the deadline can stop WAITING on it without needing to
    /// cancel it. A WKWebView render and `IngestPipeline`'s own 28s timeout
    /// both ignore cancellation, so a group-based deadline would still block
    /// on the full operation before returning.
    static func withDeadline<T: Sendable>(
        _ seconds: TimeInterval, _ operation: @escaping @Sendable () async -> T
    ) async -> T? {
        await TimeLimit.run(seconds, operation: operation)
    }
}
