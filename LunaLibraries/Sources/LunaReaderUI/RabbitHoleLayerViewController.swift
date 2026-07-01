//
//  RabbitHoleLayerViewController.swift
//  Luna
//
//  Forked, experimental "RabbitHole" reader — see RabbitHoleReaderViewController.
//  This is a hard fork of InlineReaderPageViewController's probe/embed logic, adapted
//  to live as one card in a persistent stacked layout (lips + indent + floating
//  header) instead of a page in a modal navigation stack. The original inline reader
//  is untouched.
//

import LunaDesignSystem
import LunaArchiveReader
import LunaStorage
import LunaFetch
import LunaHTMLClassification
import LunaModels
import LunaTransitions
import UIKit
import WebKit

/// One layer (card) of the RabbitHole reader. Probes its URL off-main; renders the
/// page with the app reader when it's article-like (mode-switchable scroll / RSVP /
/// original-web), otherwise a themed web view. When the layer recedes to an ancestor,
/// opaque lips (title on top, the tapped line on the bottom) and a leading indent
/// cover its edges; the rest is occluded by the layer in front. Tapping a lip asks the
/// host to pop back to this layer.
public final class RabbitHoleLayerViewController: UIViewController, WKNavigationDelegate {

    /// Identifies which page/scroll state this layer holds (kept in sync as the user
    /// reads / switches mode so the host can persist it).
    private(set) var descriptor: RabbitHoleLayerDescriptor

    /// A link was tapped inside this layer's reader → host pushes a new layer. Carries
    /// the URL plus the tapped line's text (for this layer's bottom lip) — nil text
    /// when descended from a non-scroll mode.
    public var onLinkActivated: ((_ url: URL, _ lineText: String?) -> Void)?
    /// The user tapped this layer's lip → host pops back so this layer is focused.
    public var onPopToHere: (() -> Void)?
    /// Fired once the page is confirmed article-like (host reveals the mode switcher).
    public var onBecameArticle: (() -> Void)?
    /// Fired when the reader mode changes (host updates the descriptor).
    public var onModeChanged: ((ReadingListItem.ReaderMode) -> Void)?
    /// The header back button (focused layer only): pop one layer, or exit the reader
    /// at the root. The host decides which.
    public var onBack: (() -> Void)?

    private let shareProvider: ReaderShareProviding?
    private let gazeTrackerFactory: GazeTrackerFactory?
    private let layout: RabbitHoleLayout
    /// Height of the floating header (focused layer only).
    public static let headerHeight: CGFloat = 64

    private let spinner = DotMatrixSpinnerView()
    /// Backstop so a page that never resolves (slow/hung fetch, web view that never
    /// fires didFinish) can't spin forever — see `armLoadWatchdog`.
    private var loadWatchdog: DispatchWorkItem?
    private var articleProbe: Task<Void, Never>?
    private var articleContent: ArticleContent?
    private enum ProbeDecision { case reader(ArticleContent); case web }
    private var pendingDecision: ProbeDecision?
    private var didDecide = false
    private(set) var readerMode: ReadingListItem.ReaderMode = .scroll
    private var audioOn = false
    private weak var readerChild: UIViewController?
    private var webView: WKWebView?
    private let scrollReader: ScrollReaderViewController
    private let rsvpReader: RSVPViewController
    private let originalReader: OriginalPageViewController

