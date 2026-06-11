//
//  SplitWebOverlayViewController.swift
//  Clip
//

import UIKit
import WebKit

/// The inline frame that "cuts" the article when a link is tapped.
///
/// Layout is one outer scroll view stacked vertically:
///   [ peek: article text ending with the full line containing the link ]
///   [ top border with a notch pointing down from the tapped link        ]
///   [ the linked page: a NESTED READER when the page is article-like,   ]
///   [   otherwise a web view at full content height                     ]
///   [ bottom border with a notch pointing up to the replicated line     ]
///   [ the rest of the article, starting with that same link line        ]
///
/// Nested readers get a slightly lighter background per depth level and their
/// links open further overlays (recursively, same container behavior).
final class SplitWebOverlayViewController: UIViewController, UIScrollViewDelegate {

    /// Called exactly once on dismissal with the reader content offset to restore.
    var onDismiss: ((CGFloat) -> Void)?

    private let url: URL
    private let articleText: NSAttributedString
    /// Line fragment of the tapped link, in text content coordinates.
    private let lineRect: CGRect
    /// Bounding rect of the tapped link text, in text content coordinates.
    private let linkRect: CGRect
    /// Character range of the tapped link (for highlighting the replicas).
    private let linkRange: NSRange
    private let readerOffset: CGFloat
    /// Full article text height, measured by the reader (avoids re-layout here).
    private let textHeight: CGFloat
    /// Screen captures of the reader above/below the cut, used by the open animation.
    private let topSnapshot: UIView?
    private let bottomSnapshot: UIView?
    /// Nesting level of the PARENT reader (0 = root article).
    private let depth: Int

    private let peekHeight: CGFloat = 96
    private let borderHeight: CGFloat = 26
    private let maxMiddleHeight: CGFloat = 8000
    private let accent = UIColor.systemBlue

    private let outerScroll = UIScrollView()
    private let peekContainer = UIView()
    private let peekTextView = UITextView()
    private let topBorder = UIView()
    private let bottomBorder = UIView()
    private let webView = WKWebView(frame: .zero, configuration: WebJunkBlocker.makeConfiguration())
    /// Rounded clipping wrapper — corner-masking the WKWebView itself breaks
    /// its tile rendering, so the card look lives on this container.
    private let webCard = UIView()
    private let webSpinner = UIActivityIndicatorView(style: .medium)
    private let tailContainer = UIView()
    private let tailTextView = UITextView()
    private let dismissButton = UIButton(type: .system)

    // Nested-reader middle content (replaces the web view when article-like).
    private let nestedContainer = UIView()
    private let nestedTextView = UITextView()
    private var nestedText: NSAttributedString?
    private var nestedTextHeight: CGFloat = 0
    private var isNestedReader = false

    private var middleHeight: CGFloat = 0
    private var pendingMiddleHeight: CGFloat?
    private var contentSizeObservation: NSKeyValueObservation?
    private var didDismiss = false
    private var didAnimateIn = false
    private var slicesInstalled = false
    private var didApplySafeAreaInset = false
    private var articleProbeTask: Task<Void, Never>?

    /// Top of the link's line — the continuation below the frame starts here.
    private var cutTop: CGFloat { lineRect.minY }
    /// Bottom of the link's line — the peek above the frame ends here.
    private var cutBottom: CGFloat { lineRect.maxY }
    /// Content-y where the middle region ends (start of the continuation).
    private var middleEnd: CGFloat { peekHeight + borderHeight + middleHeight + borderHeight }
    private var middleStart: CGFloat { peekHeight + borderHeight }

    private var parentBackground: UIColor { ReaderDepth.backgroundColor(for: depth) }
    private var nestedBackground: UIColor { ReaderDepth.backgroundColor(for: depth + 1) }

