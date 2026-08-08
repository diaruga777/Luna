//
//  StageCatalog+Product.swift
//  Luna
//
//  Product-kind stages. Compiled ONLY into the targets that link the product
//  kind (Luna, LunaPriceTracker); the other two exclude this file by membership
//  exception, as they already exclude `PriceTracker/ProductCardContent.swift`.
//

#if DEBUG

import LunaHTMLClassification
import LunaModels
import LunaPriceUI
import LunaStorage
import UIKit

enum ProductStageCatalog {

    @MainActor
    static func install() {
        StageRegistry.register(deckStages + editorStages + graphStages)
    }

    private static let gadgetURL = "https://store.example.com/gadget"
    private static let kettleURL = "https://store.example.com/kettle"

    // MARK: - The deck

    @MainActor
    private static var deckStages: [StageDescriptor] {
        [
            StageDescriptor(
                id: "deck.product.empty", screen: "Card deck", variant: "no trackers",
                summary: "The price deck with nothing tracked.",
                kind: .product,
                seed: {
                    StageFixtures.completeOnboarding()
                    StageFixtures.seedEmpty()
                }),
            StageDescriptor(
                id: "deck.product.steady", screen: "Card deck", variant: "price holding",
                summary: "A tracker whose price has not moved: the product card with a flat "
                    + "series and no alert.",
                kind: .product,
                seed: {
                    StageFixtures.completeOnboarding()
                    StageFixtures.seed([
                        StageFixtures.steadyTracker(
                            seed: "stage-kettle", name: "The Only Kettle", url: kettleURL,
                            price: 129.99, daysAgo: 5),
                    ])
                }),
            StageDescriptor(
                id: "deck.product.alerting", screen: "Card deck", variant: "price drop",
                summary: "A drop past the alert threshold, unacknowledged: the badged card "
                    + "that floats to the top of the whole list.",
                kind: .product,
                seed: {
                    StageFixtures.completeOnboarding()
                    StageFixtures.seed([
                        StageFixtures.alertingTracker(
                            seed: "stage-gadget", name: "Discounted Gadget", url: gadgetURL,
                            from: 200, to: 150, daysAgo: 3),
                        StageFixtures.steadyTracker(
                            seed: "stage-kettle", name: "The Only Kettle", url: kettleURL,
                            price: 129.99, daysAgo: 5),
                    ])
                }),
            StageDescriptor(
                id: "deck.product.compared", screen: "Card deck", variant: "many sellers",
                summary: "What a save-time fan-out leaves behind: six retailers, the "
                    + "cheapest tinted, and a seller list taller than its viewport.",
                kind: .product,
                seed: {
                    StageFixtures.completeOnboarding()
                    StageFixtures.seed([comparedTracker()])
                }),
            StageDescriptor(
                id: "deck.product.pending", screen: "Card deck", variant: "never refreshed",
                summary: "A tracker saved but not yet priced — what the card shows before "
                    + "the first refresh lands.",
                kind: .product,
                seed: {
                    StageFixtures.completeOnboarding()
                    StageFixtures.seed([
                        StageFixtures.pendingTracker(
                            seed: "stage-pending", name: "Pending Keyboard",
                            url: "https://store.example.com/keyboard", price: 120, daysAgo: 1),
                    ])
                }),
        ]
    }

    // MARK: - The price editor

