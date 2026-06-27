//
//  RabbitHoleLayerViewController.swift
//  Clip
//
//  Forked, experimental "RabbitHole" reader — see RabbitHoleReaderViewController.
//  This is a hard fork of InlineReaderPageViewController's probe/embed logic, adapted
//  to live as one card in a persistent stacked layout (lips + indent + floating
//  header) instead of a page in a modal navigation stack. The original inline reader
//  is untouched.
//

import ClipModels
import UIKit
import WebKit

/// One layer (card) of the RabbitHole reader. Probes its URL off-main; renders the
/// page with the app reader when it's article-like (mode-switchable scroll / RSVP /
/// original-web), otherwise a themed web view. When the layer recedes to an ancestor,
/// opaque lips (title on top, the tapped line on the bottom) and a leading indent
/// cover its edges; the rest is occluded by the layer in front. Tapping a lip asks the
/// host to pop back to this layer.
final class RabbitHoleLayerViewController: UIViewController, WKNavigationDelegate {

    /// Identifies which page/scroll state this layer holds (kept in sync as the user
    /// reads / switches mode so the host can persist it).
    private(set) var descriptor: RabbitHoleLayerDescriptor

    /// A link was tapped inside this layer's reader → host pushes a new layer. Carries
    /// the URL plus the tapped line's text (for this layer's bottom lip) — nil text
    /// when descended from a non-scroll mode.
    var onLinkActivated: ((_ url: URL, _ lineText: String?) -> Void)?
    /// The user tapped this layer's lip → host pops back so this layer is focused.
    var onPopToHere: (() -> Void)?
    /// Fired once the page is confirmed article-like (host reveals the mode switcher).
    var onBecameArticle: (() -> Void)?
    /// Fired when the reader mode changes (host updates the descriptor).
    var onModeChanged: ((ReadingListItem.ReaderMode) -> Void)?
    /// The header back button (focused layer only): pop one layer, or exit the reader
    /// at the root. The host decides which.
    var onBack: (() -> Void)?

    private let shareProvider: ReaderShareProviding?
    private let gazeTrackerFactory: GazeTrackerFactory?
    private let layout: RabbitHoleLayout
    /// Height of the floating glass header (focused layer only).
    static let headerHeight: CGFloat = 64

    private let spinner = UIActivityIndicatorView(style: .medium)
    private var articleProbe: Task<Void, Never>?
    private var articleContent: ArticleContent?
    private enum ProbeDecision { case reader(ArticleContent); case web }
    private var pendingDecision: ProbeDecision?
    private var didDecide = false
    private(set) var readerMode: ReadingListItem.ReaderMode = .scroll
    private var audioOn = false
    private weak var readerChild: UIViewController?
    private var webView: WKWebView?

    // Chrome (focused header + ancestor lips).
    private let header = UIVisualEffectView(effect: GlassStyle.barEffect())
    private let backButton = UIButton(type: .system)
    private let modeControl = UISegmentedControl()
    private let audioButton = UIButton(type: .system)
    private let saveButton = UIButton(type: .system)
    private let topLip = UIButton(type: .system)
    private let bottomLip = UIButton(type: .system)
    private let topLipLabel = UILabel()
    private let bottomLipLabel = UILabel()
    private let indentView = UIView()

    private static let orderedModes: [ReadingListItem.ReaderMode] = [.scroll, .rsvp, .original]

    var isArticle: Bool { articleContent != nil }

