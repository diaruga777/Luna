//
//  ExtensionProductPresenter.swift
//  LunaPriceUI
//

import LunaHTMLClassification
import LunaModels
import LunaPriceCompare
import LunaShareSurface
import LunaStorage
import LunaURLClassification
import UIKit

/// The product-kind side of the extension surfaces: persist the tracker for a
/// classified product page, then present the SAME price-tracking editor the
/// main app shows (the extension host wraps it in Done chrome). Conforms to
/// `ShareProductPresenting` (LunaShareSurface) directly, so
/// `ProductKindComposition.install()` registers it as-is.
@MainActor
public final class ExtensionProductPresenter: ShareProductPresenting {

    /// Test seam: which snapshot store history-seeding reads. Production reads
    /// the shared App Group one.
    var snapshotStore: ProductSnapshotStore = .shared
    /// Test seam for the product-image write. The extension keeps the editor
    /// responsive while this finishes, but persists the file before its host
    /// process is dismissed whenever the network answers in time.
    var artworkLoader: any ProductArtworkLoading = ProductTrackerArtworkLoader()

    public init() {}

    /// Persists the tracker first so the editor has an item (falling back to a
    /// plain save confirmation when the row is gone).
    ///
    /// The editor opens IMMEDIATELY, on the one seller the user was actually
    /// looking at. The alternative-seller fan-out is started at the same moment
    /// and runs behind it: its "checking for other sellers" row is already in
    /// the list, and each retailer it verifies appears there as it lands.
    ///
    /// It used to hold a full-screen wait between the save and the editor — up
    /// to half a minute of other people's web servers, in a share sheet, for a
    /// tap the user had already made. What survives a share extension's early
    /// death is not the Task but the PENDING MARKER on the tracker: the app
    /// finishes the run at its next launch or its next refresh cycle.
    ///
    /// **Merges, rather than always creating.** Before this asked
    /// `ProductTrackerMerge` (shared with the in-app path — see
    /// `claudedocs/price-comparison.md`'s "Extension saves merge and seed"),
    /// a share-sheet save of a product already being tracked created a
    /// second, unrelated tracker even when both pages declared the SAME GTIN.
    /// On a merge the editor opens on the MATCHED tracker's item, in
    /// `.merge` mode, instead of duplicating — synchronously, with no image
    /// download or other await the extension cannot afford.
    public func presentPriceEditor(product: ProductInfo, url: URL, store: ReadingListStore, host: ExtensionHost) {
        let addSellerHandoff = ExtensionAddSellerHandoff(host: host)
        guard let placeholder = store.item(forURLString: url.absoluteString) else {
            host.confirmSavedThenComplete()
            return
        }

        let outcome = ProductTrackerMerge.mergeIfPossible(
            product: product, url: url, excludingItemID: placeholder.id, store: store,
            comparisonStarter: BackgroundSellerComparisonStarter(),
            snapshotStore: snapshotStore)

        let editor: PriceTrackingViewController
        switch outcome {
        case let .merged(matchID, highlightedURL):
            // The just-saved placeholder was a duplicate route into an
            // existing tracker; drop it so only the merged tracker remains.
            store.delete(placeholder)
            PriceTrackerSaveAnnouncement.post(
                itemID: matchID, source: placeholder.effectiveCaptureSource,
                isMerge: true, highlightedURL: highlightedURL)
            editor = PriceTrackingViewController(
                mode: .merge(
                    itemID: matchID, addedStoreURLString: highlightedURL ?? url.absoluteString,
                    host: .extension),
                addSellerHandoff: addSellerHandoff)
            backfillArtwork(
                itemID: matchID, primaryURL: product.imageURL, pageURL: url, store: store)

        case .newTracker:
            var tracker = product.makeTracker(
                fallbackURL: url,
                alertThresholdFraction: PriceAlertThresholdPolicy.initialThresholdFraction)
            // The same blocking read the in-app save makes. A share-sheet save
            // of a product Luna has already priced must be born with that
            // history too — this path used to seed only on the MERGE branch,
            // so a brand-new tracker from an extension started blank.
            ProductTrackerMerge.seedHistoryFromSnapshots(
                into: &tracker, candidate: product, candidateURL: url, store: snapshotStore)
            seedPracticeHistoryIfNeeded(into: &tracker, url: url)
            guard let itemID = store.savePriceTracker(
                tracker, forURLString: url.absoluteString)
            else {
                host.confirmSavedThenComplete()
                return
            }
            SellerComparison.beginAndRunInBackground(
                itemID: itemID, sourceURL: url, store: store)
            backfillArtwork(
                itemID: itemID, primaryURL: product.imageURL, pageURL: url, store: store)
            editor = PriceTrackingViewController(
                mode: .creation(itemID: itemID, host: .extension),
                addSellerHandoff: addSellerHandoff)
        }
        editor.onDone = { [weak host] in host?.confirmSavedThenComplete() }
        host.presentModally(editor)
    }

    private func backfillArtwork(
        itemID: UUID, primaryURL: URL?, pageURL: URL, store: ReadingListStore
    ) {
        guard store.item(withID: itemID)?.priceTracker?.imageFileName == nil else { return }
        Task { [artworkLoader] in
            guard let data = await artworkLoader.artworkData(
                primaryURL: primaryURL, pageURL: pageURL),
                  var tracker = store.item(withID: itemID)?.priceTracker,
                  tracker.imageFileName == nil
            else { return }
            let fileName = "\(itemID.uuidString)-product.jpg"
            let destination = store.articlesDirectory.appendingPathComponent(fileName)
            guard (try? data.write(to: destination, options: .atomic)) != nil else { return }
            tracker.imageFileName = fileName
            store.updatePriceTracker(tracker, for: itemID)
        }
    }

    /// The onboarding rehearsal's product arrives with a QUARTER of price
    /// history behind it (`ShareSetupPractice.practicePriceHistory`).
    ///
    /// Every other product this presenter opens is genuinely new, and an empty
    /// graph is the truth for it — the tracker starts watching now. The lesson
    /// is the one case where that truth teaches the wrong thing: the save lesson
    /// exists to show what tracking a price gets you, and it was showing an
    /// empty box captioned "no price history yet". Asked by URL, like every
    /// other practice decision (`ShareSetupPractice.matchesProductPractice`), so
    /// a real Amayzon-shaped save cannot pick this up by resembling it.
    private func seedPracticeHistoryIfNeeded(into tracker: inout PriceTracker, url: URL) {
        guard ShareSetupPractice.matchesProductPractice(url),
              let host = url.host
        else { return }
        tracker.mergeHistorySamples(
            ShareSetupPractice.practicePriceHistory(
                currentPrice: tracker.initialPrice, currency: tracker.initialCurrency),
            forHost: host,
            newStoreURLString: url.absoluteString)
    }
}

/// The extension's add-seller answer: a deep link back into the containing app,
/// which is the only process that can hold a web session open long enough to
/// search a retailer. The host is held weakly — it outlives nothing here.
private struct ExtensionAddSellerHandoff: AddSellerHandoffHandling {
    weak var host: (any ExtensionHost)?

    func openContainingApp(forAddingSellerTo itemID: UUID) {
        guard let link = LunaDeepLink.priceTrackerAddSellerLink(itemID: itemID) else { return }
        host?.openURL(link)
    }
}
