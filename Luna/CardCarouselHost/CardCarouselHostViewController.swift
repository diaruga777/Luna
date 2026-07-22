//
//  CardCarouselHostViewController.swift
//  Luna
//

import LunaDesignSystem
import UIKit

/// Privacy-safe pasteboard discovery can tell us that a probable URL exists,
/// but UIKit exposes no public API for the app's "Paste from Other Apps"
/// setting. The actual read therefore happens only after the user reaches the
/// synthetic card. A conspicuously long synchronous read is used solely to
/// choose more helpful failure copy; it is never treated as authorization.
struct PasteboardReadResult {
    let value: String?
    let changeCount: Int
    let likelyPresentedPermissionPrompt: Bool
}

enum PasteboardReadTiming {
    static let likelyPermissionPromptThreshold: TimeInterval = 0.25

    static func likelyPresentedPermissionPrompt(elapsed: TimeInterval) -> Bool {
        elapsed >= likelyPermissionPromptThreshold
    }

    @MainActor
    static func readGeneralPasteboard() -> PasteboardReadResult {
        let pasteboard = UIPasteboard.general
        let changeCount = pasteboard.changeCount
        let started = ProcessInfo.processInfo.systemUptime
        let value = pasteboard.url?.absoluteString ?? pasteboard.string
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        return PasteboardReadResult(
            value: value,
            changeCount: changeCount,
            likelyPresentedPermissionPrompt: likelyPresentedPermissionPrompt(elapsed: elapsed))
    }
}

enum PasteboardTemporaryMediaPolicy {
    static let lifetime: TimeInterval = 60 * 60

    static func isExpired(expiresAt: Date, now: Date = Date()) -> Bool {
        expiresAt <= now
    }
}

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

/// The privacy-preserving leading card shown after pattern detection says the
/// pasteboard might contain a URL. Merely constructing/centering it does not
/// access the pasteboard value.
final class PasteboardPlaceholderCardContentViewController: CardContentViewController {
    private let titleText: String
    private let detailText: String

    init(title: String, detail: String) {
        self.titleText = title
        self.detailText = detail
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.isAccessibilityElement = true
        view.accessibilityLabel = titleText
        view.accessibilityHint = detailText
        view.accessibilityTraits = .button

        let icon = UIImageView(image: UIImage(systemName: "doc.on.clipboard"))
        icon.tintColor = GlassStyle.readingAccent
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 42, weight: .medium)

        let title = UILabel()
        title.text = titleText
        title.font = .preferredFont(forTextStyle: .title2)
        title.textColor = .label
        title.textAlignment = .center

        let detail = UILabel()
        detail.text = detailText
        detail.font = .preferredFont(forTextStyle: .subheadline)
        detail.textColor = .secondaryLabel
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
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])
    }
}

/// A failed user-initiated paste read. When timing suggests that the system
/// permission sheet was involved, the Settings reference becomes an inline,
/// tappable link; otherwise the card reports only that the URL is invalid.
final class InvalidPasteCardContentViewController: CardContentViewController, UITextViewDelegate {
    private static let settingsLink = URL(string: "luna-settings://paste")!
    private let showsSettingsGuidance: Bool

    init(showsSettingsGuidance: Bool) {
        self.showsSettingsGuidance = showsSettingsGuidance
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let icon = UIImageView(image: UIImage(systemName: "exclamationmark.circle"))
        icon.tintColor = .secondaryLabel
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 40, weight: .medium)

        let title = UILabel()
        title.text = "Invalid paste"
        title.font = .preferredFont(forTextStyle: .title2)
        title.textColor = .label
        title.textAlignment = .center

        let detail: UIView
        if showsSettingsGuidance {
            detail = makeSettingsTextView()
        } else {
            let label = UILabel()
            label.text = "Invalid URL"
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.textColor = .secondaryLabel
            label.textAlignment = .center
            label.numberOfLines = 0
            detail = label
        }

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

    private func makeSettingsTextView() -> UITextView {
        let font = UIFont.preferredFont(forTextStyle: .subheadline)
        let text = NSMutableAttributedString(string: "Go to ", attributes: [
            .font: font, .foregroundColor: UIColor.secondaryLabel,
        ])
        let linkStart = text.length
        let attachment = NSTextAttachment()
        attachment.image = UIImage(systemName: "gearshape.fill")?.withTintColor(
            .secondaryLabel, renderingMode: .alwaysOriginal)
        attachment.bounds = CGRect(x: 0, y: -3, width: 16, height: 16)
        text.append(NSAttributedString(attachment: attachment))
        text.append(NSAttributedString(string: " Settings", attributes: [
            .font: font, .foregroundColor: UIColor.link,
        ]))
        text.addAttribute(
            .link, value: Self.settingsLink,
            range: NSRange(location: linkStart, length: text.length - linkStart))
        text.append(NSAttributedString(
            string: " and select “Allow” under “Paste from Other Apps” to automatically handle pastes from now on.",
            attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel]))

        let textView = UITextView()
        textView.attributedText = text
        textView.delegate = self
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.textAlignment = .center
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.linkTextAttributes = [.foregroundColor: UIColor.link]
        return textView
    }

    func textView(
        _ textView: UITextView, primaryActionFor textItem: UITextItem,
        defaultAction: UIAction
    ) -> UIAction? {
        guard case .link(let url) = textItem.content, url == Self.settingsLink,
              let settingsURL = Foundation.URL(string: UIApplication.openSettingsURLString)
        else { return defaultAction }
        return UIAction { _ in UIApplication.shared.open(settingsURL) }
    }
}
