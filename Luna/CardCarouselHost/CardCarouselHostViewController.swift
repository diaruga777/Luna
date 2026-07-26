//
//  CardCarouselHostViewController.swift
//  Luna
//

import LunaDesignSystem
import LunaModels
import UniformTypeIdentifiers
import UIKit

enum PasteboardTemporaryMediaPolicy {
    static let lifetime: TimeInterval = 60 * 60

    static func isExpired(expiresAt: Date, now: Date = Date()) -> Bool {
        expiresAt <= now
    }
}

enum PasteboardCommitPolicy {
    /// A completed save may clear only the synthetic card it started from.
    /// If a newer card is already represented, it must survive the older
    /// save's asynchronous storage/Photos completion.
    static func shouldClearCommittedCard(
        committedChangeCount: Int,
        currentPasteboardChangeCount: Int,
        representedChangeCount: Int?
    ) -> Bool {
        currentPasteboardChangeCount == committedChangeCount
            || representedChangeCount == committedChangeCount
    }
}

/// The shared skeleton behind Reader's and Downloader's root screens: both
/// present one `CardCarouselViewController` full-screen, flank its scrub strip
/// with two persistent Liquid Glass circles (Settings + a share/action button),
/// and attach mirrored edge trays (setup/paste/recent on the left, archive on
/// the right). This base owns the carousel instance and the chrome/index-math
/// pieces that are byte-identical between the two hosts; each subclass keeps
/// its own item model, data source/delegate conformance, and store reload
/// orchestration.
class CardCarouselHostViewController: UIViewController {

    let carousel = CardCarouselViewController()
    private(set) var archiveTray: ArchiveTrayController?
    private(set) var leftTray: LeftTrayController?

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
        shifting views: @escaping () -> [UIView],
        canPull: @escaping () -> Bool,
        openStateChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        archiveTray = ArchiveTrayController(
            host: self,
            shiftedViews: views,
            canPull: canPull,
            openStateChanged: openStateChanged)
    }

    final func mountLeftTray(
        shifting views: @escaping () -> [UIView],
        canPull: @escaping () -> Bool,
        savedURL: @escaping (String, CaptureSource, UIView) -> Void,
        openStateChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        leftTray = LeftTrayController(
            host: self, shiftedViews: views, canPull: canPull,
            savedURL: savedURL,
            openStateChanged: openStateChanged)
    }

    final func refreshArchivePullAvailability(animated: Bool) {
        archiveTray?.refreshPullAvailability(animated: animated)
    }

    final func refreshLeftPullAvailability(animated: Bool) {
        leftTray?.refreshPullAvailability(animated: animated)
    }

    /// Retracts the tray from the carousel's intended target rather than its
    /// not-yet-swapped `currentIndex`, so paging away hides the tab immediately.
    /// Paging toward the last card deliberately does nothing here: the tab is
    /// revealed only by `refreshArchivePullAvailability` after that card centers.
    final func updateArchivePullAvailability(
        forTargetIndex index: Int,
        cardCount: Int,
        animated: Bool
    ) {
        guard cardCount > 0, index != cardCount - 1 else { return }
        archiveTray?.setPullAvailable(false, animated: animated)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        archiveTray?.layout(in: view.bounds, safeAreaInsets: view.safeAreaInsets)
        leftTray?.layout(in: view.bounds, safeAreaInsets: view.safeAreaInsets)
    }

    /// Cards rest fully below the safe area; `inset` adds any extra chrome-row
    /// clearance a subclass floats above the carousel (Reader's top control row;
    /// Downloader has none).
    final func applyCarouselTopInset(_ inset: CGFloat) {
        carousel.setTopInset(view.safeAreaInsets.top + inset)
    }

    /// A nil `action` leaves the button's behaviour to the caller — used by the
    /// share pill, which presents a menu as its primary action rather than firing
    /// a tap handler.
    final func configureBottomButton(
        _ button: UIButton, symbol: String, action: Selector?, accessibilityLabel: String
    ) {
        button.configuration = GlassStyle.circularButtonConfiguration(symbol: symbol, padding: 10)
        button.accessibilityLabel = accessibilityLabel
        if let action { button.addTarget(self, action: action, for: .touchUpInside) }
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
        image.tintColor = LunaColors.tertiaryText
        image.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44, weight: .regular)
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .title3)
        titleLabel.textColor = LunaColors.primaryText
        let subtitleLabel = UILabel()
        subtitleLabel.text = subtitle
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.textColor = LunaColors.secondaryText
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

