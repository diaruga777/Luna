//
//  CarouselScrubPreviewController.swift
//  LunaDesignSystem
//
//  Three bounded previews reuse normal non-media cards while media keeps its
//  static poster. Preview content is never centered until the strip commits.

import UIKit

final class CarouselScrubPreviewController {

    /// One previewed card: the surface, the card index it stands for, and
    /// whatever it is currently showing.
    private final class Preview {
        let card: CarouselCardView
        let index: Int
        var imageView: UIImageView?
        var titleLabel: UILabel?
        var content: CardContentViewController?
        var ownsContent = false

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
            configure(preview)
        }
        layout()
    }

    /// Mount only the visible three-card window; reuse existing controllers so
    /// an article keeps its scroll position and a utility card keeps its state.
    private func makePreview(at index: Int) -> Preview {
        let card = carousel.makeScrubPreviewCard(at: index)
        let preview = Preview(card: card, index: index)
        if carousel.dataSource?.carousel(carousel, showsContentWhileScrubbingCardAt: index) == true {
            let existing = carousel.contentController(at: index)
            if let content = existing ?? carousel.dataSource?.carousel(
                carousel, contentControllerForCardAt: index) {
                preview.content = content
                preview.ownsContent = existing == nil
                if preview.ownsContent { carousel.addChild(content) }
                card.installContentView(content.view)
                content.setMuted(carousel.isSoundMuted)
                if preview.ownsContent { content.didMove(toParent: carousel) }
                cardArea.addSubview(card)
                return preview
            }
        }

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

    /// Refreshes fallback artwork and shared chrome for a recycled preview.
    private func configure(_ preview: Preview) {
        if preview.content == nil { loadThumbnail(into: preview) }
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
        if let content = preview.content {
            if preview.ownsContent {
                content.setPlaying(false)
                content.willMove(toParent: nil)
                content.view.removeFromSuperview()
                content.removeFromParent()
            } else {
                carousel.restoreScrubContent(content, at: preview.index)
            }
        }
        preview.card.removeFromSuperview()
    }

    /// Promote the exact preview controller, preserving its rendered viewport.
    /// Mounted/borrowed controllers already belong to a real slot.
    func takeContent(at index: Int) -> CardContentViewController? {
        guard let preview = previews.values.first(where: { $0.index == index }),
              preview.ownsContent, let content = preview.content else { return nil }
        preview.content = nil
        content.view.removeFromSuperview()
        return content
    }

    // MARK: - Layout + state

    /// Rests every preview at its slot's geometry, exactly like a mounted card.
    func layout() {
        for (offset, preview) in previews {
            carousel.applyRestingLayout(
                to: preview.card, atSlotOffset: offset)
            preview.card.layoutIfNeeded()
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
