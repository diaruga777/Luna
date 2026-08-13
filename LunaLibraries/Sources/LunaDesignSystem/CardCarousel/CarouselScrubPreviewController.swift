//
//  CarouselScrubPreviewController.swift
//  LunaDesignSystem
//
//  The scrub strip's live preview: while the user scrolls the strip, the
//  carousel's real cards stand aside and this controller draws the previewed
//  card AND both of its neighbors as full card surfaces — the same
//  `CarouselCardView` chrome the mounted slots wear (glass rim, mute button,
//  top-leading accessory, failure glow) at the same resting geometry. The whole
//  deck therefore tracks the finger: the center shows a thumbnail, the card's
//  title, or host-supplied real content, and the peeks update in step instead
//  of staying frozen on the committed card until release.
//
//  The carousel's own commit path takes the center preview's content back out
//  (`takeContent()`) and installs it as the real centered slot without pausing
//  or rebuilding it, then removes the remaining previews once the real cards
//  are back in place — so a promoted media card never blinks.
//

import UIKit

final class CarouselScrubPreviewController: CardContentAudioAvailabilityObserving {

    /// One previewed card: the surface, the card index it stands for, and
    /// whatever it is currently showing.
    private final class Preview {
        let card: CarouselCardView
        let index: Int
        var content: CardContentViewController?
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
    /// Exact card controllers prepared only for mini-card chips currently in
    /// the scrubber viewport. A preview takes its controller from this cache;
    /// commit then promotes that same instance into the real centered slot.
    private var preparedContent: [Int: CardContentViewController] = [:]

    init(carousel: CardCarouselViewController, cardArea: UIView) {
        self.carousel = carousel
        self.cardArea = cardArea
    }

    /// The preview cards currently in the card area — card views the carousel's
    /// orphan sweep must leave alone.
    var liveCardIdentifiers: Set<ObjectIdentifier> {
        Set(previews.values.map { ObjectIdentifier($0.card) })
    }

    /// The card index whose real content is mounted in the CENTER preview, if
    /// any — the one the commit path can promote instead of rebuilding.
    var previewContentIndex: Int? {
        guard let center = previews[0], center.content != nil else { return nil }
        return center.index
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
    /// the card's thumbnail, its title, and — mounted over both when it exists
    /// — the card's real content. Which one shows is decided per card by
    /// `updateFill`, so a media save previews as its poster even in a mini-card
    /// strip whose article neighbours preview as titles.
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

    /// Fills a preview for the slot it now occupies. Peeks never play: only the
    /// center autoplays, and only where the host opted in.
    private func configure(_ preview: Preview, atSlotOffset offset: Int) {
        let isCenter = offset == 0
        loadThumbnail(into: preview)
        preview.titleLabel?.text = carousel.dataSource?.carousel(
            carousel, titleForCardAt: preview.index)
        // Mount unconditionally: a peek only ever gets content the strip already
        // PREPARED, and a kind whose card is an AVPlayer declines preparation,
        // so the "no player per chip" invariant holds without a deck-level flag.
        mountContent(into: preview, isCenter: isCenter)
        if let content = preview.content {
            if isCenter {
                // A card scrubbed back to center resumes the preview it was
                // already playing before it slid out to a peek.
                if carousel.cardStyle(at: preview.index).autoplaysScrubPreview,
                   content.isPlayable, !content.isPlaying {
                    content.cardDidBecomeCentered()
                }
            } else {
                content.setPlaying(false)
            }
        }
        updateFill(preview)
        preview.card.setMuteButtonVisible(
            isCenter && carousel.showsMuteButton(for: preview.content))
        preview.card.updateMuteIcon(muted: carousel.isSoundMuted)
    }

    /// Mounted content owns the card outright; failing that a thumbnail beats a
    /// title, and a title beats an empty card surface.
    private func updateFill(_ preview: Preview) {
        let hasContent = preview.content != nil
        let hasImage = preview.imageView?.image != nil
        preview.imageView?.isHidden = hasContent || !hasImage
        preview.titleLabel?.isHidden = hasContent || hasImage
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

    /// Mounts the exact card content inside a preview. Only ever takes an
    /// already-prepared controller for a peek — building one per chip pass
    /// would spin up a player (or a reader) for a card the finger is merely
    /// sweeping over.
    private func mountContent(into preview: Preview, isCenter: Bool) {
        guard preview.content == nil, let dataSource = carousel.dataSource else { return }
        let content = preparedContent[preview.index]
            ?? (isCenter
                ? dataSource.carousel(carousel, previewContentControllerForCardAt: preview.index)
                : nil)
        guard let content else { return }
        preparedContent[preview.index] = content
        carousel.addChild(content)
        preview.card.installContentView(content.view)
        content.didMove(toParent: carousel)
        content.setMuted(carousel.isSoundMuted)
        content.audioAvailabilityObserver = self
        preview.content = content
        updateFill(preview)
    }

    private func unmountContent(from preview: Preview) {
        guard let content = preview.content else { return }
        content.setPlaying(false)
        content.audioAvailabilityObserver = nil
        content.willMove(toParent: nil)
        content.view.removeFromSuperview()
        content.removeFromParent()
        preview.content = nil
        updateFill(preview)
    }

    private func discard(_ preview: Preview) {
        unmountContent(from: preview)
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
        preparedContent.removeAll()
    }

    func setMuted(_ muted: Bool) {
        for preview in previews.values {
            preview.content?.setMuted(muted)
            preview.card.updateMuteIcon(muted: muted)
        }
    }

    func cardContentDidChangeAudioAvailability(_ content: CardContentViewController) {
        updateMuteButtons()
    }

    /// Re-evaluates which preview shows the mute button — the center one, and
    /// only once its content reports that it actually carries audio.
    func updateMuteButtons() {
        for (offset, preview) in previews {
            preview.card.setMuteButtonVisible(
                offset == 0 && carousel.showsMuteButton(for: preview.content))
        }
    }

    #if DEBUG
    var previewImageForTesting: UIImage? { previews[0]?.imageView?.image }
    #endif

    /// Detaches the CENTER preview's live content without pausing it or
    /// removing it as a child. The caller immediately installs it into a real
    /// carousel card and then calls `remove()` — leaving the peek previews up
    /// until the real cards are back means no blink between the two.
    func takeContent() -> CardContentViewController? {
        guard let center = previews[0], let content = center.content else { return nil }
        preparedContent[center.index] = nil
        center.content = nil
        content.audioAvailabilityObserver = nil
        content.view.removeFromSuperview()
        return content
    }

    /// Prepares only the controllers whose mini-card chips intersect the
    /// scrubber viewport. Controllers outside that window are released unless
    /// one is currently mounted in a live preview.
    func prepare(indices: IndexSet, cardCount: Int) {
        let valid = IndexSet(indices.filter { $0 >= 0 && $0 < cardCount })
        let mounted = Set(previews.values.compactMap { $0.content != nil ? $0.index : nil })
        for index in Array(preparedContent.keys)
        where !valid.contains(index) && !mounted.contains(index) {
            preparedContent[index] = nil
        }
        guard let dataSource = carousel.dataSource else { return }
        for index in valid where preparedContent[index] == nil {
            guard let content = dataSource.carousel(
                carousel, previewContentControllerForCardAt: index)
            else { continue }
            content.loadViewIfNeeded()
            preparedContent[index] = content
        }
    }
}