    @MainActor
    private static var editorStages: [StageDescriptor] {
        [
            StageDescriptor(
                id: "price.editor.alerting", screen: "Price editor", variant: "price drop",
                summary: "The full editor over a tracker past its threshold: graph, "
                    + "threshold line, seller list.",
                kind: .product,
                seed: {
                    StageFixtures.seed([
                        StageFixtures.alertingTracker(
                            seed: "stage-gadget", name: "Discounted Gadget", url: gadgetURL,
                            from: 200, to: 150, daysAgo: 3),
                    ])
                },
                make: { editor(seed: "stage-gadget") }),
            StageDescriptor(
                id: "price.editor.no-threshold", screen: "Price editor", variant: "no alert set",
                summary: "No threshold yet: the alert row parked and dimmed behind its "
                    + "'Set price alert' button, and no line on the graph.",
                kind: .product,
                seed: {
                    StageFixtures.seed([
                        StageFixtures.pendingTracker(
                            seed: "stage-nothreshold", name: "Untracked Kettle", url: kettleURL,
                            price: 129.99, daysAgo: 2, alertThresholdFraction: nil),
                    ])
                },
                make: { editor(seed: "stage-nothreshold") }),
            StageDescriptor(
                id: "price.editor.creation", screen: "Price editor", variant: "just saved",
                summary: "The chrome a save-time editor wears in the app: the header's "
                    + "back chevron, and no floating exit.",
                kind: .product,
                seed: {
                    StageFixtures.seed([
                        StageFixtures.steadyTracker(
                            seed: "stage-kettle", name: "The Only Kettle", url: kettleURL,
                            price: 129.99, daysAgo: 0),
                    ])
                },
                make: {
                    editor(mode: .creation(
                        itemID: ReadingListItem.deterministicUUID(from: "stage-kettle"),
                        host: .inApp))
                }),
            StageDescriptor(
                id: "price.editor.extension", screen: "Price editor",
                variant: "in a share sheet",
                summary: "The extension-hosted editor: no back chevron, the floating "
                    + "glass exit standing the seller list up, and a marketplace title "
                    + "trimmed to its product name with the rest kept underneath.",
                kind: .product,
                seed: {
                    StageFixtures.seed([
                        StageFixtures.pendingTracker(
                            seed: "stage-longtitle",
                            name: "Panasonic spare blade men's shaver 6-blade ES9600 : "
                                + "Amazon.com.au: Health, Household & Personal Care",
                            url: "https://www.amazon.com.au/dp/B003FGWPPS",
                            price: 116.33, daysAgo: 0, alertThresholdFraction: nil),
                    ])
                },
                make: {
                    editor(mode: .creation(
                        itemID: ReadingListItem.deterministicUUID(from: "stage-longtitle"),
                        host: .extension))
                }),
            StageDescriptor(
                id: "price.editor.compared", screen: "Price editor", variant: "many sellers",
                summary: "The same six retailers in the editor: the list scrolls, and the "
                    + "cut lands mid-row rather than just past the first one.",
                kind: .product,
                seed: { StageFixtures.seed([comparedTracker()]) },
                make: { editor(seed: "stage-compared") }),
            StageDescriptor(
                id: "price.editor.merge", screen: "Price editor", variant: "second seller added",
                summary: "A second store for a product already tracked: the added seller "
                    + "flashes green in the list.",
                kind: .product,
                seed: {
                    StageFixtures.seed([
                        StageFixtures.alertingTracker(
                            seed: "stage-gadget", name: "Discounted Gadget", url: gadgetURL,
                            from: 200, to: 150, daysAgo: 3),
                    ])
                },
                make: {
                    editor(mode: .merge(
                        itemID: ReadingListItem.deterministicUUID(from: "stage-gadget"),
                        addedStoreURLString: "https://otherstore.example.com/gadget",
                        host: .inApp))
                }),
        ]
    }

    /// A tracker the alternative-seller fan-out has finished with: one product,
    /// six real retailers, one of them cheapest. Real hosts because the seller
    /// rows name a retailer from the bundled directory and fetch its favicon —
    /// `store.example.com` exercises neither.
    private static func comparedTracker() -> ReadingListItem {
        let sellers: [(String, Decimal)] = [
            ("https://www.jbhifi.com.au/products/kettle", 129.99),
            ("https://www.amazon.com.au/dp/B003FGWPPS", 124.50),
            ("https://www.thegoodguys.com.au/kettle", 139.00),
            ("https://www.myer.com.au/p/kettle", 145.00),
            ("https://www.harveynorman.com.au/kettle", 132.95),
            ("https://www.kmart.com.au/product/kettle", 149.00),
        ]
        var tracker = PriceTracker(
            productName: "Smeg KLF03 50's Retro Style Electric Kettle, Pastel Blue "
                + "| The Good Guys",
            firstStoreURL: sellers[0].0, price: sellers[0].1, currency: "AUD",
            brand: "Smeg", productID: "stage-compared", now: StageFixtures.ago(days: 6))
        for offset in [5, 4, 3, 2, 1] {
            tracker.recordPriceSample(
                Decimal(129 - offset), currency: "AUD", urlString: sellers[0].0,
                at: StageFixtures.ago(days: offset))
        }
        for (url, price) in sellers.dropFirst() {
            tracker.upsertStore(PriceTrackerStore(
                urlString: url, lastPrice: price, currency: "AUD",
                lastRefreshed: StageFixtures.ago(hours: 5)))
        }
        return ReadingListItem(
            seed: "stage-compared", urlString: sellers[0].0,
            title: tracker.productName, dateAdded: StageFixtures.ago(days: 6),
            state: .ready, captureSource: .manual, priceTracker: tracker)
    }

