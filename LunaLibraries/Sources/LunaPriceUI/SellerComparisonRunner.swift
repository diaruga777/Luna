//
//  SellerComparisonRunner.swift
//  LunaPriceUI
//

import Foundation
import LunaFetch
import LunaHTMLClassification
import LunaModels
import LunaPriceCompare
import LunaStorage

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

    /// One fan-out run. Nil where the product kind is not composed. `onResult`
    /// is called as each verified seller lands, which is what lets the store
    /// list fill in front of the user instead of all at once at the end.
    public typealias Run =
        @Sendable (SellerFanOutRequest, SellerFanOut.OnResult?) async -> SellerFanOutOutcome?

    /// The installed runner. Written ONLY by `ProductKindComposition.install()`
    /// in production; tests substitute a stub.
    public static var installed: Run?

    /// Installs the live fan-out. Idempotent.
    public static func install() {
        installed = { request, onResult in await liveRun(request, onResult: onResult) }
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
        guard store != nil || onResult != nil else { return await installed(request, nil) }
        let recording: SellerFanOut.OnResult = { result in
            store?.record(payload: result.snapshotPayload)
            await onResult?(result)
        }
        return await installed(request, recording)
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

    private static func liveRun(
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
    /// under one category, because the question a failing comparison raises —
    /// "it found nothing, why?" — is only answerable from the whole run: which
    /// retailers were chosen, what each answered, and what became of every link.
    /// Before this, twelve candidates and zero results left no trace at all.
    public static let logCategory = "SellerComparison"

    /// Returns `operation`'s value, or nil at `seconds`. Never throws, because
    /// every caller treats "no comparison" and "a comparison that found nothing"
    /// the same way at the surface — the save still lands.
    ///
    /// This used to be a task group with a sleeping second child, which is not a
    /// deadline at all: a group awaits every child when its scope exits, so the
    /// call returned when the WORK returned and the sleep leg only decided what
    /// the answer was called. Both caps here sat on top of work that ignores
    /// cancellation — a WKWebView render, `IngestPipeline`'s own (identically
    /// shaped, identically soft) 28 s timeout — so neither ever fired. A live
    /// AU run logged candidates 39 s in, past a 40 s hard cap it would never
    /// reach, and the intent that started it had long since handed off.
    /// `TimeLimit.run` is the same race with the work made unstructured, so the
    /// deadline can stop waiting without needing to stop the work.
    static func withDeadline<T: Sendable>(
        _ seconds: TimeInterval, _ operation: @escaping @Sendable () async -> T
    ) async -> T? {
        await TimeLimit.run(seconds, operation: operation)
    }
}