    init(descriptor: RabbitHoleLayerDescriptor,
         preloadedContent: ArticleContent? = nil,
         shareProvider: ReaderShareProviding?,
         gazeTrackerFactory: GazeTrackerFactory?,
         layout: RabbitHoleLayout) {
        self.descriptor = descriptor
        self.shareProvider = shareProvider
        self.gazeTrackerFactory = gazeTrackerFactory
        self.layout = layout
        self.readerMode = descriptor.readerMode == .highlight ? .rsvp : descriptor.readerMode
        super.init(nibName: nil, bundle: nil)
        // The root layer already has its content (loaded from the store) — render it
        // directly. Deeper layers only have a URL, so they probe the network off-main.
        if let preloadedContent {
            pendingDecision = .reader(preloadedContent)
        } else {
            probeForArticle()
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    deinit { articleProbe?.cancel() }

    // MARK: - View

    override func viewDidLoad() {
        super.viewDidLoad()
        view.clipsToBounds = true
        view.layer.cornerRadius = layout.cornerRadius
        view.layer.cornerCurve = .continuous
        view.backgroundColor = ReaderDepth.backgroundColor(for: 0)   // host overrides per depth

        spinner.hidesWhenStopped = true
        spinner.startAnimating()
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        configureChrome()
        applyDecisionIfPossible()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutChrome()
        // Content host fills the card, inset below the floating header so text clears it.
        let top = Self.headerHeight
        readerChild?.view.frame = CGRect(x: 0, y: top,
                                         width: view.bounds.width,
                                         height: max(view.bounds.height - top, 0))
        webView?.frame = view.bounds
    }

    /// Set the card's background tint for its stack depth.
    func applyDepth(_ depth: Int) {
        view.backgroundColor = ReaderDepth.backgroundColor(for: depth)
    }

    // MARK: - Chrome (header + lips)

    private func configureChrome() {
        // Floating glass header (focused only): mode switcher + audio + save.
        header.clipsToBounds = true
        header.layer.cornerRadius = layout.cornerRadius
        header.layer.cornerCurve = .continuous
        header.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        view.addSubview(header)

        backButton.configuration = GlassStyle.circularButtonConfiguration(symbol: "chevron.backward", padding: 8)
        backButton.tintColor = GlassStyle.readingAccent
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        header.contentView.addSubview(backButton)

        for (index, mode) in Self.orderedModes.enumerated() {
            modeControl.insertSegment(with: ReaderModeIcons.image(for: mode), at: index, animated: false)
        }
        modeControl.selectedSegmentIndex = Self.orderedModes.firstIndex(of: readerMode) ?? 0
        modeControl.isHidden = true
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        header.contentView.addSubview(modeControl)

        audioButton.configuration = GlassStyle.circularButtonConfiguration(symbol: "speaker.slash", padding: 8)
        audioButton.tintColor = GlassStyle.readingAccent
        audioButton.addTarget(self, action: #selector(audioToggled), for: .touchUpInside)
        header.contentView.addSubview(audioButton)

        if shareProvider != nil {
            saveButton.configuration = Self.saveConfiguration(title: "Save")
            saveButton.tintColor = GlassStyle.readingAccent
            saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)
            header.contentView.addSubview(saveButton)
        }

        // Lips: opaque bars covering this card's top/bottom edges once it's an ancestor.
        for (lip, label, action) in [
            (topLip, topLipLabel, #selector(lipTapped)),
            (bottomLip, bottomLipLabel, #selector(lipTapped)),
        ] {
            lip.backgroundColor = .clear
            lip.addTarget(self, action: action, for: .touchUpInside)
            label.font = .systemFont(ofSize: 14, weight: .semibold)
            label.textColor = .label
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            lip.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerYAnchor.constraint(equalTo: lip.centerYAnchor),
                label.leadingAnchor.constraint(equalTo: lip.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: lip.trailingAnchor, constant: -16),
            ])
            view.addSubview(lip)
        }
        bottomLipLabel.font = .systemFont(ofSize: 14, weight: .regular)
        bottomLipLabel.textColor = .secondaryLabel

        indentView.isUserInteractionEnabled = false   // tapping the indent never pops
        indentView.backgroundColor = .clear
        view.addSubview(indentView)

        // Lips + indent become opaque (matching this card's colour) once the layer is an
        // ancestor, so they hide its occluded content. Because each ancestor card carries
        // its own depth tint, the strip the user sees to the leading side of the focused
        // layer shows the outer layer's colour — the indent the spec calls for.
        updateLipTitles()
        setChrome(role: .focused, alpha: 0)
    }

    private func layoutChrome() {
        let w = view.bounds.width
        let h = view.bounds.height
        let lip = layout.lipHeight
        let indent = layout.indentWidth

        header.frame = CGRect(x: 0, y: 0, width: w, height: Self.headerHeight)
        let s: CGFloat = 38
        let y = (Self.headerHeight - s) / 2
        backButton.frame = CGRect(x: 12, y: y, width: s, height: s)
        audioButton.frame = CGRect(x: backButton.frame.maxX + 8, y: y, width: s, height: s)
        var trailing = w - 12
        if saveButton.superview != nil {
            let fit = saveButton.sizeThatFits(CGSize(width: w, height: s))
            let sw = max(fit.width, s)
            saveButton.frame = CGRect(x: w - sw - 12, y: y, width: sw, height: s)
            trailing = saveButton.frame.minX - 8
        }
        let modeFit = modeControl.sizeThatFits(CGSize(width: w, height: 34))
        let reserve = max(audioButton.frame.maxX, w - trailing) + 8
        let modeW = min(modeFit.width, w - reserve * 2)
        modeControl.frame = CGRect(x: (w - modeW) / 2, y: (Self.headerHeight - 32) / 2,
                                   width: modeW, height: 32)

        // Lips span from the indent's trailing edge to the card's trailing edge, so a
        // lip tap and the indent exclusion zone never overlap.
        topLip.frame = CGRect(x: indent, y: 0, width: max(w - indent, 0), height: lip)
        bottomLip.frame = CGRect(x: indent, y: max(h - lip, 0), width: max(w - indent, 0), height: lip)
        indentView.frame = CGRect(x: 0, y: 0, width: indent, height: h)
    }

    /// Show/hide chrome for this layer's role. `alpha` is the layout's `chromeAlpha`
    /// (0 = focused header showing, 1 = full ancestor lips).
    func setChrome(role: RabbitHoleLayout.Role, alpha: CGFloat) {
        let lipAlpha = alpha
        topLip.alpha = lipAlpha
        bottomLip.alpha = lipAlpha
        indentView.alpha = lipAlpha
        // The lip + indent backgrounds become opaque (matching the card) so they hide
        // the occluded content beneath.
        let bg = view.backgroundColor ?? .clear
        topLip.backgroundColor = bg.withAlphaComponent(lipAlpha)
        bottomLip.backgroundColor = bg.withAlphaComponent(lipAlpha)
        indentView.backgroundColor = bg.withAlphaComponent(lipAlpha)
        header.alpha = 1 - lipAlpha
        // Only the focused layer's content + the floating header take touches; an
        // ancestor only listens on its lips.
        let focused = role == .focused
        readerChild?.view.isUserInteractionEnabled = focused
        webView?.isUserInteractionEnabled = focused
        header.isUserInteractionEnabled = focused
        topLip.isUserInteractionEnabled = !focused && role != .tucked
        bottomLip.isUserInteractionEnabled = !focused && role != .tucked
    }

    private func updateLipTitles() {
        let title = (descriptor.title?.isEmpty == false)
            ? descriptor.title : descriptor.url?.host
        topLipLabel.text = title ?? descriptor.urlString
        bottomLipLabel.text = descriptor.bottomLipText
    }

    /// Update the line shown in the bottom lip (the line tapped to descend from here).
    func setBottomLipText(_ text: String?) {
        descriptor.bottomLipText = text
        bottomLipLabel.text = text
    }

    private static func saveConfiguration(title: String) -> UIButton.Configuration {
        var config: UIButton.Configuration = {
            if #available(iOS 26.0, *) { return .glass() }
            return .tinted()
        }()
        config.title = title
        config.cornerStyle = .capsule
        config.baseForegroundColor = GlassStyle.readingAccent
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14)
        return config
    }

    @objc private func lipTapped() { onPopToHere?() }

    @objc private func backTapped() { onBack?() }

    @objc private func modeChanged() {
        let mode = Self.orderedModes[
            max(0, min(modeControl.selectedSegmentIndex, Self.orderedModes.count - 1))]
        setMode(mode)
    }

    @objc private func audioToggled() {
        audioOn.toggle()
        audioButton.configuration?.image = UIImage(
            systemName: audioOn ? "speaker.wave.2.fill" : "speaker.slash")
        guard isArticle else { return }
        embedReader(mode: readerMode, forceReembed: true)
    }

    @objc private func saveTapped() {
        guard let target = descriptor.url else { return }
        shareProvider?.saveLink(urlString: target.absoluteString)
        saveButton.configuration = Self.saveConfiguration(title: "Saved")
        saveButton.tintColor = GlassStyle.readingAccent
        saveButton.isEnabled = false
        view.setNeedsLayout()
    }

    // MARK: - Mode switching

    func setMode(_ mode: ReadingListItem.ReaderMode) {
        guard isArticle, mode != readerMode else { return }
        embedReader(mode: mode)
        descriptor.readerMode = mode
        if let index = Self.orderedModes.firstIndex(of: mode) {
            modeControl.selectedSegmentIndex = index
        }
        onModeChanged?(mode)
    }

    // MARK: - Article probe / embedding (forked from InlineReaderPageViewController)

    private func probeForArticle() {
        guard let target = descriptor.url else { pendingDecision = .web; return }
        articleProbe = Task { [weak self] in
            let content: ArticleContent? = await Task.detached(priority: .userInitiated) {
                if let cached = PreloadStore.shared.articleContent(for: target),
                   Self.isArticleLike(cached) {
                    return cached
                }
                guard let html = try? await ArticleFetcher().fetchHTML(from: target) else { return nil }
                return try? ArticleExtractor().extract(html: html, baseURL: target)
            }.value
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                if let content, Self.isArticleLike(content) {
                    self.pendingDecision = .reader(content)
                } else {
                    self.pendingDecision = .web
                }
                self.applyDecisionIfPossible()
            }
        }
    }