    // Chrome (focused header + ancestor lips).
    // De-glassed (Task 3): a solid header fill over the layer card's solid background,
    // so the Dot Matrix pixel-wipe captures it faithfully (a live blur could not be).
    private let header = UIView()
    private let backButton = UIButton(type: .system)
    private let modeControl = LunaSegmentedControl()
    private let audioButton = UIButton(type: .system)
    /// Trailing header slot: "Save" while the article isn't in the library, "Share"
    /// once it is (always Share on the root, which is already a saved item).
    private let saveButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)
    private let topLip = UIButton(type: .system)
    private let bottomLip = UIButton(type: .system)
    private let topLipLabel = UILabel()
    private let bottomLipLabel = UILabel()
    private let indentView = UIView()

    /// Reading modes offered for this layer. `.original` (loading the live web page)
    /// is only shown when this layer actually points at a web page — saves with no real
    /// http(s) URL (e.g. mail imports) have nothing to load, so they never get it. This
    /// matches `ReadingListItem.canHaveOriginalArchive` for this reader's web-only domain
    /// (every layer is a dived-into http(s) link), sharing the same web-page URL test.
    private var orderedModes: [ReadingListItem.ReaderMode] {
        var modes: [ReadingListItem.ReaderMode] = [.scroll, .rsvp]
        if ReadingListItem.isWebPageURL(descriptor.urlString) {
            modes.append(.original)
        }
        return modes
    }

    /// Rebuild the mode switcher's segments from `orderedModes` and reselect the
    /// current mode. Needed because the chrome is first built against the blank shell's
    /// placeholder urlString (no `.original`); once `configure(...)` installs the real
    /// URL this re-derives the set so web-URL saves regain the Original segment. Layout
    /// (segment widths) is refreshed by the caller's `updateLipTitles`/layout pass.
    private func rebuildModeSegments() {
        let modes = orderedModes
        modeControl.removeAllSegments()
        for (index, mode) in modes.enumerated() {
            modeControl.insertSegment(with: ReaderModeIcons.image(for: mode), at: index, animated: false)
        }
        modeControl.selectedSegmentIndex = modes.firstIndex(of: readerMode) ?? 0
        view.setNeedsLayout()
    }

    public var isArticle: Bool { articleContent != nil }

    private static let emptyContent = ArticleContent(title: "", blocks: [])
    private static var emptyItem: ReadingListItem {
        var item = ReadingListItem(urlString: "about:blank")
        item.state = .ready
        return item
    }

    #if DEBUG
    /// Test hook: the number of segments actually present in the header mode switcher.
    /// This reads the live mode control (not the `orderedModes` it's built from),
    /// so it catches the regression where `configure(...)` set a new URL but left the
    /// segment set built off the blank shell's placeholder ("", no `.original`).
    public var modeSegmentCountForTesting: Int {
        loadViewIfNeeded()
        return modeControl.numberOfSegments
    }
    #endif

    /// De-duplicated http(s) links this layer's article points at, in document order.
    /// The host preloads these so a dive into one is instant.
    public var outboundLinkURLs: [URL] { articleContent?.outboundURLs ?? [] }
    /// True once `configure(...)` has assigned this shell a real page to load. A freshly
    /// created shell stays blank (chrome built, nothing loading) so the host can
    /// pre-create the next layer offscreen and a dive only sets content + frame.
    private var isConfigured = false

    /// Creates a BLANK layer shell: its view loads and all chrome (the header,
    /// buttons, lips, indent) is built immediately, but nothing is fetched or rendered
    /// until `configure(descriptor:preloadedContent:)`. The host pre-creates one of
    /// these offscreen so tapping a link never has to build a view controller.
    public init(shareProvider: ReaderShareProviding?,
         gazeTrackerFactory: GazeTrackerFactory?,
         layout: RabbitHoleLayout) {
        self.descriptor = RabbitHoleLayerDescriptor(urlString: "")
        self.shareProvider = shareProvider
        self.gazeTrackerFactory = gazeTrackerFactory
        self.layout = layout
        let emptyItem = Self.emptyItem
        self.scrollReader = ScrollReaderViewController(
            item: emptyItem, content: Self.emptyContent, audioEnabled: false,
            gazeTrackerFactory: nil)
        self.rsvpReader = RSVPViewController(item: emptyItem, content: Self.emptyContent)
        self.originalReader = OriginalPageViewController()
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError("not used") }
    deinit { articleProbe?.cancel(); loadWatchdog?.cancel() }

    /// Assign this shell its page and start loading. Called once on a blank shell — on
    /// the root/restored layers at build time, and on the pre-created spare when the user
    /// dives into a link. The root already has its content (render directly); deeper
    /// layers carry only a URL, so they probe off-main.
    public func configure(descriptor: RabbitHoleLayerDescriptor, preloadedContent: ArticleContent?) {
        self.descriptor = descriptor
        self.readerMode = descriptor.readerMode == .highlight ? .rsvp : descriptor.readerMode
        self.isConfigured = true
        if let preloadedContent {
            pendingDecision = .reader(preloadedContent)
        } else {
            probeForArticle()
        }
        guard isViewLoaded else { return }   // viewDidLoad will start loading
        // The chrome was built against the blank shell's placeholder urlString (""),
        // so its segment set excluded `.original`. Now that the real URL is in place,
        // rebuild the segments from `orderedModes` so a web-URL save regains Original.
        rebuildModeSegments()
        updateLipTitles()
        updateSaveSlot()
        beginLoading()
    }

    // MARK: - View

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.clipsToBounds = true
        view.layer.cornerRadius = layout.cornerRadius
        view.layer.cornerCurve = .continuous
        view.backgroundColor = ReaderDepth.backgroundColor(for: 0)   // host overrides per depth

        spinner.hidesWhenStopped = true
        view.addSubview(spinner)   // centred manually in viewDidLayoutSubviews

        configureChrome()
        installPreloadedModeChildren()
        if isConfigured { beginLoading() }
    }

    /// Begin (or resume) loading once both the view and a `configure(...)` are in place.
    private func beginLoading() {
        if case .reader = pendingDecision {
            spinner.stopAnimating()
        } else {
            spinner.startAnimating()
        }
        applyDecisionIfPossible()
        armLoadWatchdog()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Backstop: if a probe decision landed before the view existed, apply it now
        // (idempotent — guarded by didDecide).
        applyDecisionIfPossible()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutChrome()
        // Spinner + any error label sit centred in the card (manual frames, no autolayout).
        spinner.sizeToFit()
        spinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        if let errorLabel = view.viewWithTag(Self.errorLabelTag) {
            let fit = errorLabel.sizeThatFits(view.bounds.size)
            errorLabel.frame = CGRect(
                x: (view.bounds.width - fit.width) / 2, y: (view.bounds.height - fit.height) / 2,
                width: fit.width, height: fit.height)
        }
        // Content host fills the card, inset below the floating header so text clears it.
        let top = Self.headerHeight
        readerChild?.view.frame = CGRect(x: 0, y: top,
                                         width: view.bounds.width,
                                         height: max(view.bounds.height - top, 0))
        for child in [scrollReader, rsvpReader, originalReader] {
            child.view.frame = CGRect(x: 0, y: top,
                                      width: view.bounds.width,
                                      height: max(view.bounds.height - top, 0))
        }
        webView?.frame = view.bounds
    }

    /// Install all article mode children while the layer shell is still blank. This
    /// pays the child containment, view creation, TextKit/WebKit setup, constraints,
    /// controls, and first layout before any link tap needs the layer.
    private func installPreloadedModeChildren() {
        for child in [scrollReader, rsvpReader, originalReader] {
            addChild(child)
            child.view.isHidden = true
            child.view.isUserInteractionEnabled = false
            view.insertSubview(child.view, belowSubview: header)
            child.didMove(toParent: self)
        }
    }

    /// Set the card's background tint for its stack depth.
    public func applyDepth(_ depth: Int) {
        view.backgroundColor = ReaderDepth.backgroundColor(for: depth)
    }

    // MARK: - Chrome (header + lips)

    private func configureChrome() {
        // Floating (de-glassed) header (focused only): mode switcher + audio + save.
        header.backgroundColor = GlassStyle.solidBarColor
        header.clipsToBounds = true
        header.layer.cornerRadius = layout.cornerRadius
        header.layer.cornerCurve = .continuous
        header.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        view.addSubview(header)

        backButton.configuration = GlassStyle.solidCircularButtonConfiguration(symbol: "chevron.backward", padding: 8)
        backButton.tintColor = GlassStyle.readingAccent
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        header.addSubview(backButton)

        rebuildModeSegments()
        modeControl.isHidden = true
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        header.addSubview(modeControl)

        audioButton.configuration = GlassStyle.solidCircularButtonConfiguration(symbol: "speaker.slash", padding: 8)
        audioButton.tintColor = GlassStyle.readingAccent
        audioButton.addTarget(self, action: #selector(audioToggled), for: .touchUpInside)
        header.addSubview(audioButton)

        if shareProvider != nil {
            saveButton.configuration = Self.capsuleConfiguration(title: "Save")
            saveButton.tintColor = GlassStyle.readingAccent
            saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)
            header.addSubview(saveButton)

            shareButton.configuration = GlassStyle.solidCircularButtonConfiguration(
                symbol: "square.and.arrow.up", padding: 8)
            shareButton.tintColor = GlassStyle.readingAccent
            shareButton.addTarget(self, action: #selector(shareTapped), for: .touchUpInside)
            header.addSubview(shareButton)
            updateSaveSlot()
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
            lip.addSubview(label)   // framed manually in layoutChrome
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
        // The trailing slot holds whichever of Save / Share is currently visible.
        if let slot = [saveButton, shareButton].first(where: { $0.superview != nil && !$0.isHidden }) {
            let fit = slot.sizeThatFits(CGSize(width: w, height: s))
            let sw = max(fit.width, s)
            slot.frame = CGRect(x: w - sw - 12, y: y, width: sw, height: s)
            trailing = slot.frame.minX - 8
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

        // Lip labels: inset 4pt leading / 16pt trailing within their lip, full height
        // (the label centres its single line of text vertically). Manual frames — no
        // autolayout in this experimental viewer.
        let labelWidth = max(topLip.bounds.width - 20, 0)
        topLipLabel.frame = CGRect(x: 4, y: 0, width: labelWidth, height: topLip.bounds.height)
        bottomLipLabel.frame = CGRect(x: 4, y: 0, width: labelWidth, height: bottomLip.bounds.height)
    }

    /// Show/hide chrome for this layer's role. `alpha` is the layout's `chromeAlpha`
    /// (0 = focused header showing, 1 = full ancestor lips).
    public func setChrome(role: RabbitHoleLayout.Role, alpha: CGFloat) {
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
    public func setBottomLipText(_ text: String?) {
        descriptor.bottomLipText = text
        bottomLipLabel.text = text
    }

    /// Whether this layer's URL is already in the reading list (always true for the
    /// root, which IS a saved item). Drives Save-vs-Share in the trailing header slot.
    private var isAlreadySaved: Bool {
        guard let urlString = descriptor.url?.absoluteString else { return false }
        return ReadingListStore.shared.item(forURLString: urlString) != nil
    }

    /// Show Share when the article is already saved, Save when it isn't. No-op when
    /// there's no share provider (the slot stays empty).
    private func updateSaveSlot() {
        guard shareProvider != nil else { return }
        let saved = isAlreadySaved
        saveButton.isHidden = saved
        shareButton.isHidden = !saved
        view.setNeedsLayout()
    }

    private static func capsuleConfiguration(title: String) -> UIButton.Configuration {
        var config = UIButton.Configuration.filled()
        config.baseBackgroundColor = GlassStyle.readingAccent.withAlphaComponent(0.16)
        config.title = title
        config.cornerStyle = .capsule
        config.baseForegroundColor = GlassStyle.readingAccent
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14)
        return config
    }

    @objc private func lipTapped() { onPopToHere?() }

    @objc private func backTapped() { onBack?() }

    @objc private func modeChanged() {
        let mode = orderedModes[
            max(0, min(modeControl.selectedSegmentIndex, orderedModes.count - 1))]
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
        // Now saved → the slot becomes Share.
        updateSaveSlot()
    }

    @objc private func shareTapped() {
        guard let target = descriptor.url else { return }
        shareProvider?.presentShareSheet(
            urlString: target.absoluteString, title: descriptor.title,
            from: self, sourceView: shareButton)
    }

    // MARK: - Mode switching

    public func setMode(_ mode: ReadingListItem.ReaderMode) {
        guard isArticle, mode != readerMode else { return }
        // Keep the control's live selection on the new mode (it's already there when this
        // came from `modeChanged`; a no-op then, but needed for programmatic mode changes).
        // The control's OWN selection move uses UIKit's stock selection animation — no
        // dotmatrix pixel-wipe on the control widget itself; only the content below it wipes.
        if let index = orderedModes.firstIndex(of: mode) {
            modeControl.selectedSegmentIndex = index
        }
        // Dissolve ONLY the content region (below the floating header) dot-by-dot from
        // the old mode to the new one. The wipe is confined to the reader-child content rect
        // via `region:`, so the header sitting at y:0..headerHeight never pixelates.
        // (Falls back to a plain crossfade when the pixel-wipe is off / unavailable.)
        let contentRegion = Self.contentWipeRegion(in: view.bounds)
        DotMatrixCrossfade.run(in: view, direction: .random, region: contentRegion) { [weak self] in
            self?.embedReader(mode: mode)
        }
        descriptor.readerMode = mode
        onModeChanged?(mode)
    }

    /// The sub-rect of the card the mode-switch wipe is confined to: everything BELOW the
    /// floating header (which sits at `y: 0 ..< headerHeight`). Pure + testable so the
    /// "header never pixelates" contract is pinned — the returned rect must never overlap the
    /// header band. Mirrors the reader-child content frame in `viewDidLayoutSubviews`.
    public static func contentWipeRegion(in bounds: CGRect) -> CGRect {
        let top = headerHeight
        return CGRect(x: 0, y: top,
                      width: bounds.width,
                      height: max(bounds.height - top, 0))
    }

    // MARK: - Article probe / embedding (forked from InlineReaderPageViewController)

    private func probeForArticle() {
        guard let target = descriptor.url else { pendingDecision = .web; return }
        articleProbe = Task { [weak self] in
            let content: ArticleContent? = await Task.detached(priority: .userInitiated) {
                if let cached = PreloadStore.shared.articleContent(for: target),
                   cached.isArticleLike {
                    return cached
                }
                guard let html = try? await ArticleFetcher().fetchHTML(from: target) else { return nil }
                return try? ArticleExtractor().extract(html: html, baseURL: target)
            }.value
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                if let content, content.isArticleLike {
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

    /// Stop the loading spinner and cancel the watchdog (any terminal load outcome).
    private func finishLoading() {
        spinner.stopAnimating()
        loadWatchdog?.cancel()
        loadWatchdog = nil
    }

    /// A page that never resolves (hung fetch, or a web view that never fires
    /// didFinish) would otherwise spin forever. After a grace period, force a terminal
    /// state: take the web fallback if no decision arrived, then stop spinning.
    private func armLoadWatchdog() {
        guard spinner.isAnimating else { return }   // already resolved (e.g. preloaded root)
        let work = DispatchWorkItem { [weak self] in self?.loadWatchdogFired() }
        loadWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    private func loadWatchdogFired() {
        guard isViewLoaded, spinner.isAnimating else { return }
        if !didDecide {
            pendingDecision = .web
            applyDecisionIfPossible()   // → showWebView (or error for a nil URL)
        }
        // Whatever loaded, stop spinning; a slow web view stays visible underneath.
        spinner.stopAnimating()
        if webView == nil, articleContent == nil { showLoadError() }
    }

    /// Tag identifying the "couldn't load" label (manually centred in viewDidLayoutSubviews).
    private static let errorLabelTag = 0x4C4F4144   // "LOAD"

    /// Themed "couldn't load" state for a nil/invalid URL or a dead load.
    private func showLoadError() {
        finishLoading()
        guard view.viewWithTag(Self.errorLabelTag) == nil else { return }
        let label = UILabel()
        label.tag = Self.errorLabelTag
        label.text = "Couldn’t load this page."
        label.textColor = .secondaryLabel
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textAlignment = .center
        view.addSubview(label)   // centred manually in viewDidLayoutSubviews
        view.setNeedsLayout()
    }

    private func showReader(_ content: ArticleContent) {
        guard isViewLoaded, !didDecide else { return }
        didDecide = true
        articleContent = content
        if descriptor.title?.isEmpty != false, !content.title.isEmpty {
            descriptor.title = content.title
            updateLipTitles()
        }
        finishLoading()
        // The mode switcher applies only to article-rendered pages — reveal it now, at
        // every nesting level (not just the root).
        modeControl.isHidden = false
        updateSaveSlot()
        embedReader(mode: readerMode)
        onBecameArticle?()
    }

    private func showWebView() {
        guard isViewLoaded, !didDecide else { return }
        didDecide = true
        installWebView()
    }

    private func installWebView() {
        guard webView == nil else { return }
        guard let url = descriptor.url else { showLoadError(); return }
        for child in [scrollReader, rsvpReader, originalReader] {
            child.view.isHidden = true
        }
        readerChild = nil
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
            spinner.stopAnimating()
            removeLiveWebView()
            var transient = ReadingListItem(urlString: url.absoluteString)
            transient.state = .ready
            transient.title = descriptor.title
            originalReader.configure(item: transient)
            showPreloadedChild(originalReader)
            readerMode = .original
            return
        }
        removeLiveWebView()
        var transient = ReadingListItem(urlString: url.absoluteString)
        transient.state = .ready
        transient.title = descriptor.title
        transient.lastScrollOffset = descriptor.scrollOffset

        switch mode {
        case .scroll, .highlight, .original:
            // Deliberately NO gaze tracker here: EyeGazeWordTracker.init starts an
            // ARFaceTracking camera session synchronously, and a dive builds a fresh
            // ScrollReader every time — so per-layer trackers stalled the main thread
            // (the on-device dive hang) and stacked a camera session per layer. Eye
            // tracking stays available in the standard reader; it's off in this
            // experimental stacked reader by design.
            scrollReader.configureForReuse(
                item: transient, content: content, audioEnabled: audioOn)
            scrollReader.onLinkActivatedWithRange = { [weak self] url, range in
                guard let self else { return }
                self.onLinkActivated?(url, self.lineText(for: range))
            }
            showPreloadedChild(scrollReader)
        case .rsvp:
            rsvpReader.configureForReuse(item: transient, content: content, audioEnabled: audioOn)
            rsvpReader.onLinkActivated = { [weak self] url in self?.onLinkActivated?(url, nil) }
            showPreloadedChild(rsvpReader)
        }
        readerMode = mode
        view.setNeedsLayout()
    }

    private func showPreloadedChild(_ child: UIViewController) {
        for candidate in [scrollReader, rsvpReader, originalReader] {
            candidate.view.isHidden = candidate !== child
        }
        child.view.frame = CGRect(x: 0, y: Self.headerHeight, width: view.bounds.width,
                                  height: max(view.bounds.height - Self.headerHeight, 0))
        view.insertSubview(child.view, belowSubview: header)
        readerChild = child
        (child as? ScrollReaderViewController)?
            .activateVisibleReader(deferFullContentUntilHostCompletion: true)
    }

    private func removeLiveWebView() {
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
    }

    /// The stacked-layer wipe that revealed this layer has finished — tell the embedded
    /// scroll reader to run its progressive-load Phase 2 (full render + swap) now, so
    /// the heavy glyph pass lands after the wipe instead of stalling it. No-op unless
    /// the focused content is the scroll reader (idempotent there).
    public func entryAnimationDidFinish() {
        (readerChild as? ScrollReaderViewController)?.prepareFullContent()
    }

    // MARK: - Scroll access (no changes to ScrollReaderViewController)

    /// The layer's primary scroll view, found by walking the embedded reader's view
    /// tree (UITextView is a UIScrollView). Used for overscroll-pop + offset capture.
    public var contentScrollView: UIScrollView? {
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
    public var currentScrollOffset: Double {
        guard let scroll = contentScrollView else { return descriptor.scrollOffset }
        return Double(scroll.contentOffset.y)
    }

    /// Capture the current scroll offset into the descriptor (call before persisting).
    public func syncScrollOffset() {
        descriptor.scrollOffset = currentScrollOffset
    }

    /// Best-effort text of the line containing the tapped link range, for the bottom
    /// lip. The range comes directly from UIKit's link tap resolution, so this avoids
    /// scanning every link in the attributed string during the tap.
    public func lineText(for linkRange: NSRange) -> String? {
        guard let textView = contentScrollView as? UITextView else { return nil }
        let attributed = textView.textStorage
        guard attributed.length > 0 else { return nil }
        let bounded = NSIntersectionRange(linkRange, NSRange(location: 0, length: attributed.length))
        guard bounded.length > 0 else { return nil }
        // Expand to the paragraph/line and trim to a single sensible line.
        let line = (attributed.string as NSString).lineRange(for: bounded)
        let text = (attributed.string as NSString).substring(with: line)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(140))
    }

    // MARK: - WKNavigationDelegate

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if articleContent == nil { finishLoading() }
    }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoading()
    }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) { finishLoading() }
}
