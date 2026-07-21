//
//  CatchUpCardBodyFactory.swift
//  Luna
//

import LunaDesignSystem
import LunaReaderUI
import LunaStorage
import LunaModels
import UIKit

/// Builds one catch-up card's content — a price tracker, an embedded live
/// reader, or a media/link (locked or previewable) body — so
/// `CatchUpViewController` stays ignorant of each body kind's own layout
/// rules. The three kinds anchor to different tops (an article reader folds
/// the date into its single glass header; a media card gets the standalone
/// date strip above it), so `bodyTop` is returned alongside the body itself.
enum CatchUpCardBodyFactory {

    struct Result {
        let body: UIView
        let bodyTop: NSLayoutYAxisAnchor
        /// Set only for the embedded-reader body — `host` already has it as a
        /// child view controller; the caller retains it for later teardown.
        let readerChild: UIViewController?
    }

    static func make(
        for item: ReadingListItem,
        card: CatchUpCardView,
        store: ReadingListStore,
        host: UIViewController,
        onChangeThreshold: @escaping () -> Void,
        onOpenMediaItem: @escaping () -> Void
    ) -> Result {
        if let tracker = item.priceTracker {
            // A price tracker fills the whole content area (no date strip): a small
            // thumbnail, the product name, a non-tappable per-store mini-table, and a
            // read-only alert-threshold readout with a "Change" button. Editing the
            // threshold happens on the full price-tracking screen (where the slider
            // lives), opened via the button.
            let trackerBody = CatchUpPriceTrackerCardBody(item: item, tracker: tracker, store: store)
            trackerBody.onChangeThreshold = onChangeThreshold
            return Result(body: trackerBody, bodyTop: card.contentContainer.topAnchor, readerChild: nil)
        }
        if ReadingListViewController.rendersAsReader(item), item.state == .ready,
           let content = store.content(for: item) {
            // Embed the reader DIRECTLY (no UINavigationController) with an inline
            // liquid-glass header carrying the card's date. The card rasterizes itself
            // while rotating, so the glass header renders at identity scale (no balloon).
            let reader = ReaderViewController(
                item: item, content: content, forceMode: .scroll,
                shareProvider: nil,
                persistsModePreference: false, marksOpenedOnLoad: false,
                inlineControlsHeader: true,
                inlineHeaderSubtitle: CatchUpCardHeader.text(for: item))
            host.addChild(reader)
            reader.didMove(toParent: host)
            return Result(body: reader.view, bodyTop: card.contentContainer.topAnchor, readerChild: reader)
        }

        let header = CatchUpCardHeader(item: item)
        header.translatesAutoresizingMaskIntoConstraints = false
        card.contentContainer.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: card.contentContainer.topAnchor),
            header.leadingAnchor.constraint(equalTo: card.contentContainer.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: card.contentContainer.trailingAnchor),
        ])
        // A paywalled item awaiting its archive unlock shows a locked placeholder
        // (there's no content yet); everything else shows its media/link preview.
        let body: UIView
        if item.state == .needsCaptcha {
            body = makeLockedBody(for: item)
        } else {
            body = CatchUpMediaCardBody(item: item, store: store, onTap: onOpenMediaItem)
        }
        return Result(body: body, bodyTop: header.bottomAnchor, readerChild: nil)
    }

    /// The locked-card placeholder: a lock glyph + title + hint (no content exists
    /// until the user unlocks it via the archive flow).
    private static func makeLockedBody(for item: ReadingListItem) -> UIView {
        let container = UIView()
        let icon = UIImageView(image: UIImage(
            systemName: "lock.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 46, weight: .semibold)))
        icon.tintColor = GlassStyle.readingAccent
        icon.contentMode = .center

        let titleLabel = UILabel()
        titleLabel.text = item.title ?? item.url?.host ?? "Locked article"
        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 4

        let hint = UILabel()
        hint.text = "Locked · swipe left or tap Unlock to read it in Luna"
        hint.font = .preferredFont(forTextStyle: .subheadline)
        hint.textColor = .secondaryLabel
        hint.textAlignment = .center
        hint.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [icon, titleLabel, hint])
        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -28),
        ])
        return container
    }
}