    private func applyDecisionIfPossible() {
        guard isViewLoaded, !didDecide, let decision = pendingDecision else { return }
        switch decision {
        case .reader(let content): showReader(content)
        case .web: showWebView()
        }
    }

    nonisolated private static func isArticleLike(_ content: ArticleContent) -> Bool {
        let blocks = content.blocks.filter { !$0.text.isEmpty }
        let totalText = blocks.reduce(0) { $0 + $1.text.count }
        return totalText >= 600 && blocks.count >= 3
    }

    private func showReader(_ content: ArticleContent) {
        guard isViewLoaded, !didDecide else { return }
        didDecide = true
        articleContent = content
        if descriptor.title?.isEmpty != false, !content.title.isEmpty {
            descriptor.title = content.title
            updateLipTitles()
        }
        spinner.stopAnimating()
        embedReader(mode: readerMode)
        onBecameArticle?()
    }

    private func showWebView() {
        guard isViewLoaded, !didDecide else { return }
        didDecide = true
        installWebView()
    }

    private func installWebView() {
        guard webView == nil, let url = descriptor.url else { return }
        let web = WKWebView(frame: view.bounds, configuration: WebJunkBlocker.makeConfiguration())
        webView = web
        let themed = view.backgroundColor ?? ReaderDepth.backgroundColor(for: 0)
        web.isOpaque = false
        web.backgroundColor = themed
        web.scrollView.backgroundColor = themed
        web.underPageBackgroundColor = themed
        web.scrollView.contentInset.top = Self.headerHeight
        web.scrollView.verticalScrollIndicatorInsets.top = Self.headerHeight
        view.insertSubview(web, belowSubview: header)
        WebJunkBlocker.applyRuleList(to: web.configuration.userContentController)
        web.navigationDelegate = self
        web.load(URLRequest(url: url))
        view.setNeedsLayout()
    }

