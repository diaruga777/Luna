//
//  ProductCardContent.swift
//  Luna
//
//  The product card's host: the card frame, and the shared
//  `ProductDetailViewController` (LunaPriceUI) inside it. The header, graph
//  and threshold, seller rows, add-seller flow, and product artwork all live
//  in that shared controller, because the share/action extension's editor
//  draws the same content and must not diverge from the card.
//
//  Compiled into Luna and LunaPriceTracker only (Reader and Downloader exclude
//  it through the synchronized group's membership exceptions).
//

import LunaDesignSystem
import LunaModels
import LunaPriceUI
import LunaSavesUI
import LunaStorage
import UIKit

/// One product card: the shared product surface, inset inside the deck's
/// card frame. It owns no archive timer or completion policy, and no layout
/// of its own beyond that inset.
final class ProductCardContentViewController: CardContentViewController {

    /// The card's own margin. The surface inside it is a form, and a form that
    /// touches the card's rounded corners reads as clipped.
    private static let inset: CGFloat = 18

    private let detail: ProductDetailViewController

    init(itemID: UUID, priceFetcher: PriceFetching = PriceFetcher()) {
        detail = ProductDetailViewController(itemID: itemID, priceFetcher: priceFetcher)
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.secondaryBackground

        // The util card's save transition flies the saved thumbnail and title
        // into their places on the new card, and finds them by identifier.
        detail.thumbnailTransitionIdentifier = UtilCardSaveTransitionAnchor.thumbnail
        detail.titleTransitionIdentifier = UtilCardSaveTransitionAnchor.title

        addChild(detail)
        detail.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(detail.view)
        detail.didMove(toParent: self)

        NSLayoutConstraint.activate([
            detail.view.topAnchor.constraint(equalTo: view.topAnchor, constant: Self.inset),
            detail.view.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Self.inset),
            detail.view.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -Self.inset),
            detail.view.bottomAnchor.constraint(
                equalTo: view.bottomAnchor, constant: -Self.inset),
        ])
    }

    override func ownsHorizontalDrag(at point: CGPoint) -> Bool {
        detail.ownsHorizontalDrag(at: point, in: view)
    }
}

// MARK: - The Price Tracker app's root

/// Luna Price Tracker's root: the shared deck host, configured. There is no
/// subclass — the app's root screen is a deck, and everything a screen needs
/// is either the shared host's job or the product presenter's.
enum ProductCardDeck {

    @MainActor
    static func makeRoot() -> CardCarouselHostViewController {
        let deck = CardCarouselHostViewController()
        let style = CardCarouselStyle.singleKindDeck
        deck.configure(style: style) { host in
            var configuration = CardDeckConfiguration()
            // This app has no generic link card: a product row with no tracker
            // payload behind it is not a slot here.
            configuration.showsSavesWithoutKindContent = false
            // The pill greys out on the util card rather than vanishing: it is a
            // fixture of this deck's chrome, and a gap beside the scrub strip
            // reads as a layout fault.
            configuration.shareButton = CardDeckShareButton(
                accessibilityLabel: L10n.string("PriceTracker_productCard_shareCurrentProductLabel"),
                unavailability: .disables)
            return KindDeckProvider(host: host, configuration: configuration)
        }
        return deck
    }
}