/// The privacy-preserving leading card shown after pattern detection says the
/// pasteboard might contain a URL. Merely constructing/centering it does not
/// access the pasteboard value.
///
/// The read is performed by a system `UIPasteControl`, whose tap IS the
/// authorization: the pasted item arrives through `paste(itemProviders:)` and
/// the "Allow Paste from Other Apps" alert never appears. Nothing else on this
/// card touches the pasteboard, so the value stays unread until the user asks
/// for it — the same privacy posture as before, without the interruption.
/// `onPaste` nil (the transient "Loading Paste" state) shows no control.
final class PasteboardPlaceholderCardContentViewController: CardContentViewController {
    private let titleText: String
    private let detailText: String
    private let onPaste: ((String) -> Void)?

    init(title: String, detail: String, onPaste: ((String) -> Void)? = nil) {
        self.titleText = title
        self.detailText = detail
        self.onPaste = onPaste
        super.init()
        pasteConfiguration = UIPasteConfiguration(
            acceptableTypeIdentifiers: [UTType.url.identifier, UTType.plainText.identifier])
    }

    /// The paste control owns this card's interaction; a stray card tap would
    /// otherwise page or toggle under the user's finger.
    override func allowsCardTap(at point: CGPoint) -> Bool { onPaste == nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background
        // With a real control present the card must not swallow it into one
        // accessibility element; without one the whole card is the affordance.
        view.isAccessibilityElement = onPaste == nil
        view.accessibilityLabel = titleText
        view.accessibilityHint = detailText

        let icon = UIImageView(image: UIImage(systemName: "doc.on.clipboard"))
        icon.tintColor = GlassStyle.readingAccent
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 42, weight: .medium)

        let title = UILabel()
        title.text = titleText
        title.font = .preferredFont(forTextStyle: .title2)
        title.textColor = LunaColors.primaryText
        title.textAlignment = .center

        let detail = UILabel()
        detail.text = detailText
        detail.font = .preferredFont(forTextStyle: .subheadline)
        detail.textColor = LunaColors.secondaryText
        detail.textAlignment = .center
        detail.numberOfLines = 0

        var arranged: [UIView] = [icon, title, detail]
        if onPaste != nil { arranged.append(makePasteControl()) }
        let stack = UIStackView(arrangedSubviews: arranged)
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14
        stack.setCustomSpacing(24, after: detail)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])
    }

    /// The system paste button, dressed as one of Luna's capsule actions: the
    /// fixed brand indigo rather than the configurable reading accent, so a
    /// yellow highlight preference can't leave white-on-yellow.
    private func makePasteControl() -> UIPasteControl {
        var configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconAndLabel
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = GlassStyle.lunaBrandAccent
        configuration.baseForegroundColor = .white
        let control = UIPasteControl(configuration: configuration)
        control.target = self
        control.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            control.heightAnchor.constraint(equalToConstant: 44),
            control.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
        ])
        return control
    }

    /// Delivered by `UIPasteControl` — an implicitly authorized read, so no
    /// prompt and no timing heuristics.
    override func paste(itemProviders: [NSItemProvider]) {
        if let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: URL.self) }) {
            _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                guard let url else { return }
                DispatchQueue.main.async { self?.onPaste?(url.absoluteString) }
            }
            return
        }
        guard let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: NSString.self) })
        else { return }
        _ = provider.loadObject(ofClass: NSString.self) { [weak self] string, _ in
            guard let string = string as? NSString else { return }
            DispatchQueue.main.async { self?.onPaste?(string as String) }
        }
    }
}

/// A failed user-initiated paste read: the pasted text was not a URL this app
/// can take. There is no "Allow Paste" branch to explain — the read arrives
/// through `UIPasteControl`, which never asks.
final class InvalidPasteCardContentViewController: CardContentViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background

        let icon = UIImageView(image: UIImage(systemName: "exclamationmark.circle"))
        icon.tintColor = LunaColors.secondaryText
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 40, weight: .medium)

        let title = UILabel()
        title.text = "Invalid paste"
        title.font = .preferredFont(forTextStyle: .title2)
        title.textColor = LunaColors.primaryText
        title.textAlignment = .center

        let detail = UILabel()
        detail.text = "Invalid URL"
        detail.font = .preferredFont(forTextStyle: .subheadline)
        detail.textColor = LunaColors.secondaryText
        detail.textAlignment = .center
        detail.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [icon, title, detail])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -28),
            detail.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -56),
        ])
    }
}