    private func embedReader(mode: ReadingListItem.ReaderMode, forceReembed: Bool = false) {
        guard let content = articleContent, let url = descriptor.url else { return }
        if mode == .original {
            guard readerMode != .original || forceReembed else { return }
            removeReaderChild()
            spinner.stopAnimating()
            installWebView()
            readerMode = .original
            return
        }
        removeLiveWebView()
        removeReaderChild()
        var transient = ReadingListItem(urlString: url.absoluteString)
        transient.state = .ready
        transient.title = descriptor.title
        transient.lastScrollOffset = descriptor.scrollOffset

        let child: UIViewController
        switch mode {
        case .scroll, .highlight, .original:
            let scroll = ScrollReaderViewController(
                item: transient, content: content, audioEnabled: audioOn,
                gazeTrackerFactory: gazeTrackerFactory)
            scroll.onLinkActivated = { [weak self] url in
                guard let self else { return }
                self.onLinkActivated?(url, self.lineText(for: url))
            }
            child = scroll
        case .rsvp:
            let rsvp = RSVPViewController(item: transient, content: content, audioEnabled: audioOn)
            rsvp.onLinkActivated = { [weak self] url in self?.onLinkActivated?(url, nil) }
            child = rsvp
        }
        addChild(child)
        child.view.frame = CGRect(x: 0, y: Self.headerHeight, width: view.bounds.width,
                                  height: max(view.bounds.height - Self.headerHeight, 0))
        view.insertSubview(child.view, belowSubview: header)
        child.didMove(toParent: self)
        readerChild = child
        readerMode = mode
        view.setNeedsLayout()
    }

