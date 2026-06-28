//
//  SplitWebOverlayViewController.swift
//  Clip
//

import ClipDesignSystem
import ClipModels
import UIKit

/// The inline reader shown when a link is tapped in the scroll reader.
///
/// The outer reader is snapshotted (in WINDOW coordinates) and split at the top of
/// the tapped link's line. An inset rounded glass card grows out from the cut to
/// the space between a one-line top peek (the line above the link) and a one-line
/// bottom peek (the link's line). A themed strip covers the status-bar band so the
/// outer reader's header tucks out of sight while the inline reader is open.
///
/// The card hosts a navigation stack of `InlineReaderPageViewController`s: the first
/// is the tapped link; tapping a link inside an embedded reader PUSHES the next page
/// (the ✕ becomes a back chevron) rather than nesting another overlay. The pages
/// render the linked page with the app reader when it's article-like, otherwise a
/// themed web view; a floating glass header holds the close/back, mode switcher, and
/// save controls.
///
/// All split motion is a single `progress` (0 = fully open, 1 = closed back onto the
/// cut line). The peeks are derived FROM the interpolating card frame so they stay
/// flush with it. Dismiss via the ✕ (at the stack root), the bottom chevron, or an
/// interactive drag on either peek — each dismisses the WHOLE stack.
public final class SplitWebOverlayViewController: UIViewController, UIGestureRecognizerDelegate,
                                           UINavigationControllerDelegate {

    /// Called once on dismissal (the reader never moved — the overlay covered it).
    public var onDismiss: (() -> Void)?
    /// Called as the card opens / closes, so the presenter can tuck the outer
    /// reader's header out of sight while the inline reader is up (animated in sync).
    public var onOpen: (() -> Void)?
    public var onClose: (() -> Void)?

    private let url: URL
    private let shareProvider: ReaderShareProviding?
    private let lineHeight: CGFloat
    /// Window-y of the top of the tapped link's line (clamped so the peeks fit).
    private var cutY: CGFloat
    private let topHalf: UIView?
    private let bottomHalf: UIView?

    private let dimView = UIView()
    /// Themed strip over the status-bar band — hides the outer reader's header that
    /// would otherwise show through there once the card opens.
    private let topCover = UIView()
    private let card = UIView()
    private let cardShadow = UIView()
    private let header = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    private let closeButton = UIButton(type: .system)
    private let saveButton = UIButton(type: .system)
    private let bottomChevron = UIButton(type: .system)
    private let modeControl = UISegmentedControl()

    /// Navigation stack of inline pages (root = the tapped link).
    private let innerNav = UINavigationController()

    private static let cardInset: CGFloat = 12
    /// Extra gap below the card so the outer reader shows through more at the bottom.
    private static let bottomReaderInset: CGFloat = 36
    private static let cardCornerRadius: CGFloat = 26
    private static let buttonSize: CGFloat = 40
    private static let headerHeight: CGFloat = 68
    private static let buttonInset: CGFloat = 16
    // `.original` here = the live original web page (the inline reader has no saved
    // archive, so Original loads the URL in a web view) — offered alongside the
    // reader modes so the user can always see the source page.
    private static let orderedModes: [ReadingListItem.ReaderMode] = [.scroll, .rsvp, .original]

    private var didLayoutInitial = false
    private var didAnimateIn = false
    private var didDismiss = false
    /// Once a drag fully compresses the card it dismisses and stops responding —
    /// dragging back must not re-grow it.
    private var isClosing = false

    public init(url: URL, shareProvider: ReaderShareProviding?, lineHeight: CGFloat,
         cutY: CGFloat, topHalf: UIView?, bottomHalf: UIView?) {
        self.url = url
        self.shareProvider = shareProvider
        self.lineHeight = max(lineHeight, 18)
        self.cutY = cutY
        self.topHalf = topHalf
        self.bottomHalf = bottomHalf
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        // With peeks (from the scroll reader) the side margins show the dimmed
        // reader; without them (the RSVP pill) the card grows from center over an
        // OPAQUE themed backdrop so nothing of the outer screen shows through.
        dimView.backgroundColor = hasPeeks
            ? UIColor.black.withAlphaComponent(0.35)
            : ReaderDepth.backgroundColor(for: 0)
        dimView.frame = view.bounds
        dimView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(dimView)

        // The peeks are snapshots clipped to their own bounds so they never bleed
        // past where they sit on screen.
        for half in [topHalf, bottomHalf].compactMap({ $0 }) {
            half.clipsToBounds = true
            half.isUserInteractionEnabled = true
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePeekPan(_:)))
            pan.delegate = self
            half.addGestureRecognizer(pan)
            view.addSubview(half)
        }

        // Above the peeks so the slice of the outer header that the top peek would
        // otherwise show in the status-bar band stays hidden behind a themed strip.
        topCover.backgroundColor = ReaderDepth.backgroundColor(for: 0)
        view.addSubview(topCover)

        cardShadow.backgroundColor = .clear
        cardShadow.layer.shadowColor = UIColor.black.cgColor
        cardShadow.layer.shadowOpacity = 0.22
        cardShadow.layer.shadowRadius = 18
        cardShadow.layer.shadowOffset = CGSize(width: 0, height: 6)
        view.addSubview(cardShadow)

        card.backgroundColor = ReaderDepth.backgroundColor(for: 0)
        card.layer.cornerRadius = Self.cardCornerRadius
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 0.5
        card.layer.borderColor = UIColor.separator.withAlphaComponent(0.6).cgColor
        card.clipsToBounds = true
        view.addSubview(card)

        setUpInnerNav()         // page navigation stack fills the card
        configureHeader()       // glass header over the pages
        configureChevron()
    }

    /// Establish the seamless progress = 1 layout BEFORE the first frame is shown,
    /// so opening never flashes a half-laid-out copy of the reader. The peeks keep
    /// their captured (natural) bounds; `apply` positions them by origin.
    /// Lay out collapsed AND kick off the open animation in the same pass. Doing both
    /// here (rather than waiting for `viewDidAppear`) removes the one-runloop gap that
    /// otherwise showed the collapsed sliver as a brief stall before the card grew.
    public override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        guard !didLayoutInitial else { return }
        didLayoutInitial = true
        cutY = min(max(cutY, openCardFrame.minY), openCardFrame.maxY)
        apply(progress: 1)
        dimView.alpha = 1
        animateOpen()
    }

    private func animateOpen() {
        guard !didAnimateIn else { return }
        didAnimateIn = true
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        onOpen?()
        // A higher initial velocity + lighter damping so the card starts moving on the
        // first frame instead of easing in slowly (which read as a pre-open delay).
        UIView.animate(withDuration: 0.34, delay: 0, usingSpringWithDamping: 0.82,
                       initialSpringVelocity: 1.0, options: [.beginFromCurrentState]) {
            self.apply(progress: 0)
        }
    }

    // MARK: - Geometry

    private var hasPeeks: Bool { topHalf != nil || bottomHalf != nil }

    private var openCardFrame: CGRect {
        let width = view.bounds.width
        let peek = hasPeeks ? lineHeight : 0
        let top = view.safeAreaInsets.top + peek
        // Leave extra room at the bottom so more of the outer reader stays visible
        // there and the card's bottom edge sits a little higher up the screen.
        let bottom = view.bounds.height - view.safeAreaInsets.bottom - peek - Self.bottomReaderInset
        return CGRect(x: Self.cardInset, y: top,
                      width: width - Self.cardInset * 2, height: max(bottom - top, 0))
    }

    /// Lays everything out for compression `progress` (0 open … 1 closed onto the
    /// cut). The card interpolates between its open frame and a zero-height sliver
    /// at `cutY`; the peeks are pinned flush to the card's top/bottom edges.
    private func apply(progress p: CGFloat) {
        let clamped = min(max(p, 0), 1)
        let open = openCardFrame
        let cardTop = open.minY + (cutY - open.minY) * clamped
        let cardBottom = open.maxY + (cutY - open.maxY) * clamped
        let frame = CGRect(x: open.minX, y: cardTop, width: open.width, height: max(cardBottom - cardTop, 0))

        card.frame = frame
        cardShadow.frame = frame
        cardShadow.layer.shadowPath = UIBezierPath(
            roundedRect: CGRect(origin: .zero, size: frame.size),
            cornerRadius: Self.cardCornerRadius).cgPath
        innerNav.view.frame = card.bounds
        layoutHeader()

        // Peeks flush to the card edges → no gap for the live reader to show through.
        if let topHalf { topHalf.frame.origin.y = cardTop - topHalf.bounds.height }
        if let bottomHalf { bottomHalf.frame.origin.y = cardBottom }

        // Themed strip covering EVERYTHING above the top peek — not just the status
        // bar. Whatever the cut position, the outer reader's header sits behind this
        // opaque strip the whole time the card animates (when the link is high up the
        // top peek is tiny and never covers the header band on its own).
        let topPeekTop = topHalf.map { $0.frame.origin.y } ?? cardTop
        let coverBottom = max(view.safeAreaInsets.top, topPeekTop)
        topCover.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: max(coverBottom, 0))

        // Chevron straddles the card's bottom edge, kept clear of the home indicator.
        let chevronY = min(cardBottom, view.bounds.height - view.safeAreaInsets.bottom - 6)
        bottomChevron.center = CGPoint(x: frame.midX, y: chevronY)

        let chromeAlpha = 1 - clamped
        header.alpha = chromeAlpha
        bottomChevron.alpha = chromeAlpha
    }

    // MARK: - Dismiss

    private func animateDismiss() {
        guard !didDismiss else { return }
        didDismiss = true
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        onClose?()
        // A high-damping spring (matching the open) reads smoother than the old
        // ease-in, which accelerated abruptly into the close.
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.9,
                       initialSpringVelocity: 0.85, options: [.beginFromCurrentState]) {
            self.apply(progress: 1)
            self.dimView.alpha = 0
        } completion: { _ in
            self.onDismiss?()
            self.dismiss(animated: false)
        }
    }

    // MARK: - Interactive peek drag

    @objc private func handlePeekPan(_ gesture: UIPanGestureRecognizer) {
        guard !didDismiss, !isClosing else { return }
        let openHeight = max(openCardFrame.height, 1)
        let progress = min((abs(gesture.translation(in: view).y) * 2) / openHeight, 1)

        switch gesture.state {
        case .changed:
            apply(progress: progress)
            if progress >= 1 {   // fully compressed → dismiss; never re-grow
                isClosing = true
                animateDismiss()
            }
        case .ended, .cancelled:
            if progress >= 0.5 || abs(gesture.velocity(in: view).y) > 800 {
                animateDismiss()
            } else {
                UIView.animate(withDuration: 0.25) { self.apply(progress: 0) }
            }
        default:
            break
        }
    }

    // MARK: - Inner navigation stack

    private func setUpInnerNav() {
        let root = makePage(url: url)
        innerNav.setViewControllers([root], animated: false)
        innerNav.setNavigationBarHidden(true, animated: false)
        innerNav.delegate = self
        // Our glass back button drives the stack; the edge-swipe would fight the
        // peek-drag dismissal, so it's disabled.
        innerNav.interactivePopGestureRecognizer?.isEnabled = false
        addChild(innerNav)
        card.addSubview(innerNav.view)
        innerNav.didMove(toParent: self)
    }

    private func makePage(url: URL) -> InlineReaderPageViewController {
        let page = InlineReaderPageViewController(
            url: url, shareProvider: shareProvider, headerHeight: Self.headerHeight)
        page.onLinkActivated = { [weak self] linkURL in self?.pushPage(url: linkURL) }
        page.onBecameArticle = { [weak self] in self?.syncHeaderToTopPage() }
        return page
    }

    private func pushPage(url: URL) {
        guard !didDismiss else { return }
        innerNav.pushViewController(makePage(url: url), animated: true)
    }

    private var topPage: InlineReaderPageViewController? {
        innerNav.topViewController as? InlineReaderPageViewController
    }

    public func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController, animated: Bool
    ) {
        syncHeaderToTopPage()
    }

    /// Reflects the top page in the header: ✕ at the root vs. a back chevron deeper
    /// in the stack, and the mode switcher only when the top page is an article.
    private func syncHeaderToTopPage() {
        let isRoot = innerNav.viewControllers.count <= 1
        closeButton.configuration = GlassStyle.circularButtonConfiguration(
            symbol: isRoot ? "xmark" : "chevron.backward")

        let showsModes = topPage?.isArticle ?? false
        modeControl.isHidden = !showsModes
        if showsModes, let mode = topPage?.readerMode,
           let index = Self.orderedModes.firstIndex(of: mode) {
            modeControl.selectedSegmentIndex = index
        }
        // A fresh page can save again.
        saveButton.configuration = Self.saveButtonConfiguration(title: "Save")
        saveButton.tintColor = GlassStyle.readingAccent
        saveButton.isEnabled = true
        layoutHeader()
    }

    // MARK: - Chrome

    private func configureHeader() {
        header.clipsToBounds = true
        header.layer.cornerRadius = Self.cardCornerRadius
        header.layer.cornerCurve = .continuous
        header.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        card.addSubview(header)

        closeButton.configuration = GlassStyle.circularButtonConfiguration(symbol: "xmark")
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        header.contentView.addSubview(closeButton)

        // Mode switcher (scroll / chunk / speed), shown only when the top page is
        // rendered with the app reader.
        for (index, mode) in Self.orderedModes.enumerated() {
            modeControl.insertSegment(with: ReaderModeIcons.image(for: mode), at: index, animated: false)
        }
        modeControl.selectedSegmentIndex = 0
        modeControl.isHidden = true
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        header.contentView.addSubview(modeControl)

        if shareProvider != nil {
            saveButton.configuration = Self.saveButtonConfiguration(title: "Save")
            saveButton.tintColor = GlassStyle.readingAccent
            saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)
            header.contentView.addSubview(saveButton)
        }
    }

    /// The save button shows the word "Save" (then "Saved") in a glass capsule
    /// rather than an icon, tinted with the reading accent.
    private static func saveButtonConfiguration(title: String) -> UIButton.Configuration {
        var config: UIButton.Configuration = {
            if #available(iOS 26.0, *) { return .glass() }
            return .tinted()
        }()
        config.title = title
        config.cornerStyle = .capsule
        config.baseForegroundColor = GlassStyle.readingAccent
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
        return config
    }

    private func layoutHeader() {
        header.frame = CGRect(x: 0, y: 0, width: card.bounds.width, height: Self.headerHeight)
        let s = Self.buttonSize
        let y = (Self.headerHeight - s) / 2
        closeButton.frame = CGRect(x: Self.buttonInset, y: y, width: s, height: s)

        // The save button is a text capsule — size it to its title, keeping a capsule
        // height equal to the close button.
        var trailingWidth = s
        if saveButton.superview != nil {
            let fit = saveButton.sizeThatFits(CGSize(width: card.bounds.width, height: s))
            let saveWidth = max(fit.width, s)
            saveButton.frame = CGRect(
                x: card.bounds.width - saveWidth - Self.buttonInset, y: y, width: saveWidth, height: s)
            trailingWidth = saveWidth
        }

        // Keep the centered mode switcher clear of whichever side button is wider.
        let sideReserve = Self.buttonInset + max(s, trailingWidth) + 8
        let modeSize = modeControl.sizeThatFits(CGSize(width: card.bounds.width, height: 36))
        let modeWidth = min(modeSize.width, card.bounds.width - sideReserve * 2)
        modeControl.frame = CGRect(
            x: (card.bounds.width - modeWidth) / 2, y: (Self.headerHeight - 34) / 2,
            width: modeWidth, height: 34)
    }

    @objc private func modeChanged() {
        let mode = Self.orderedModes[
            max(0, min(modeControl.selectedSegmentIndex, Self.orderedModes.count - 1))]
        topPage?.setMode(mode)
    }

    private func configureChevron() {
        var config = GlassStyle.circularButtonConfiguration(symbol: "chevron.compact.down")
        config.baseForegroundColor = GlassStyle.readingAccent   // blue icon
        bottomChevron.configuration = config
        bottomChevron.tintColor = GlassStyle.readingAccent
        bottomChevron.bounds = CGRect(x: 0, y: 0, width: Self.buttonSize, height: Self.buttonSize)
        bottomChevron.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)
        view.addSubview(bottomChevron)
    }

    /// ✕ at the stack root dismisses the whole overlay; deeper in, it pops one page.
    @objc private func closeTapped() {
        if innerNav.viewControllers.count > 1 {
            innerNav.popViewController(animated: true)
        } else {
            animateDismiss()
        }
    }

    @objc private func dismissTapped() { animateDismiss() }

    @objc private func saveTapped() {
        guard let target = topPage?.url else { return }
        shareProvider?.saveLink(urlString: target.absoluteString)
        saveButton.configuration = Self.saveButtonConfiguration(title: "Saved")
        saveButton.tintColor = GlassStyle.readingAccent
        saveButton.isEnabled = false
        layoutHeader()
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { false }
}
