//
//  CarouselScrubPreviewController.swift
//  LunaDesignSystem
//
//  The scrub strip's live preview overlay: mounted over the centered card while
//  the user scrubs the strip — a thumbnail or, for `.miniCards` scrubbers, the
//  card's title — with host-supplied real content mounted inside it when the
//  style opts in. The carousel's own commit path takes the live preview content
//  back out (`takeContent()`) and installs it as the real centered slot without
//  pausing or rebuilding it, so only the mute/accessory chrome fades in around
//  an already-playing preview.
//

import UIKit

final class CarouselScrubPreviewController {
    private unowned let carousel: CardCarouselViewController
    private let cardArea: UIView

    private var previewOverlay: UIView?
    private var previewImageView: UIImageView?
    private var previewTitleLabel: UILabel?
    /// Host-supplied exact card content mounted inside the overlay.
    private var previewContent: CardContentViewController?
    private(set) var previewContentIndex: Int?
    /// Exact card controllers prepared only for mini-card chips currently in
    /// the scrubber viewport. A preview takes its controller from this cache;
    /// commit then promotes that same instance into the real centered slot.
    private var preparedContent: [Int: CardContentViewController] = [:]

    init(carousel: CardCarouselViewController, cardArea: UIView) {
        self.carousel = carousel
        self.cardArea = cardArea
    }

    func show(at index: Int, cardCount: Int, centeredCardFrame: CGRect) {
        if previewOverlay == nil {
            let overlay = UIView()
            overlay.backgroundColor = LunaColors.secondaryBackground
            overlay.layer.cornerRadius = CarouselCardView.cornerRadius
            overlay.layer.cornerCurve = .continuous
            overlay.clipsToBounds = true
            switch carousel.style.scrubberStyle {
            case .thumbnails:
                let imageView = UIImageView()
                imageView.contentMode = .scaleAspectFit
                imageView.frame = overlay.bounds
                imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                overlay.addSubview(imageView)
                previewImageView = imageView
            case .miniCards:
                let label = UILabel()
                label.font = .preferredFont(forTextStyle: .title2)
                label.textColor = LunaColors.primaryText
                label.textAlignment = .center
                label.numberOfLines = 0
                label.translatesAutoresizingMaskIntoConstraints = false
                overlay.addSubview(label)
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 24),
                    label.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -24),
                    label.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
                ])
                previewTitleLabel = label
            }
            cardArea.addSubview(overlay)
            previewOverlay = overlay
            layout(centeredCardFrame: centeredCardFrame)
        }
        switch carousel.style.scrubberStyle {
        case .thumbnails:
            carousel.dataSource?.carousel(carousel, loadThumbnailForCardAt: index) { [weak self] image in
                DispatchQueue.main.async { self?.previewImageView?.image = image }
            }
            if carousel.style.autoplaysScrubPreviewContent {
                mountContent(at: index, cardCount: cardCount, autoplay: true)
            }
        case .miniCards:
            previewTitleLabel?.text = carousel.dataSource?.carousel(carousel, titleForCardAt: index)
            mountContent(at: index, cardCount: cardCount)
        }
    }

    private func mountContent(at index: Int, cardCount: Int, autoplay: Bool = false) {
        guard index != previewContentIndex else { return }
        unmountContent()
        previewTitleLabel?.isHidden = false
        guard let overlay = previewOverlay, let dataSource = carousel.dataSource,
              index >= 0, index < cardCount
        else { return }
        let content = preparedContent[index] ?? dataSource.carousel(
            carousel, previewContentControllerForCardAt: index)
        guard let content else { return }
        preparedContent[index] = content
        carousel.addChild(content)
        content.view.frame = overlay.bounds
        content.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.addSubview(content.view)
        content.didMove(toParent: carousel)
        content.setMuted(carousel.isSoundMuted)
        previewContent = content
        previewContentIndex = index
        if autoplay {
            content.cardDidBecomeCentered()
        }
        // The mounted preview owns its complete visible presentation.
        previewTitleLabel?.isHidden = true
    }

    func unmountContent() {
        guard let content = previewContent else { return }
        content.setPlaying(false)
        content.willMove(toParent: nil)
        content.view.removeFromSuperview()
        content.removeFromParent()
        previewContent = nil
        previewContentIndex = nil
    }

    func layout(centeredCardFrame: CGRect) {
        previewOverlay?.frame = centeredCardFrame
    }

    func remove() {
        unmountContent()
        removeOverlay()
        preparedContent.removeAll()
    }

    func setMuted(_ muted: Bool) {
        previewContent?.setMuted(muted)
    }

    func removeOverlay() {
        previewOverlay?.removeFromSuperview()
        previewOverlay = nil
        previewImageView = nil
        previewTitleLabel = nil
    }

    /// Detaches the live preview without pausing or removing it as a child.
    /// The caller immediately installs it into a real carousel card.
    func takeContent() -> CardContentViewController? {
        guard let content = previewContent else { return nil }
        if let index = previewContentIndex { preparedContent[index] = nil }
        previewContent = nil
        previewContentIndex = nil
        content.view.removeFromSuperview()
        removeOverlay()
        return content
    }

    /// Prepares only the controllers whose mini-card chips intersect the
    /// scrubber viewport. Controllers outside that window are released unless
    /// one is currently mounted as the live preview.
    func prepare(indices: IndexSet, cardCount: Int) {
        let valid = IndexSet(indices.filter { $0 >= 0 && $0 < cardCount })
        for index in Array(preparedContent.keys)
        where !valid.contains(index) && index != previewContentIndex {
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
