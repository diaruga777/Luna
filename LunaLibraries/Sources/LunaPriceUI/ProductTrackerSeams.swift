//
//  ProductTrackerSeams.swift
//  LunaPriceUI
//

import Foundation
import LunaStorage

/// Starts the save-time alternative-seller fan-out for a freshly saved product.
///
/// Both save paths take one — the in-app ingestor and the extension's
/// immediate-editor path — because a fan-out that RUNS is the difference
/// between a save that grows sellers and one that never does, and a test that
/// is about seeding or merging must be able to hold it still without racing a
/// real run (`claudedocs/price-comparison.md`).
public protocol SellerComparisonStarting {
    func startComparison(itemID: UUID, sourceURL: URL, store: SavesStore)
}

/// Production: stamps the pending marker and runs the fan-out in the background
/// — and does nothing at all when the product kind isn't composed in this
/// process.
public struct BackgroundSellerComparisonStarter: SellerComparisonStarting {
    public init() {}

    public func startComparison(itemID: UUID, sourceURL: URL, store: SavesStore) {
        SellerComparison.beginAndRunInBackground(itemID: itemID, sourceURL: sourceURL, store: store)
    }
}

/// The immediate single-tracker refresh a just-seeded tracker gets, so a product
/// seeded from history shows a LIVE price right away.
public protocol SingleTrackerRefreshing {
    func refresh(itemID: UUID) async -> PriceRefreshOutcome?
}

/// Production: the real single-tracker coordinator.
public struct CoordinatorTrackerRefresher: SingleTrackerRefreshing {
    public init() {}

    public func refresh(itemID: UUID) async -> PriceRefreshOutcome? {
        await PriceRefreshCoordinator.shared.refreshTracker(itemID: itemID)
    }
}

/// Fetches a tracker's product artwork.
public protocol ProductArtworkLoading {
    /// The declared product image, else a page header image, else the favicon —
    /// whatever this conformer can get for the page.
    func artworkData(primaryURL: URL?, pageURL: URL) async -> Data?
}

/// Production: the complete product-artwork pass.
public struct ProductTrackerArtworkLoader: ProductArtworkLoading {
    public init() {}

    public func artworkData(primaryURL: URL?, pageURL: URL) async -> Data? {
        await ProductTrackerArtwork.fetch(primaryURL: primaryURL, pageURL: pageURL)
    }
}
