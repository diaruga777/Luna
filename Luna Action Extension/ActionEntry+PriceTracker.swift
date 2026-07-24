//
//  ActionEntry+PriceTracker.swift
//
//  The extension's principal class (Info.plist names the stable @objc name
//  `LunaActionEntry`). EXACTLY ONE variant is compiled into each host's
//  extension target (per-target membership exceptions on the shared folder),
//  registering the per-kind pipeline processors AND extension presenters that
//  host's app handles — the registries mirror the link set.
//

import LunaShareSurface
import UIKit
import LunaHTMLClassification
import LunaIngest
import LunaPriceIngest
import LunaPriceUI
import LunaStorage

@objc(LunaActionEntry)
final class ActionEntry: ShareViewController {
    override init(nibName: String?, bundle: Bundle?) {
        IngestKindProcessors.product = ProductIngestProcessor()
        ShareKindPresenters.product = ProductPresenterAdapter()
        super.init(nibName: nibName, bundle: bundle)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// Adapts the protocol-free `ExtensionProductPresenter` (LunaPriceUI) to
/// `ShareProductPresenting`.
private struct ProductPresenterAdapter: ShareProductPresenting {
    private let presenter = ExtensionProductPresenter()

    func presentPriceEditor(product: ProductInfo, url: URL, store: ReadingListStore, host: ExtensionHost) {
        presenter.presentPriceEditor(
            product: product, url: url, store: store,
            presentModally: { [weak host] in host?.presentModally($0) },
            complete: { [weak host] in host?.confirmSavedThenComplete() })
    }
}