    private func removeReaderChild() {
        guard let old = readerChild else { return }
        old.willMove(toParent: nil)
        old.view.removeFromSuperview()
        old.removeFromParent()
        readerChild = nil
    }

    private func removeLiveWebView() {
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
    }

    // MARK: - Scroll access (no changes to ScrollReaderViewController)

    /// The layer's primary scroll view, found by walking the embedded reader's view
    /// tree (UITextView is a UIScrollView). Used for overscroll-pop + offset capture.
    var contentScrollView: UIScrollView? {
        if let web = webView { return web.scrollView }
        guard let root = readerChild?.view else { return nil }
        return Self.firstScrollView(in: root)
    }

    private static func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        for sub in view.subviews {
            if let found = firstScrollView(in: sub) { return found }
        }
        return nil
    }

    /// Current vertical scroll offset, snapshotted for persistence.
    var currentScrollOffset: Double {
        guard let scroll = contentScrollView else { return descriptor.scrollOffset }
        return Double(scroll.contentOffset.y)
    }

    /// Capture the current scroll offset into the descriptor (call before persisting).
    func syncScrollOffset() {
        descriptor.scrollOffset = currentScrollOffset
    }

    /// Best-effort text of the line containing the tapped link `url`, for the bottom
    /// lip. Found by locating the link's range in the embedded text view; nil unless
    /// we're in a text (scroll) reader.
    func lineText(for url: URL) -> String? {
        guard let textView = contentScrollView as? UITextView else { return nil }
        let attributed = textView.textStorage
        guard attributed.length > 0 else { return nil }
        var found: NSRange?
        attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length)) {
            value, range, stop in
            let matches: Bool
            if let u = value as? URL { matches = u == url }
            else if let s = value as? String { matches = s == url.absoluteString }
            else { matches = false }
            if matches { found = range; stop.pointee = true }
        }
        guard let linkRange = found else { return nil }
        // Expand to the paragraph/line and trim to a single sensible line.
        let line = (attributed.string as NSString).lineRange(for: linkRange)
        let text = (attributed.string as NSString).substring(with: line)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(140))
    }

    /// The tapped link's line rect, in this layer's coordinate space, for the morph.
    func lineRectInLayer(for url: URL) -> CGRect? {
        guard let textView = contentScrollView as? UITextView else { return nil }
        let attributed = textView.textStorage
        guard attributed.length > 0 else { return nil }
        var found: NSRange?
        attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length)) {
            value, range, stop in
            let matches = (value as? URL == url) || (value as? String == url.absoluteString)
            if matches { found = range; stop.pointee = true }
        }
        guard let linkRange = found else { return nil }
        let glyphRange = textView.layoutManager.glyphRange(forCharacterRange: linkRange, actualCharacterRange: nil)
        var rect = textView.layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
        rect.origin.y += textView.textContainerInset.top
        // text view → layer coordinates (textView is inset below the header).
        return textView.convert(rect, to: view)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if articleContent == nil { spinner.stopAnimating() }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        spinner.stopAnimating()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) { spinner.stopAnimating() }
}