    init(url: URL, articleText: NSAttributedString, lineRect: CGRect, linkRect: CGRect,
         linkRange: NSRange, readerOffset: CGFloat, textHeight: CGFloat,
         topSnapshot: UIView?, bottomSnapshot: UIView?, depth: Int = 0) {
        self.url = url
        self.articleText = articleText
        self.lineRect = lineRect
        self.linkRect = linkRect
        self.linkRange = linkRange
        self.readerOffset = readerOffset
        self.textHeight = textHeight
        self.topSnapshot = topSnapshot
        self.bottomSnapshot = bottomSnapshot
        self.depth = depth
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        contentSizeObservation?.invalidate()
        articleProbeTask?.cancel()
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = parentBackground

        outerScroll.delegate = self
        outerScroll.alwaysBounceVertical = true
        outerScroll.contentInsetAdjustmentBehavior = .never
        outerScroll.frame = view.bounds
        outerScroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(outerScroll)

        peekContainer.clipsToBounds = true
        peekContainer.backgroundColor = parentBackground
        tailContainer.clipsToBounds = true
        tailContainer.backgroundColor = parentBackground
        nestedContainer.clipsToBounds = true
        nestedContainer.backgroundColor = nestedBackground

        // The web frame is a read-only preview: all gestures must reach the outer
        // scroll view (interactive page regions would otherwise swallow pans).
        webView.scrollView.isScrollEnabled = false
        webView.isUserInteractionEnabled = false
        webCard.layer.cornerRadius = 22
        webCard.layer.cornerCurve = .continuous
        webCard.clipsToBounds = true
        webCard.backgroundColor = .systemBackground
        webCard.addSubview(webView)

        webSpinner.hidesWhenStopped = true
        webSpinner.startAnimating()

        configureBorder(topBorder, notchPointsDown: true)
        configureBorder(bottomBorder, notchPointsDown: false)

        outerScroll.addSubview(peekContainer)
        outerScroll.addSubview(topBorder)
        outerScroll.addSubview(webCard)
        outerScroll.addSubview(webSpinner)
        outerScroll.addSubview(bottomBorder)
        outerScroll.addSubview(tailContainer)

        configureDismissButton()

        middleHeight = view.bounds.height
        layoutContent()

        contentSizeObservation = webView.scrollView.observe(\.contentSize, options: [.new]) {
            [weak self] scrollView, _ in
            DispatchQueue.main.async {
                self?.webContentSizeChanged(scrollView.contentSize.height)
            }
        }
        webView.navigationDelegate = self
        WebJunkBlocker.applyRuleList(to: webView.configuration.userContentController)
        webView.load(URLRequest(url: url))

        probeForArticle()

        dismissButton.alpha = 0
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        // Keep the peek strip below the status bar initially; it still scrolls
        // under it once the user starts scrolling.
        guard !didApplySafeAreaInset, view.safeAreaInsets.top > 0 else { return }
        didApplySafeAreaInset = true
        outerScroll.contentInset.top = view.safeAreaInsets.top
        outerScroll.contentOffset.y = -view.safeAreaInsets.top
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didAnimateIn else { return }
        didAnimateIn = true
        animateSplitIn()
    }

    // MARK: - Article probe (nested reader)

    /// Fetches and extracts the linked page concurrently with the web load.
    /// If it's article-like — substantial text across several blocks — the web
    /// view is swapped for a nested reader, unless the user is already
    /// scrolling through the web content.
    private func probeForArticle() {
        let targetURL = url
        articleProbeTask = Task { [weak self] in
            let content: ArticleContent? = await Task.detached(priority: .userInitiated) {
                guard let html = try? await ArticleFetcher().fetchHTML(from: targetURL) else {
                    return nil
                }
                return try? ArticleExtractor().extract(html: html, baseURL: targetURL)
            }.value

            guard let self, !Task.isCancelled, let content else { return }
            let textBlocks = content.blocks.filter { !$0.text.isEmpty }
            let totalText = textBlocks.reduce(0) { $0 + $1.text.count }
            let isArticle = totalText >= 1200 && textBlocks.count >= 5
            guard isArticle else { return }

            await MainActor.run {
                self.switchToNestedReader(content)
            }
        }
    }

