//
//  SellerComparisonTests.swift
//  LunaTests
//

import LunaHTMLClassification
import LunaModels
import LunaPriceCompare
import LunaStorage
import XCTest
@testable import LunaPriceUI

/// The save-time half of the alternative-seller comparison
/// (`claudedocs/price-comparison.md`): what the fan-out is ASKED, what happens
/// to what it finds, and the ordering that keeps the median honest.
final class SellerComparisonTests: XCTestCase {

    private var tempDirectory: URL!
    private var snapshotDirectory: URL?
    private var snapshotStore: ProductSnapshotStore!
    private var store: ReadingListStore!
    private var ingestor: ProductTrackerIngestor!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SellerComparisonTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        store = ReadingListStore(containerURL: tempDirectory)
        ingestor = ProductTrackerIngestor()
        ingestor.indexRegenerator = {}
        snapshotStore = .temporary(directory: &snapshotDirectory)
        ingestor.snapshotStore = snapshotStore
        SellerComparisonRunner.snapshotStore = snapshotStore
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        if let snapshotDirectory { try? FileManager.default.removeItem(at: snapshotDirectory) }
        SellerComparisonRunner.installed = nil
        SellerComparisonRunner.snapshotStore = .shared
        super.tearDown()
    }

    // MARK: - Fixtures

    private func tracker(
        price: String = "100", currency: String = "USD",
        urlString: String = "https://source.example/p/1",
        gtin: String? = "0012345678905"
    ) -> PriceTracker {
        PriceTracker(
            productName: "Acme Widget",
            firstStoreURL: urlString,
            price: Decimal(string: price)!,
            currency: currency,
            brand: "Acme",
            productID: gtin,
            identifiers: ProductIdentifiers(gtin: gtin, brand: "Acme"))
    }

    private func result(
        domain: String, price: String, currency: String = "USD",
        path: String = "/p/1", confidence: SellerMatchConfidence = .gtin
    ) -> ComparableSellerResult {
        ComparableSellerResult(
            sellerID: domain, sellerName: domain, domain: domain,
            url: URL(string: "https://\(domain)\(path)")!,
            price: Decimal(string: price)!, currency: currency,
            productName: "Acme Widget", identifiers: ProductIdentifiers(gtin: "0012345678905"),
            imageURL: nil, confidence: confidence, source: .directory)
    }

    // MARK: - The request

    /// The tracker's own stores are excluded, so a re-comparison never spends a
    /// candidate re-finding a seller that is already attached.
    func testRequestExcludesEveryStoreAlreadyOnTheTracker() {
        var subject = tracker()
        subject.upsertStore(PriceTrackerStore(
            urlString: "https://other.example/p/1", lastPrice: 90, currency: "USD"))
        let request = SellerComparison.request(
            for: subject, sourceURL: URL(string: "https://source.example/p/1")!)
        XCTAssertEqual(
            Set(request.excludedURLStrings),
            ["https://source.example/p/1", "https://other.example/p/1"])
    }

    /// A tracker saved before keyed identifiers existed still has a flattened
    /// `brand`; the request must carry it, or the name-similarity tier can never
    /// be brand-qualified and every name match is refused.
    func testRequestFallsBackToTheFlattenedBrand() {
        var subject = tracker(gtin: nil)
        subject.identifiers = ProductIdentifiers()
        let request = SellerComparison.request(
            for: subject, sourceURL: URL(string: "https://source.example/p/1")!)
        XCTAssertEqual(request.identifiers.brand, "Acme")
        XCTAssertEqual(request.productName, "Acme Widget")
    }

    // MARK: - Applying results

    func testEveryResultBecomesAStoreWithALivePriceAndARecordedSample() {
        var subject = tracker()
        let added = SellerComparison.apply(
            [result(domain: "a.example", price: "80"), result(domain: "b.example", price: "120")],
            to: &subject, at: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(added, 2)
        XCTAssertEqual(subject.stores.count, 3)
        let attached = subject.stores.first { $0.urlString.contains("a.example") }
        XCTAssertEqual(attached?.lastPrice, 80)
        XCTAssertNotNil(attached?.lastRefreshed)
        XCTAssertEqual(attached?.priceHistory.count, 1)
    }

    /// Attaching is now the STREAMING step — one seller at a time, as the
    /// fan-out finds them — so it deliberately leaves the baseline alone. The
    /// baseline is settled once, at the end, by `completePendingComparison`.
    func testAttachingDoesNotTouchTheBaselineOnItsOwn() {
        var subject = tracker(price: "100")
        SellerComparison.apply([result(domain: "a.example", price: "40")], to: &subject)
        XCTAssertEqual(subject.initialPrice, 100)
        XCTAssertNil(subject.alertAcknowledgedAt)
    }

    /// The request names the market: the currency of the page the tracker was
    /// created from, so the engine can refuse foreign-market results before a
    /// single one is fetched.
    func testRequestCarriesTheTrackersOwnCurrencyAsTheMarket() {
        let request = SellerComparison.request(
            for: tracker(currency: "AUD"), sourceURL: URL(string: "https://source.example/p/1")!)
        XCTAssertEqual(request.sourceCurrency, "AUD")
    }

    /// A seller priced in another currency must never reach the store list —
    /// there is no FX source, so it can neither be compared nor displayed as a
    /// better price. This is the tracker-side half of the market rule (the
    /// engine refuses them too, but a resumed run's stale results must not
    /// slip past).
    func testAForeignCurrencyResultIsNeverAttached() {
        var subject = tracker(currency: "AUD")
        let added = SellerComparison.apply(
            [
                result(domain: "us-shop.example", price: "40", currency: "USD"),
                result(domain: "au-shop.example", price: "80", currency: "AUD"),
            ],
            to: &subject)
        XCTAssertEqual(added, 1, "only the AUD seller may join an AUD tracker")
        XCTAssertFalse(subject.stores.contains { $0.urlString.contains("us-shop.example") })
        XCTAssertTrue(subject.stores.contains { $0.urlString.contains("au-shop.example") })
    }

    /// Two rows for the same shop is the one thing the store list must never
    /// show — and the engine's own per-domain key cannot know what the tracker
    /// already holds.
    func testASellerOnAHostTheTrackerAlreadyHoldsIsRefused() {
        var subject = tracker(urlString: "https://www.shop.example/p/1")
        let added = SellerComparison.apply(
            [result(domain: "shop.example", price: "80", path: "/p/2")], to: &subject)
        XCTAssertEqual(added, 0)
        XCTAssertEqual(subject.stores.count, 1)
    }

    /// A fan-out is a passive writer, so it may not undo the user's own
    /// removal: the seller they took off this tracker stays off, however
    /// cheaply it turns up again.
    func testASellerTheUserRemovedIsNeverReAttachedByAFanOut() {
        var subject = tracker()
        subject.upsertStore(PriceTrackerStore(
            urlString: "https://a.example/p/1", lastPrice: 90, currency: "USD"))
        XCTAssertTrue(subject.removeStore(urlString: "https://a.example/p/1"))

        let added = SellerComparison.apply(
            [result(domain: "a.example", price: "40", path: "/p/2"),
             result(domain: "b.example", price: "80")],
            to: &subject)
        XCTAssertEqual(added, 1)
        XCTAssertFalse(subject.stores.contains { $0.urlString.contains("a.example") })
    }

    // MARK: - The pending marker

    /// The marker is what survives the extension process that started the run.
    func testBeginningARunStampsAResumableMarker() {
        let item = store.add(urlString: "https://source.example/p/1")
        store.savePriceTracker(tracker(), for: item.id)
        installRunner(results: [])
        XCTAssertTrue(SellerComparison.begin(
            itemID: item.id, sourceURL: URL(string: "https://source.example/p/1")!, store: store))
        let pending = store.item(withID: item.id)?.priceTracker?.pendingComparison
        XCTAssertEqual(pending?.sourceURLString, "https://source.example/p/1")
    }

    /// Nothing pending where nothing can run: a "checking for other sellers" row
    /// for a run that will never happen is worse than no row.
    func testNoMarkerIsStampedWithNoRunnerInstalled() {
        SellerComparisonRunner.installed = nil
        let item = store.add(urlString: "https://source.example/p/1")
        store.savePriceTracker(tracker(), for: item.id)
        XCTAssertFalse(SellerComparison.begin(
            itemID: item.id, sourceURL: URL(string: "https://source.example/p/1")!, store: store))
        XCTAssertNil(store.item(withID: item.id)?.priceTracker?.pendingComparison)
    }

    /// The resume path, exactly as a launch or a refresh cycle runs it: a marker
    /// left by a dead process, finished by a live one.
    func testAMarkerLeftByADeadProcessIsResumedAndCleared() async {
        let item = store.add(urlString: "https://source.example/p/1")
        var subject = tracker()
        subject.beginPendingComparison(sourceURLString: "https://source.example/p/1")
        store.savePriceTracker(subject, for: item.id)
        installRunner(results: [result(domain: "a.example", price: "80")])

        let finished = await SellerComparison.completePending(store: store)

        XCTAssertEqual(finished, 1)
        let saved = store.item(withID: item.id)?.priceTracker
        XCTAssertNil(saved?.pendingComparison, "the row must not wait forever")
        XCTAssertEqual(saved?.stores.count, 2)
    }

    /// A run that found nothing is a FINISHED run. Leaving the marker would
    /// leave a spinner turning until the end of time.
    func testARunThatFoundNothingStillClearsTheMarker() async {
        let item = store.add(urlString: "https://source.example/p/1")
        store.savePriceTracker(tracker(), for: item.id)
        installRunner(results: [])
        _ = await runAndAttach(
            itemID: item.id, sourceURL: URL(string: "https://source.example/p/1")!, store: store)
        XCTAssertNil(store.item(withID: item.id)?.priceTracker?.pendingComparison)
    }

    /// With no runner in THIS process the marker is left alone, so an app that
    /// does compose the product kind can still pick the run up.
    func testAMarkerSurvivesAProcessThatCannotRunTheFanOut() async {
        let item = store.add(urlString: "https://source.example/p/1")
        var subject = tracker()
        subject.beginPendingComparison(sourceURLString: "https://source.example/p/1")
        store.savePriceTracker(subject, for: item.id)
        SellerComparisonRunner.installed = nil

        let finished = await SellerComparison.completePending(store: store)
        XCTAssertEqual(finished, 0)
        XCTAssertNotNil(store.item(withID: item.id)?.priceTracker?.pendingComparison)
    }

    /// Sellers arrive one at a time, so the list fills in front of the user
    /// rather than appearing all at once when the run ends.
    func testEachSellerIsPersistedAsItLandsRatherThanAtTheEnd() async {
        let item = store.add(urlString: "https://source.example/p/1")
        store.savePriceTracker(tracker(), for: item.id)
        let results = [result(domain: "a.example", price: "80"),
                       result(domain: "b.example", price: "120")]
        var countsSeenDuringTheRun: [Int] = []
        SellerComparisonRunner.installed = { [store] _, onResult in
            for found in results {
                await onResult?(found)
                countsSeenDuringTheRun.append(
                    store?.item(withID: item.id)?.priceTracker?.stores.count ?? 0)
            }
            return SellerFanOutOutcome(
                results: results, attemptedSellerIDs: [], stopReason: .reachedTarget)
        }
        _ = await runAndAttach(
            itemID: item.id, sourceURL: URL(string: "https://source.example/p/1")!, store: store)
        XCTAssertEqual(countsSeenDuringTheRun, [2, 3], "persisted as each one landed")
    }

    // MARK: - The baseline, and whose decision it is

    /// The default path: the user never touched the alert configuration, so the
    /// median becomes the baseline — the cheapest of a dozen sellers is the
    /// going rate at the moment of saving, not a drop worth hearing about.
    func testAnUntouchedTrackerGetsTheMedianBaselineAndNoBadge() async {
        let item = store.add(urlString: "https://source.example/p/1")
        var subject = tracker(price: "100")
        subject.setAlertThresholdFraction(0.10)
        store.savePriceTracker(subject, for: item.id)
        installRunner(results: [result(domain: "a.example", price: "50"),
                                result(domain: "b.example", price: "60")])

        _ = await runAndAttach(
            itemID: item.id, sourceURL: URL(string: "https://source.example/p/1")!, store: store)

        let saved = store.item(withID: item.id)!.priceTracker!
        XCTAssertEqual(saved.initialPrice, 60, "median of 100, 60, 50")
        XCTAssertTrue(saved.isAlerting, "the cheapest seller really is below the threshold")
        XCTAssertFalse(saved.hasUnviewedAlert, "but that must not badge the row at save time")
    }

    /// **The touched-threshold rule.** A user who adjusted the alert before the
    /// fan-out came back chose a number against the price they could SEE. They
    /// are owed the alert that number implies, so their configuration stands,
    /// the baseline is not re-based under them, and a cheaper seller arriving
    /// from the fan-out is allowed to cross the line — which is the intended
    /// behaviour, not an accident.
    func testATouchedThresholdIsRespectedAndTheArrivingSellerMayAlert() async {
        let item = store.add(urlString: "https://source.example/p/1")
        var subject = tracker(price: "100")
        subject.setAlertThresholdFraction(0.10)
        store.savePriceTracker(subject, for: item.id)
        installRunner(
            results: [result(domain: "a.example", price: "50")],
            beforeReturning: {
                // The user drags the slider while the fan-out is still out.
                guard var live = self.store.item(withID: item.id)?.priceTracker else { return }
                live.setAlertThresholdFraction(0.25)
                self.store.updatePriceTracker(live, for: item.id)
            })

        _ = await runAndAttach(
            itemID: item.id, sourceURL: URL(string: "https://source.example/p/1")!, store: store)

        let saved = store.item(withID: item.id)!.priceTracker!
        XCTAssertEqual(saved.alertThresholdFraction, 0.25, "their number, untouched")
        XCTAssertEqual(saved.initialPrice, 100, "and their baseline, untouched")
        XCTAssertTrue(saved.isAlerting)
        XCTAssertTrue(
            saved.hasUnviewedAlert,
            "a genuine alert: they set the threshold themselves and a seller crossed it")
        XCTAssertNil(saved.pendingComparison)
    }

    /// Clearing the alert entirely counts as touching it.
    func testClearingTheThresholdAlsoCountsAsTouchingIt() {
        var subject = tracker(price: "100")
        subject.setAlertThresholdFraction(0.10)
        subject.beginPendingComparison(sourceURLString: "https://source.example/p/1")
        subject.clearAlertThreshold()
        XCTAssertTrue(subject.alertConfigurationChangedSincePendingComparison)
        XCTAssertFalse(subject.completePendingComparison())
        XCTAssertEqual(subject.initialPrice, 100)
    }

    /// The market rule at the end of a whole run: a foreign-currency result is
    /// never attached at all (it used to join the list and merely sit out the
    /// median — a GBP row in a USD seller list was exactly the reported bug),
    /// and the baseline settles on the market-currency stores alone.
    func testAForeignCurrencySellerIsNeverAttachedAndTheMedianIgnoresIt() async {
        let item = store.add(urlString: "https://source.example/p/1")
        store.savePriceTracker(tracker(price: "100", currency: "USD"), for: item.id)
        installRunner(results: [result(domain: "a.example", price: "1", currency: "GBP"),
                                result(domain: "b.example", price: "140", currency: "USD")])
        _ = await runAndAttach(
            itemID: item.id, sourceURL: URL(string: "https://source.example/p/1")!, store: store)
        let saved = store.item(withID: item.id)!.priceTracker!
        XCTAssertEqual(saved.stores.count, 2, "the GBP seller must not appear in the list")
        XCTAssertFalse(saved.stores.contains { $0.urlString.contains("a.example") })
        XCTAssertEqual(saved.initialPrice, 120, "median of the two USD stores")
    }

    // MARK: - Through the ingestor

    private func product() -> ProductInfo {
        ProductInfo(
            name: "Acme Widget", priceAmount: 100, priceCurrency: "USD",
            imageURL: nil, brand: "Acme", productID: "0012345678905",
            identifiers: ProductIdentifiers(gtin: "0012345678905", brand: "Acme"))
    }

    /// The save does not WAIT for the fan-out any more: the ingestor starts it
    /// and returns, and the card the announcement centers is already on screen.
    func testANewTrackerStartsAComparisonWithoutWaitingForIt() async {
        let item = store.add(urlString: "https://source.example/p/1")
        var started: [String] = []
        ingestor.comparisonStarter = { _, url, _ in started.append(url.absoluteString) }
        ingestor.refreshRunner = { _ in nil }

        await ingestor.ingest(
            item, url: URL(string: "https://source.example/p/1")!,
            product: product(), store: store)

        XCTAssertEqual(started, ["https://source.example/p/1"])
        XCTAssertEqual(store.item(withID: item.id)?.priceTracker?.stores.count, 1)
    }

    /// The merge path is NOT compared once a tracker has already BEEN
    /// through a fan-out (2+ stores, or a run already pending) — re-running
    /// would spend a dozen candidates re-finding the stores it is excluding.
    /// A merge into a tracker that has never had one is the Fix-8 carve-out,
    /// covered separately below.
    func testMergingIntoAnAlreadyComparedTrackerRunsNoComparison() async {
        let existing = store.add(urlString: "https://source.example/p/1")
        var tracker = PriceTracker(
            productName: "Acme Widget", firstStoreURL: "https://source.example/p/1",
            price: 100, currency: "USD", brand: "Acme", productID: "0012345678905")
        tracker.upsertStore(
            PriceTrackerStore(urlString: "https://other.example/p/1", lastPrice: 90, currency: "USD"))
        store.savePriceTracker(tracker, for: existing.id)
        let incoming = store.add(urlString: "https://source.example/p/1?ref=x")
        var ran = false
        ingestor.comparisonStarter = { _, _, _ in ran = true }
        ingestor.refreshRunner = { _ in nil }

        await ingestor.ingest(
            incoming, url: URL(string: "https://source.example/p/1?ref=x")!,
            product: product(), store: store)

        XCTAssertFalse(ran)
    }

    /// Fix 8's carve-out: a merge into a tracker that has NEVER been through
    /// a fan-out (still one store, no pendingComparison) DOES kick a
    /// comparison — the rule above was written for a tracker that had
    /// already had one, not for one a prior save merely created and left
    /// alone.
    func testMergingIntoANeverComparedSellerlessTrackerKicksAComparison() async {
        let existing = store.add(urlString: "https://source.example/p/1")
        store.savePriceTracker(
            PriceTracker(
                productName: "Acme Widget", firstStoreURL: "https://source.example/p/1",
                price: 100, currency: "USD", brand: "Acme", productID: "0012345678905"),
            for: existing.id)
        let incoming = store.add(urlString: "https://source.example/p/1?ref=x")
        var kickedItemID: UUID?
        ingestor.comparisonStarter = { itemID, _, _ in kickedItemID = itemID }
        ingestor.refreshRunner = { _ in nil }

        await ingestor.ingest(
            incoming, url: URL(string: "https://source.example/p/1?ref=x")!,
            product: product(), store: store)

        XCTAssertEqual(kickedItemID, existing.id)
    }

    /// No runner installed (an app that doesn't compose the product kind, or a
    /// process that hasn't) must be indistinguishable from a comparison that
    /// found nothing — the save still lands, unchanged.
    func testWithNoRunnerInstalledNothingIsAttachedAndNothingFails() async {
        SellerComparisonRunner.installed = nil
        let item = store.add(urlString: "https://source.example/p/1")
        let added = await runAndAttach(
            itemID: item.id, sourceURL: URL(string: "https://source.example/p/1")!, store: store)
        XCTAssertEqual(added, 0)
    }

    func testAnInstalledRunnerAttachesWhatItFinds() async {
        let item = store.add(urlString: "https://source.example/p/1")
        store.savePriceTracker(tracker(), for: item.id)
        installRunner(results: [result(domain: "a.example", price: "80")])
        let added = await runAndAttach(
            itemID: item.id, sourceURL: URL(string: "https://source.example/p/1")!, store: store)
        XCTAssertEqual(added, 1)
        XCTAssertEqual(store.item(withID: item.id)?.priceTracker?.stores.count, 2)
    }

    // MARK: - Fan-out results are observations

    /// Every seller the fan-out priced is a product observation, and gets
    /// recorded — INCLUDING the ones this tracker refuses to attach. A seller
    /// in another currency is useless to a USD tracker's graph today and still
    /// perfectly good history for a tracker created in that market tomorrow;
    /// before this, twelve fetched prices were thrown away every save.
    func testEveryFanOutResultIsRecordedAsAnObservationEvenWhenNotAttached() async {
        let item = store.add(urlString: "https://source.example/p/1")
        store.savePriceTracker(tracker(), for: item.id)
        installRunner(results: [
            result(domain: "a.example", price: "80"),
            result(domain: "b.example", price: "70", currency: "GBP"),
        ])

        let added = await runAndAttach(
            itemID: item.id, sourceURL: URL(string: "https://source.example/p/1")!, store: store)

        XCTAssertEqual(added, 1, "only the same-currency seller joins the tracker")
        let observed = snapshotStore
            .snapshots(forKeys: ProductSnapshotKeys.gtinKeys("0012345678905"))
        XCTAssertEqual(
            Set(observed.map(\.host)), Set(["a.example", "b.example"]),
            "both fetched prices must be observable, whatever the tracker did with them")
        XCTAssertEqual(
            observed.first { $0.host == "b.example" }?.currency, "GBP")
    }

    /// The recorded observation is retrievable by the seller's own identifier,
    /// which is the whole point: a later save of that product finds it without
    /// ever having seen that URL.
    func testAFanOutObservationSeedsALaterSaveOfTheSameProduct() async {
        let item = store.add(urlString: "https://source.example/p/1")
        store.savePriceTracker(tracker(), for: item.id)
        installRunner(results: [result(domain: "a.example", price: "80")])
        _ = await runAndAttach(
            itemID: item.id, sourceURL: URL(string: "https://source.example/p/1")!, store: store)

        var later = PriceTracker(
            productName: "Acme Widget", firstStoreURL: "https://elsewhere.example/p/9",
            price: 95, currency: "USD",
            identifiers: ProductIdentifiers(gtin: "0012345678905"))
        ProductTrackerMerge.seedHistoryFromSnapshots(
            into: &later,
            candidate: ProductInfo(
                name: "Acme Widget", priceAmount: 95, priceCurrency: "USD", imageURL: nil,
                brand: "Acme", productID: "0012345678905",
                identifiers: ProductIdentifiers(gtin: "0012345678905")),
            candidateURL: URL(string: "https://elsewhere.example/p/9")!,
            store: snapshotStore)

        let seeded = later.stores.first { $0.urlString.contains("a.example") }
        XCTAssertNotNil(seeded, "the fan-out's price must reach a later tracker's graph")
        XCTAssertEqual(seeded?.priceHistory.first?.lowestPrice, 80)
    }

    // MARK: - The opportunistic completion hooks

    /// A refresh cycle opens by finishing whatever a dead process left behind.
    /// The sweep both hooks call: it takes every tracker carrying a marker, and
    /// nothing else.
    func testTheSweepPicksUpEveryPendingTrackerAndSkipsTheRest() async {
        let pending = store.add(urlString: "https://source.example/p/1")
        var withMarker = tracker()
        withMarker.beginPendingComparison(sourceURLString: "https://source.example/p/1")
        store.savePriceTracker(withMarker, for: pending.id)

        let settled = store.add(urlString: "https://other.example/p/1")
        store.savePriceTracker(tracker(urlString: "https://other.example/p/1"), for: settled.id)

        installRunner(results: [result(domain: "a.example", price: "80")])
        let finished = await SellerComparison.completePending(store: store)

        XCTAssertEqual(finished, 1)
        XCTAssertEqual(store.item(withID: pending.id)?.priceTracker?.stores.count, 2)
        XCTAssertEqual(
            store.item(withID: settled.id)?.priceTracker?.stores.count, 1,
            "a tracker with no marker is not re-compared")
    }

    /// An archived tracker is out of the background refresh; it is out of this
    /// too, rather than spending a dozen retailers on something nobody watches.
    func testAnArchivedTrackerIsNotSweptUp() async {
        let item = store.add(urlString: "https://source.example/p/1")
        var subject = tracker()
        subject.beginPendingComparison(sourceURLString: "https://source.example/p/1")
        subject.isArchived = true
        store.savePriceTracker(subject, for: item.id)
        installRunner(results: [result(domain: "a.example", price: "80")])

        let finished = await SellerComparison.completePending(store: store)
        XCTAssertEqual(finished, 0)
    }

    /// Two callers, one run. The intent's summary asking for a comparison the
    /// share extension started a moment ago must WAIT for it rather than fan out
    /// across the same dozen retailers again.
    func testASecondCallerJoinsTheRunInFlightRatherThanStartingAnother() async {
        let item = store.add(urlString: "https://source.example/p/1")
        var subject = tracker()
        subject.beginPendingComparison(sourceURLString: "https://source.example/p/1")
        store.savePriceTracker(subject, for: item.id)

        let runs = Counter()
        SellerComparisonRunner.installed = { _, onResult in
            await runs.increment()
            try? await Task.sleep(nanoseconds: 120_000_000)
            let found = self.result(domain: "a.example", price: "80")
            await onResult?(found)
            return SellerFanOutOutcome(
                results: [found], attemptedSellerIDs: [], stopReason: .reachedTarget)
        }

        async let first = SellerComparison.complete(itemID: item.id, store: store)
        async let second = SellerComparison.complete(itemID: item.id, store: store)
        _ = await (first, second)

        let count = await runs.value
        XCTAssertEqual(count, 1, "one fan-out, two callers")
        XCTAssertEqual(store.item(withID: item.id)?.priceTracker?.stores.count, 2)
    }

    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    // MARK: - Helpers

    /// A stub fan-out that streams `results` and then returns them.
    /// `beforeReturning` runs after the last one has landed and before the run
    /// settles the baseline — the window in which the user can touch the alert.
    private func installRunner(
        results: [ComparableSellerResult],
        beforeReturning: (@Sendable () -> Void)? = nil
    ) {
        SellerComparisonRunner.installed = { _, onResult in
            for found in results { await onResult?(found) }
            beforeReturning?()
            return SellerFanOutOutcome(
                results: results, attemptedSellerIDs: [], stopReason: .reachedTarget)
        }
    }

    /// The whole save-time leg, START TO FINISH, for a tracker already persisted
    /// under `itemID` — `begin` + `complete` are the live production API; this
    /// test-only helper just chains them the way `beginAndRunInBackground` and
    /// `ProductIntentHandoff` each do inline, without detaching a background task.
    @discardableResult
    private func runAndAttach(
        itemID: UUID, sourceURL: URL, store: ReadingListStore, now: Date = Date()
    ) async -> Int {
        if store.item(withID: itemID)?.priceTracker?.pendingComparison == nil {
            guard SellerComparison.begin(itemID: itemID, sourceURL: sourceURL, store: store, now: now)
            else { return 0 }
        }
        return await SellerComparison.complete(itemID: itemID, store: store, now: now)
    }
}
