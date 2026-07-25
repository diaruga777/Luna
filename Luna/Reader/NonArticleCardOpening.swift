//
//  NonArticleCardOpening.swift
//  Luna
//

import LunaDesignSystem
import LunaModels
import LunaPlatforms
import LunaPriceUI
import LunaStorage
import UIKit

/// Installs the card deck's non-article tap routing (`ArticleCardsViewController
/// .nonArticleOpener`) — the central Luna app's all-kinds deck opens a price
/// tracker in the price editor and a platform post through the same
/// native-app → embed → in-app-browser ladder the list rows use. Installed at
/// launch from the app shell; the deck only contains non-article cards on the
/// `.all` surface, so the closure is never hit elsewhere.
enum NonArticleCardOpening {
    static func install() {
        ArticleCardsViewController.nonArticleOpener = { item, presenter in
            open(item, from: presenter)
        }
        // …and the cards themselves: a downloaded media save renders here with
        // the Downloader's own player, not as a link that has to be opened.
        ArticleCardsViewController.cardProvider = AllKindsCardProvider()
    }

    private static func open(_ item: ReadingListItem, from presenter: UIViewController) {
        let store = ReadingListStore.shared
        if item.isPriceTracker {
            // Opening an alerting tracker acknowledges its alert (same as the
            // list row), so it stops floating above the other cards' ordering.
            if var tracker = item.priceTracker, tracker.hasUnviewedAlert {
                tracker.markAlertViewed()
                store.updatePriceTracker(tracker, for: item.id)
            }
            let editor = PriceTrackingViewController(itemID: item.id)
            presenter.navigationController?.pushViewController(editor, animated: true)
            return
        }
        guard let platform = item.contentPlatform,
              let module = PlatformRegistry.shared.module(for: platform) else {
            InAppBrowser.present(urlString: item.urlString, from: presenter)
            return
        }
        if let appURL = module.appDeepLink(for: item), UIApplication.shared.canOpenURL(appURL) {
            UIApplication.shared.open(appURL) { success in
                if success { store.markReadState(.read, for: item.id) }
            }
            return
        }
        if let embed = module.embed(for: item) {
            presenter.present(PlatformEmbedViewController(embed: embed, itemID: item.id), animated: true)
            return
        }
        InAppBrowser.present(urlString: item.urlString, from: presenter)
    }
}