    @MainActor
    private static func editor(seed: String) -> UIViewController {
        editor(mode: .existing(itemID: ReadingListItem.deterministicUUID(from: seed)))
    }

    @MainActor
    private static func editor(mode: PriceTrackingViewController.Mode) -> UIViewController {
        // `StagedPriceFetcher` rather than the real one: the editor refreshes on
        // appear, and a live scrape would move the price the stage exists to show.
        UINavigationController(
            rootViewController: PriceTrackingViewController(
                mode: mode, priceFetcher: StagedPriceFetcher()))
    }

    // MARK: - The graph, on its own

    /// The graph is the one price surface that takes its whole state as
    /// arguments, so its variants cost nothing and are worth having: they are
    /// what a reviewer actually compares.
    @MainActor
    private static var graphStages: [StageDescriptor] {
        [
            StageDescriptor(
                id: "price.graph.empty", screen: "Price graph", variant: "no data",
                summary: "Axes and the 'set price alert' offer, before three days of "
                    + "samples exist to draw.",
                kind: .product,
                make: {
                    let graph = PriceGraphView()
                    graph.setData(
                        [], currency: "USD", thresholdPrice: nil, baselinePrice: nil,
                        allowsThresholdEditing: true)
                    return StageFixtures.hosting(graph, height: 240)
                }),
            StageDescriptor(
                id: "price.graph.series", screen: "Price graph", variant: "falling series",
                summary: "A week of samples under a threshold line — the shape a drop makes.",
                kind: .product,
                make: {
                    let graph = PriceGraphView()
                    graph.setData(
                        fallingSeries(), currency: "USD", thresholdPrice: 180,
                        baselinePrice: 200, allowsThresholdEditing: true)
                    return StageFixtures.hosting(graph, height: 240)
                }),
            StageDescriptor(
                id: "price.threshold.unset", screen: "Alert threshold row", variant: "parked",
                summary: "The row before an alert is set: track dimmed, and a Set price "
                    + "alert button where the threshold price goes.",
                kind: .product,
                make: {
                    let row = AlertThresholdRow()
                    row.configure(fraction: nil, initialPrice: 200, currency: "USD")
                    return StageFixtures.hosting(row, height: 90)
                }),
            StageDescriptor(
                id: "price.threshold.set", screen: "Alert threshold row", variant: "armed",
                summary: "A 25%-off threshold committed: accent track and the price it "
                    + "resolves to, on one line.",
                kind: .product,
                make: {
                    let row = AlertThresholdRow()
                    row.configure(fraction: 0.25, initialPrice: 200, currency: "USD")
                    return StageFixtures.hosting(row, height: 90)
                }),
        ]
    }

    private static func fallingSeries() -> [PriceGraphPoint] {
        let prices: [Decimal] = [200, 198, 195, 188, 175, 162, 150]
        return prices.enumerated().map { index, price in
            PriceGraphPoint(
                date: StageFixtures.ago(days: prices.count - index),
                price: price, currency: "USD", storeURLString: gadgetURL)
        }
    }
}

/// A price fetcher that never answers. The editor kicks off a refresh when it
/// appears, and a real one would replace the seeded price mid-capture — which
/// is the whole reason staged mode suppresses network work everywhere else too.
private struct StagedPriceFetcher: PriceFetching {
    func fetchPrice(forURLString urlString: String, prefetchedHTML: String?) async -> ProductPrice? {
        nil
    }
}

#endif
