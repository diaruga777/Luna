//
//  CarouselScrubPreviewController.swift
//  LunaDesignSystem
//
//  The scrub strip's live preview: while the user scrolls the strip, the
//  carousel's real cards stand aside and this controller draws the previewed
//  card AND both of its neighbors as lightweight card surfaces — the same
//  `CarouselCardView` chrome the mounted slots wear (glass rim, mute button,
//  top-leading accessory, failure glow) at the same resting geometry. The whole
//  deck therefore tracks the finger: the center shows a thumbnail, the card's
//  title or poster, and the peeks update in step instead
//  of staying frozen on the committed card until release.
//

import UIKit

final class CarouselScrubPreviewController {

    /// One previewed card: the surface, the card index it stands for, and
    /// whatever it is currently showing.
    private final class Preview {
        let card: CarouselCardView
        let index: Int
        var imageView: UIImageView?
        var titleLabel: UILabel?

        init(card: CarouselCardView, index: Int) {
            self.card = card
            self.index = index
        }
    }

    /// Slot offsets a preview is drawn for: the centered card and both peeks.
    private static let offsets = [-1, 0, 1]

    private unowned let carousel: CardCarouselViewController
    private let cardArea: UIView

    /// Live previews keyed by their slot offset from the previewed card.
    private var previews: [Int: Preview] = [:]

    init(carousel: CardCarouselViewController, cardArea: UIView) {
        self.carousel = carousel
        self.cardArea = cardArea
    }

    /// The preview cards currently in the card area — card views the carousel's
    /// orphan sweep must leave alone.
    var liveCardIdentifiers: Set<ObjectIdentifier> {
        Set(previews.values.map { ObjectIdentifier($0.card) })
    }

    // MARK: - Showing

    func show(at index: Int, cardCount: Int) {
        guard index >= 0, index < cardCount else { return }
        // Recycle by CARD, not by position: the card that was centered becomes
        // a peek when the strip advances one chip, keeping its mounted content
        // and loaded thumbnail instead of being torn down and rebuilt.
        let previous = previews
        var recycled: [Int: Preview] = [:]
        for offset in Self.offsets {
            let target = index + offset
            guard target >= 0, target < cardCount,
                  let match = previous.values.first(where: { $0.index == target })
            else { continue }
            recycled[offset] = match
        }
        let kept = Set(recycled.values.map(ObjectIdentifier.init))
        for preview in previous.values where !kept.contains(ObjectIdentifier(preview)) {
            discard(preview)
        }

        previews = recycled
        for offset in Self.offsets {
            let target = index + offset
            guard target >= 0, target < cardCount else { continue }
            let preview = previews[offset] ?? makePreview(at: target)
            previews[offset] = preview
            configure(preview, atSlotOffset: offset)
        }
        layout()
    }

    /// Every preview carries the same three layers, whatever the strip style:
    /// the card's thumbnail and its title. A media save previews as its poster
    /// while an article neighbour previews as title text; no reader, player, or
    /// product editor is constructed while the finger is moving.
    private func makePreview(at index: Int) -> Preview {
        let card = carousel.makeScrubPreviewCard(at: index)
        let preview = Preview(card: card, index: index)

        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.isHidden = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        card.contentContainer.addSubview(imageView)

        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .title2)
        label.textColor = LunaColors.primaryText
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        card.contentContainer.addSubview(label)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: card.contentContainer.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: card.contentContainer.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: card.contentContainer.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: card.contentContainer.trailingAnchor),
            label.leadingAnchor.constraint(
                equalTo: card.contentContainer.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(
                equalTo: card.contentContainer.trailingAnchor, constant: -24),
            label.centerYAnchor.constraint(equalTo: card.contentContainer.centerYAnchor),
        ])
        preview.imageView = imageView
        preview.titleLabel = label
        cardArea.addSubview(card)
        return preview
    }

    /// Fills a preview for the slot it now occupies without mounting live content.
    private func configure(_ preview: Preview, atSlotOffset offset: Int) {
        loadThumbnail(into: preview)
        preview.titleLabel?.text = carousel.dataSource?.carousel(
            carousel, titleForCardAt: preview.index)
        updateFill(preview)
        preview.card.setMuteButtonVisible(false)
        preview.card.updateMuteIcon(muted: carousel.isSoundMuted)
    }

    /// Mounted content owns the card outright; failing that a thumbnail beats a
    /// title, and a title beats an empty card surface.
    private func updateFill(_ preview: Preview) {
        let hasImage = preview.imageView?.image != nil
        preview.imageView?.isHidden = !hasImage
        preview.titleLabel?.isHidden = hasImage
    }

    private func loadThumbnail(into preview: Preview) {
        guard preview.imageView?.image == nil else { return }
        let index = preview.index
        carousel.dataSource?.carousel(carousel, loadThumbnailForCardAt: index) {
            [weak self, weak preview] image in
            DispatchQueue.main.async {
                guard let self, let preview,
                      self.previews.values.contains(where: { $0 === preview })
                else { return }
                preview.imageView?.image = image
                self.updateFill(preview)
            }
        }
    }

    private func discard(_ preview: Preview) {
        preview.card.removeFromSuperview()
    }

    // MARK: - Layout + state

    /// Rests every preview at its slot's geometry, exactly like a mounted card.
    func layout() {
        for (offset, preview) in previews {
            carousel.applyRestingLayout(
                to: preview.card, atSlotOffset: offset)
        }
    }

    func remove() {
        for preview in previews.values { discard(preview) }
        previews = [:]
    }

    func setMuted(_ muted: Bool) {
        for preview in previews.values { preview.card.updateMuteIcon(muted: muted) }
    }

    #if DEBUG
    var previewImageForTesting: UIImage? { previews[0]?.imageView?.image }
    #endif

}
