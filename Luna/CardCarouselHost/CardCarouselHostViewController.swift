//
//  CardCarouselHostViewController.swift
//  Luna
//

import LunaDesignSystem
import UIKit

/// The shared skeleton behind Reader's and Downloader's root screens: both
/// present one `CardCarouselViewController` full-screen, flank its scrub strip
/// with two persistent Liquid Glass circles (Settings + a share/action button),
/// and prepend a synthetic leading card for a not-yet-saved pasteboard URL —
/// which shifts every real item's carousel index by one. This base owns the
/// carousel instance and the chrome/index-math pieces that are byte-identical
/// between the two hosts; each subclass keeps its own item model, data source/
/// delegate conformance, and reload/pasteboard-polling orchestration (those
/// diverge in real ways — what's fetched, what's deduped against, what runs on
/// success — not just in naming).
class CardCarouselHostViewController: UIViewController {

    let carousel = CardCarouselViewController()
    private(set) var archiveTray: ArchiveTrayController?

    /// Adds the already-configured `carousel` (style/dataSource/delegate are the
    /// subclass's business, set before calling this) as a full-screen child,
    /// pinned to all four edges.
    final func mountCarousel() {
        addChild(carousel)
        view.addSubview(carousel.view)
        carousel.view.translatesAutoresizingMaskIntoConstraints = false
        carousel.didMove(toParent: self)
        NSLayoutConstraint.activate([
            carousel.view.topAnchor.constraint(equalTo: view.topAnchor),
            carousel.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            carousel.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            carousel.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    final func mountArchiveTray(
        shifting views: @escaping () -> [UIView], canPull: @escaping () -> Bool
    ) {
        archiveTray = ArchiveTrayController(host: self, shiftedViews: views, canPull: canPull)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        archiveTray?.layout(in: view.bounds, safeAreaInsets: view.safeAreaInsets)
    }

    /// Cards rest fully below the safe area; `inset` adds any extra chrome-row
    /// clearance a subclass floats above the carousel (Reader's top control row;
    /// Downloader has none).
    final func applyCarouselTopInset(_ inset: CGFloat) {
        carousel.setTopInset(view.safeAreaInsets.top + inset)
    }

    final func configureBottomButton(
        _ button: UIButton, symbol: String, action: Selector, accessibilityLabel: String
    ) {
        button.configuration = GlassStyle.circularButtonConfiguration(symbol: symbol, padding: 10)
        button.accessibilityLabel = accessibilityLabel
        button.addTarget(self, action: action, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    /// Pins two already-`configureBottomButton`-ed buttons to the bottom
    /// corners, flanking the scrub strip: 12pt from each side edge, 26pt above
    /// the safe area, 44×44.
    final func mountBottomControls(leading: UIButton, trailing: UIButton) {
        view.addSubview(leading)
        view.addSubview(trailing)
        NSLayoutConstraint.activate([
            leading.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            leading.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -26),
            leading.widthAnchor.constraint(equalToConstant: 44),
            leading.heightAnchor.constraint(equalToConstant: 44),
            trailing.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            trailing.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -26),
            trailing.widthAnchor.constraint(equalToConstant: 44),
            trailing.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    // MARK: - Pasteboard-offset index math

    /// Whether a synthetic pasteboard card is currently prepended to the
    /// carousel, shifting every real item's carousel index by one. Subclasses
    /// override to reflect their own pasteboard state.
    var hasLeadingPasteboardCard: Bool { false }

    final var cardOffset: Int { hasLeadingPasteboardCard ? 1 : 0 }

    final func itemIndex(forCarouselIndex index: Int, itemCount: Int) -> Int? {
        let itemIndex = index - cardOffset
        return (0..<itemCount).contains(itemIndex) ? itemIndex : nil
    }

    // MARK: - Empty state

    /// The image + title + subtitle stack both hosts use for "nothing saved
    /// yet" — identical layout, subclass-supplied glyph and copy.
    static func makeEmptyStateView(symbol: String, title: String, subtitle: String) -> UIView {
        let container = UIView()
        let image = UIImageView(image: UIImage(systemName: symbol))
        image.tintColor = .tertiaryLabel
        image.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44, weight: .regular)
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .title3)
        titleLabel.textColor = .label
        let subtitleLabel = UILabel()
        subtitleLabel.text = subtitle
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0
        let stack = UIStackView(arrangedSubviews: [image, titleLabel, subtitleLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -32),
        ])
        return container
    }

    // MARK: - Settings

    @objc func settingsTapped() {
        navigationController?.pushViewController(SettingsViewController(), animated: true)
    }
}