    private func switchToNestedReader(_ content: ArticleContent) {
        guard !didDismiss, !isNestedReader else { return }
        // Don't yank the web view out from under someone already reading it.
        guard outerScroll.contentOffset.y < peekHeight else { return }

        let rendered = ArticleTextRenderer.render(content)
        nestedText = rendered.text

        // One-time full measure of the nested article (TextKit 1 for metric
        // consistency with the viewport text view that will display it).
        let measuringView = UITextView()
        _ = measuringView.layoutManager
        measuringView.attributedText = rendered.text
        measuringView.textContainerInset = UIEdgeInsets(top: 20, left: 20, bottom: 40, right: 20)
        let fitted = measuringView.sizeThatFits(
            CGSize(width: view.bounds.width, height: .greatestFiniteMagnitude))
        nestedTextHeight = fitted.height

        _ = nestedTextView.layoutManager
        nestedTextView.attributedText = rendered.text
        nestedTextView.isEditable = false
        nestedTextView.isSelectable = true
        nestedTextView.isScrollEnabled = true
        nestedTextView.showsVerticalScrollIndicator = false
        nestedTextView.contentInsetAdjustmentBehavior = .never
        nestedTextView.textContainerInset = UIEdgeInsets(top: 20, left: 20, bottom: 40, right: 20)
        nestedTextView.backgroundColor = nestedBackground
        nestedTextView.linkTextAttributes = [
            .foregroundColor: accent,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        // The text view is fully non-interactive so every pan reaches the
        // outer scroll (UIScrollView silently re-enables a disabled pan
        // recognizer, which made the nested reader scroll independently).
        // Link taps are resolved manually via a recognizer on the CONTAINER.
        nestedTextView.isSelectable = false
        nestedTextView.isUserInteractionEnabled = false
        let tap = UITapGestureRecognizer(target: self, action: #selector(nestedReaderTapped(_:)))
        nestedContainer.addGestureRecognizer(tap)

        webView.stopLoading()
        contentSizeObservation?.invalidate()
        contentSizeObservation = nil
        webCard.removeFromSuperview()
        webSpinner.stopAnimating()

        nestedContainer.addSubview(nestedTextView)
        outerScroll.addSubview(nestedContainer)

        isNestedReader = true
        applyMiddleHeight(min(nestedTextHeight, maxMiddleHeight))
    }

    /// Floats the nested reader's viewport-sized text view over the on-screen
    /// part of its region, mirroring the tail's lazy-layout pattern.
    private func updateNestedViewport() {
        guard isNestedReader else { return }
        let viewportHeight = view.bounds.height
        let regionHeight = nestedContainer.bounds.height
        let intoRegion = outerScroll.contentOffset.y - nestedContainer.frame.minY
        let floatY = min(max(0, intoRegion), max(0, regionHeight - viewportHeight))
        nestedTextView.frame = CGRect(
            x: 0, y: floatY, width: nestedContainer.bounds.width,
            height: min(viewportHeight, regionHeight))
        let maxOffset = max(0, nestedTextHeight - nestedTextView.bounds.height)
        nestedTextView.contentOffset.y = min(floatY, maxOffset)
    }

    // MARK: - Slices

    /// The slices are viewport-sized SCROLLABLE text views with driven offsets:
    /// scrollable text views lay out lazily, so the whole article is never laid
    /// out at once.
    private func installSliceTextViewsIfNeeded() {
        guard !slicesInstalled else { return }
        slicesInstalled = true
        configureSliceTextView(peekTextView)
        configureSliceTextView(tailTextView)
        peekContainer.addSubview(peekTextView)
        tailContainer.addSubview(tailTextView)
        layoutContent()
        // The text views clamp programmatic offsets against a stale (pre-first-
        // layout) contentSize; one more pass on the next runloop sticks.
        DispatchQueue.main.async { [weak self] in
            self?.layoutContent()
        }
    }

    private func configureSliceTextView(_ textView: UITextView) {
        // TextKit 1 from the start, matching the reader — TK1 and TK2 break
        // lines slightly differently, which would make the slices' text sit a
        // hair off from the reader's and "jump" during open/close.
        _ = textView.layoutManager
        let text = NSMutableAttributedString(attributedString: articleText)
        if linkRange.location + linkRange.length <= text.length {
            text.addAttribute(
                .backgroundColor, value: accent.withAlphaComponent(0.18), range: linkRange)
        }
        textView.attributedText = text
        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = true
        textView.isUserInteractionEnabled = false
        textView.showsVerticalScrollIndicator = false
        textView.contentInsetAdjustmentBehavior = .never
        textView.textContainerInset = UIEdgeInsets(top: 20, left: 20, bottom: 40, right: 20)
        textView.backgroundColor = parentBackground
        textView.linkTextAttributes = [
            .foregroundColor: accent,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
    }

    /// Keeps the tail's viewport-sized text view floating over the part of the
    /// tail region that's on screen — one screen of text laid out at any time.
    private func updateTailViewport() {
        guard slicesInstalled else { return }
        let viewportHeight = view.bounds.height
        let tailHeight = tailContainer.bounds.height
        let intoTail = outerScroll.contentOffset.y - tailContainer.frame.minY
        let floatY = min(max(0, intoTail), max(0, tailHeight - viewportHeight))
        tailTextView.frame = CGRect(
            x: 0, y: floatY, width: view.bounds.width,
            height: min(viewportHeight, tailHeight))
        let maxOffset = max(0, textHeight - tailTextView.bounds.height)
        tailTextView.contentOffset.y = min(cutTop + floatY, maxOffset)
    }

    /// A quiet band separating text from the inline frame; a small floating
    /// glass chip with a chevron sits at the tapped link's x-position, tying
    /// the frame to the link that opened it.
    private func configureBorder(_ border: UIView, notchPointsDown: Bool) {
        border.backgroundColor = .clear

        let chip = UIVisualEffectView(effect: GlassStyle.barEffect())
        chip.tag = 102
        chip.clipsToBounds = true
        chip.layer.cornerRadius = 11
        chip.layer.cornerCurve = .continuous
        let chevron = UIImageView(image: UIImage(
            systemName: notchPointsDown ? "chevron.compact.down" : "chevron.compact.up"))
        chevron.tintColor = accent
        chevron.contentMode = .center
        chevron.tag = 103
        chip.contentView.addSubview(chevron)
        border.addSubview(chip)
    }

    private func layoutBorderDecorations(_ border: UIView, notchPointsDown: Bool) {
        let width = border.bounds.width
        guard let chip = border.viewWithTag(102) else { return }
        let chipWidth: CGFloat = 46
        let chipHeight: CGFloat = 22
        let chipX = min(max(linkRect.midX - chipWidth / 2, 20), width - chipWidth - 20)
        chip.frame = CGRect(
            x: chipX, y: (border.bounds.height - chipHeight) / 2,
            width: chipWidth, height: chipHeight)
        border.viewWithTag(103)?.frame = chip.bounds
    }

    private func configureDismissButton() {
        dismissButton.configuration = GlassStyle.circularButtonConfiguration(symbol: "xmark")
        dismissButton.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)
        dismissButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dismissButton)
        NSLayoutConstraint.activate([
            dismissButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            dismissButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
        ])
    }

    // MARK: - Layout

    private func layoutContent() {
        let width = view.bounds.width
        let tailHeight = max(0, textHeight - cutTop)

        peekContainer.frame = CGRect(x: 0, y: 0, width: width, height: peekHeight)
        if slicesInstalled {
            peekTextView.frame = peekContainer.bounds
            peekTextView.contentOffset.y = cutBottom - peekHeight
        }

        topBorder.frame = CGRect(x: 0, y: peekHeight, width: width, height: borderHeight)
        layoutBorderDecorations(topBorder, notchPointsDown: true)

        let cardInset: CGFloat = 10
        if isNestedReader {
            nestedContainer.frame = CGRect(
                x: cardInset, y: middleStart, width: width - cardInset * 2, height: middleHeight)
            nestedContainer.layer.cornerRadius = 22
            nestedContainer.layer.cornerCurve = .continuous
            updateNestedViewport()
        } else {
            webCard.frame = CGRect(
                x: cardInset, y: middleStart, width: width - cardInset * 2, height: middleHeight)
            webView.frame = webCard.bounds
            webSpinner.center = CGPoint(
                x: width / 2, y: middleStart + view.bounds.height / 3)
        }

        bottomBorder.frame = CGRect(
            x: 0, y: middleStart + middleHeight, width: width, height: borderHeight)
        layoutBorderDecorations(bottomBorder, notchPointsDown: false)

        tailContainer.frame = CGRect(x: 0, y: middleEnd, width: width, height: tailHeight)
        updateTailViewport()

        outerScroll.contentSize = CGSize(width: width, height: middleEnd + tailHeight)
    }

    /// Defers height changes while the user is scrolling so nothing jumps
    /// mid-gesture; applies them when the scroll settles.
    private func webContentSizeChanged(_ contentHeight: CGFloat) {
        guard !isNestedReader else { return }
        let newHeight = min(max(contentHeight, view.bounds.height), maxMiddleHeight)
        guard abs(newHeight - middleHeight) > 1 else { return }
        if outerScroll.isDragging || outerScroll.isDecelerating {
            pendingMiddleHeight = newHeight
            return
        }
        applyMiddleHeight(newHeight)
    }

    private func applyMiddleHeight(_ newHeight: CGFloat) {
        let delta = newHeight - middleHeight
        middleHeight = newHeight
        pendingMiddleHeight = nil
        // If the user is already past the middle frame, shift the offset with
        // the content so the visible text doesn't move.
        let wasBeyondMiddle = outerScroll.contentOffset.y > middleStart + (middleHeight - delta)
        layoutContent()
        if wasBeyondMiddle {
            outerScroll.contentOffset.y += delta
        }
    }

    private func applyPendingMiddleHeightIfIdle() {
        guard let pending = pendingMiddleHeight,
              !outerScroll.isDragging, !outerScroll.isDecelerating else { return }
        applyMiddleHeight(pending)
    }

    // MARK: - Part-open animation

    /// The reader's halves part vertically using screen snapshots: the half
    /// above the cut (ending with the link's line) slides up to become the
    /// peek; the half below — which begins with that same line — slides down
    /// off screen, leaving the line replicated on both sides of the frame.
    private func animateSplitIn() {
        let height = view.bounds.height
        let safeTop = view.safeAreaInsets.top
        let cutBottomScreen = cutBottom - readerOffset
        let cutTopScreen = cutTop - readerOffset

        guard let topSnapshot, let bottomSnapshot else {
            installSliceTextViewsIfNeeded()
            dismissButton.alpha = 1
            return
        }

        topSnapshot.frame = CGRect(
            x: 0, y: 0, width: view.bounds.width, height: max(cutBottomScreen, 1))
        bottomSnapshot.frame = CGRect(
            x: 0, y: cutTopScreen, width: view.bounds.width,
            height: max(height - cutTopScreen, 1))
        view.insertSubview(topSnapshot, belowSubview: dismissButton)
        view.insertSubview(bottomSnapshot, belowSubview: dismissButton)

        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        UIView.animate(
            withDuration: 0.45, delay: 0,
            usingSpringWithDamping: 0.9, initialSpringVelocity: 0.2,
            animations: {
                topSnapshot.frame.origin.y = safeTop + self.peekHeight - cutBottomScreen
                bottomSnapshot.frame.origin.y = height
                self.dismissButton.alpha = 1
            },
            completion: { _ in
                self.installSliceTextViewsIfNeeded()
                topSnapshot.removeFromSuperview()
                bottomSnapshot.removeFromSuperview()
            })
    }

    // MARK: - Collapse (reverse of open)

    /// The halves close back over the inline frame: the peek slides down until
    /// the link's line sits where it was in the reader, the tail slides up to
    /// meet it, and the frame disappears underneath.
    private func animateCollapse() {
        guard !didDismiss else { return }
        didDismiss = true
        onDismiss?(readerOffset)
        guard slicesInstalled else {
            dismiss(animated: false)
            return
        }

        let width = view.bounds.width
        let cutBottomScreen = cutBottom - readerOffset
        let cutTopScreen = cutTop - readerOffset

        // Reparent the live slices above the scroll view so they can close
        // over the (shrinking) frame — no new text layout needed.
        let peekFrame = outerScroll.convert(peekContainer.frame, to: view)
        let tailFrame = outerScroll.convert(tailContainer.frame, to: view)
        peekContainer.frame = peekFrame
        tailContainer.frame = tailFrame
        view.insertSubview(peekContainer, belowSubview: dismissButton)
        view.insertSubview(tailContainer, belowSubview: dismissButton)

        // Anchor the tail's viewport to the start of the continuation so the
        // closing half shows the text the reader will show underneath.
        tailTextView.frame.origin.y = 0
        tailTextView.contentOffset.y = cutTop

        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        UIView.animate(
            withDuration: 0.4, delay: 0,
            usingSpringWithDamping: 0.95, initialSpringVelocity: 0.2,
            animations: {
                let peekTarget = CGRect(x: 0, y: 0, width: width, height: max(cutBottomScreen, 1))
                self.peekContainer.frame = peekTarget
                self.peekTextView.frame = CGRect(origin: .zero, size: peekTarget.size)
                self.peekTextView.contentOffset.y = self.readerOffset
                self.tailContainer.frame.origin.y = cutTopScreen
                self.dismissButton.alpha = 0
            },
            completion: { _ in
                self.dismiss(animated: false)
            })
    }

    // MARK: - Seamless scroll-past handoff

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === outerScroll else { return }
        updateTailViewport()
        updateNestedViewport()
        // Re-assert the peek's window (UITextView occasionally re-clamps it).
        if slicesInstalled, !didDismiss {
            let peekOffset = cutBottom - peekHeight
            if abs(peekTextView.contentOffset.y - peekOffset) > 0.5 {
                peekTextView.contentOffset.y = peekOffset
            }
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === outerScroll else { return }
        handOffIfPastMiddle()
        applyPendingMiddleHeightIfIdle()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView === outerScroll, !decelerate else { return }
        handOffIfPastMiddle()
        applyPendingMiddleHeightIfIdle()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollView === outerScroll else { return }
        // The frame scrolled fully offscreen and the user touched again:
        // swap back to the reader before this gesture does anything.
        handOffIfPastMiddle()
    }

    /// Once the inline frame is fully above the viewport, the visible content
    /// is pure article text identical to the reader — swap with zero movement.
    private func handOffIfPastMiddle() {
        let offset = outerScroll.contentOffset.y
        guard offset >= middleEnd, !didDismiss else { return }
        didDismiss = true
        onDismiss?(cutTop + (offset - middleEnd))
        dismiss(animated: false)
    }

    @objc private func dismissTapped() {
        animateCollapse()
    }
}

// MARK: - Nested reader link taps → deeper overlay

extension SplitWebOverlayViewController {
    @objc fileprivate func nestedReaderTapped(_ recognizer: UITapGestureRecognizer) {
        let location = recognizer.location(in: nestedTextView)
        let pointInContainer = CGPoint(
            x: location.x - nestedTextView.textContainerInset.left,
            y: location.y - nestedTextView.textContainerInset.top)
        let layoutManager = nestedTextView.layoutManager
        let characterIndex = layoutManager.characterIndex(
            for: pointInContainer, in: nestedTextView.textContainer,
            fractionOfDistanceBetweenInsertionPoints: nil)
        guard let text = nestedText, characterIndex < text.length else { return }
        var linkRange = NSRange(location: 0, length: 0)
        guard let linkURL = text.attribute(.link, at: characterIndex, effectiveRange: &linkRange) as? URL
        else { return }
        openNestedSplit(for: linkURL, tappedRange: linkRange)
    }

