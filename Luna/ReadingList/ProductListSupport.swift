//
//  ProductListSupport.swift
//  Luna
//
//  Product-kind implementation of `ProductListSupporting` — compiled only into
//  product-handling app targets (Price Tracker + the central Luna app; excluded
//  from the others via the synchronized group's membership exceptions) and
//  installed by their `KindWiring` variants.
//

import LunaPriceUI
import UIKit

struct ProductListSupport: ProductListSupporting {

    func openTracker(itemID: UUID, on nav: UINavigationController?) {
        nav?.pushViewController(PriceTrackingViewController(itemID: itemID), animated: true)
    }

    func presentInteractiveSaveEditor(
        itemID: UUID, isMerge: Bool, highlightedURL: String?, on nav: UINavigationController?
    ) {
        let mode: PriceTrackingViewController.Mode
        if isMerge, let highlightedURL {
            mode = .merge(itemID: itemID, addedStoreURLString: highlightedURL, host: .inApp)
        } else {
            mode = .creation(itemID: itemID, host: .inApp)
        }
        nav?.pushViewController(PriceTrackingViewController(mode: mode), animated: true)
    }
}