    private func openNestedSplit(for linkURL: URL, tappedRange: NSRange) {
        guard let nestedText else { return }
        let layoutManager = nestedTextView.layoutManager
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: tappedRange, actualCharacterRange: nil)
        var nestedLineRect = layoutManager.lineFragmentRect(
            forGlyphAt: glyphRange.location, effectiveRange: nil)
        var nestedLinkRect = layoutManager.boundingRect(
            forGlyphRange: glyphRange, in: nestedTextView.textContainer)
        nestedLineRect.origin.y += nestedTextView.textContainerInset.top
        nestedLinkRect.origin.y += nestedTextView.textContainerInset.top
        nestedLinkRect.origin.x += nestedTextView.textContainerInset.left

        // The nested overlay treats this nested article as "the reader": its
        // coordinates are nested-text coordinates, and the offset at the top
        // of the screen maps back through the region start.
        let regionStart = nestedContainer.frame.minY
        let nestedReaderOffset = outerScroll.contentOffset.y - regionStart

        let width = view.bounds.width
        let height = view.bounds.height
        let cutBottomScreen = nestedLineRect.maxY - nestedReaderOffset
        let cutTopScreen = nestedLineRect.minY - nestedReaderOffset
        let topSnap = view.resizableSnapshotView(
            from: CGRect(x: 0, y: 0, width: width, height: max(cutBottomScreen, 1)),
            afterScreenUpdates: false, withCapInsets: .zero)
        let bottomSnap = view.resizableSnapshotView(
            from: CGRect(x: 0, y: cutTopScreen, width: width,
                         height: max(height - cutTopScreen, 1)),
            afterScreenUpdates: false, withCapInsets: .zero)

        let deeper = SplitWebOverlayViewController(
            url: linkURL,
            articleText: nestedText,
            lineRect: nestedLineRect,
            linkRect: nestedLinkRect,
            linkRange: tappedRange,
            readerOffset: nestedReaderOffset,
            textHeight: nestedTextHeight,
            topSnapshot: topSnap,
            bottomSnapshot: bottomSnap,
            depth: depth + 1)
        deeper.modalPresentationStyle = .overFullScreen
        deeper.onDismiss = { [weak self] restored in
            guard let self else { return }
            self.outerScroll.contentOffset.y = regionStart + restored
            self.updateNestedViewport()
            self.updateTailViewport()
        }
        present(deeper, animated: false)
    }
}

extension SplitWebOverlayViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webSpinner.stopAnimating()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        webSpinner.stopAnimating()
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        webSpinner.stopAnimating()
    }
}

