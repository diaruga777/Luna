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
    /// Link activation with its resolved point in this layer's coordinate space.
    /// Card hosts use the point as the origin of the full-screen eclipse.
    public var onLinkActivatedAtPoint:
        ((_ url: URL, _ lineText: String?, _ point: CGPoint) -> Void)?
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
    private let layout: RabbitHoleLayout
    /// Height of the floating header region (focused layer only): the content
    /// inset that keeps text clear of the free-floating header pills.
    public static let headerHeight: CGFloat = 52

    private let spinner = DotMatrixSpinnerView()
    /// Backstop so a page that never resolves (slow/hung fetch, web view that never
    /// fires didFinish) can't spin forever — see `armLoadWatchdog`.
    private var loadWatchdog: DispatchWorkItem?
    private var articleProbe: Task<Void, Never>?
    private var articleContent: ArticleContent?
    private enum ProbeDecision { case reader(ArticleContent); case web }
    private var pendingDecision: ProbeDecision?
    private var didDecide = false
    public private(set) var readerMode: ReadingListItem.ReaderMode = .scroll
    private var audioOn = false
    /// The `ReadingListItem.id` handed to the CURRENTLY embedded reader child —
    /// the identity the app-wide audio center plays under when this layer's
    /// audio toggle starts read-aloud. Captured per embed so toggling audio OFF
    /// can pause exactly that playback, and so the host can tell whether the
    /// playing article lives somewhere in this reader's trail.
    private(set) var embeddedReaderItemID: UUID?
    /// The item auto-marked `.read` when the embedded reader reached the end THIS
    /// session, plus its prior progress — so scrolling back before the end can revert
    /// the transient completion (mirrors `ReaderViewController`'s mark/unmark dance).
    private var autoMarkedRead: (id: UUID, priorProgress: Double?)?
    private weak var readerChild: UIViewController?
    private var currentRole: RabbitHoleLayout.Role = .focused
    private var webView: WKWebView?
    private let scrollReader: ScrollReaderViewController
    private let rsvpReader: RSVPViewController
    private let originalReader: OriginalPageViewController

    // Chrome (focused header + ancestor lips).
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

    // MARK: - External-chrome accessors (host-rendered header pills)

    /// The reading modes this layer offers (mirrors the in-card mode switcher).
    public var availableModes: [ReadingListItem.ReaderMode] { orderedModes }
    /// Whether this layer's embedded reader currently renders with read-aloud on.
    public var isAudioOn: Bool { audioOn }
    /// Whether this layer's page is already a saved reading-list item (drives
    /// Save-vs-Share in the trailing chrome slot).
    public var isSavedInLibrary: Bool { isAlreadySaved }
    /// Whether a share provider exists (without one the save/share slot is empty).
    public var offersSaveShare: Bool { shareProvider != nil }

    /// Toggle read-aloud, exactly as the in-card audio pill does.
    public func toggleAudio() { audioToggled() }

    /// Save this layer's page to the library, exactly as the in-card Save pill does.
    public func performSave() {
        guard let target = descriptor.url else { return }
        shareProvider?.saveLink(urlString: target.absoluteString)
        // Now saved → the slot becomes Share.
        updateSaveSlot()
    }

    /// Present the share sheet for this layer's page, anchored to `sourceView`
    /// (an external chrome pill, or the in-card share pill).
    public func performShare(from sourceView: UIView) {
        guard let target = descriptor.url else { return }
        shareProvider?.presentShareSheet(
            urlString: target.absoluteString, title: descriptor.title,
            from: self, sourceView: sourceView)
    }

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

    /// True once `configure(...)` has assigned this shell a real page to load. A freshly
    /// created shell stays blank until it receives its descriptor.
    private var isConfigured = false

    /// Render embedded scroll readers' WHOLE article up front instead of the
    /// Phase-1 prefix + deferred Phase-2 swap. Set by permanently-embedding hosts
    /// (carousel cards), where the swap would visibly relayout the card. Must be
    /// set before content is configured.
    public var rendersFullContentUpFront = false

    /// Whether this layer draws its own in-card header pills. Hosts that render
    /// the reader chrome OUTSIDE the card (the Reader carousel's screen-level
    /// pill row) set this false before the view loads; content then starts at
    /// the card's top instead of below the header region.
    public var showsHeaderChrome = true

    /// Top content reservation supplied by a host whose header floats outside
    /// this layer. It is applied as scroll content inset rather than a child
    /// frame offset so scrolled text can continue behind the host's blur.
    public var externalChromeContentInset: CGFloat = 0 {
        didSet { applyExternalChromeInset() }
    }

    /// The top inset that keeps content clear of the in-card header (0 when the
    /// chrome is rendered externally).
    private var contentTopInset: CGFloat { showsHeaderChrome ? Self.headerHeight : 0 }

    /// Creates a blank layer shell. Loading starts after `configure` assigns its page.
    public init(shareProvider: ReaderShareProviding?,
         layout: RabbitHoleLayout) {
        self.descriptor = RabbitHoleLayerDescriptor(urlString: "")
        self.shareProvider = shareProvider
        self.layout = layout
        let emptyItem = Self.emptyItem
        self.scrollReader = ScrollReaderViewController(
            item: emptyItem, content: Self.emptyContent, audioEnabled: false)
        self.rsvpReader = RSVPViewController(item: emptyItem, content: Self.emptyContent)
        self.originalReader = OriginalPageViewController()
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError("not used") }
    deinit { articleProbe?.cancel(); loadWatchdog?.cancel() }

    /// Assign this shell its page and start loading. The root already has content;
    /// deeper layers carry only a URL and probe off-main.
    public func configure(descriptor: RabbitHoleLayerDescriptor, knownContent: ArticleContent?) {
        self.descriptor = descriptor
        self.readerMode = descriptor.readerMode == .highlight ? .rsvp : descriptor.readerMode
        self.isConfigured = true
        if let knownContent {
            pendingDecision = .reader(knownContent)
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
        applyExternalChromeInset()
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
        let top = contentTopInset
        readerChild?.view.frame = CGRect(x: 0, y: top,
                                         width: view.bounds.width,
                                         height: max(view.bounds.height - top, 0))
        webView?.frame = view.bounds
    }

    private func applyExternalChromeInset() {
        let inset = showsHeaderChrome ? 0 : externalChromeContentInset
        scrollReader.topChromeInset = inset
        rsvpReader.topContentInset = inset
        webView?.scrollView.contentInset.top = inset
        webView?.scrollView.verticalScrollIndicatorInsets.top = inset
    }

    /// Set the card's background tint for its stack depth.
    public func applyDepth(_ depth: Int) {
        view.backgroundColor = ReaderDepth.backgroundColor(for: depth)
    }

    // MARK: - Chrome (header + lips)

    private func configureChrome() {
        // Floating header (focused only): each control is its own liquid-glass
        // pill (back / audio / mode switcher / save-or-share) resting directly
        // on the card — no full-width bar behind them.
        header.backgroundColor = .clear
        view.addSubview(header)

        backButton.configuration = GlassStyle.circularButtonConfiguration(symbol: "chevron.backward", padding: 8)
        backButton.tintColor = GlassStyle.readingAccent
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        header.addSubview(backButton)

        rebuildModeSegments()
        modeControl.isHidden = true
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        header.addSubview(modeControl)

        audioButton.configuration = GlassStyle.circularButtonConfiguration(symbol: "speaker.slash", padding: 8)
        audioButton.tintColor = GlassStyle.readingAccent
        audioButton.addTarget(self, action: #selector(audioToggled), for: .touchUpInside)
        header.addSubview(audioButton)

        if shareProvider != nil {
            saveButton.configuration = Self.capsuleConfiguration(title: "Save")
            saveButton.tintColor = GlassStyle.readingAccent
            saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)
            header.addSubview(saveButton)

            shareButton.configuration = GlassStyle.circularButtonConfiguration(
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
        header.isHidden = !showsHeaderChrome
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
        // The card is already inset from the screen edges, so the pills keep
        // only a small inset of their own.
        let edgeInset: CGFloat = 6
        var leadingX = edgeInset
        if !backButton.isHidden {
            backButton.frame = CGRect(x: leadingX, y: y, width: s, height: s)
            leadingX = backButton.frame.maxX + 8
        }
        audioButton.frame = CGRect(x: leadingX, y: y, width: s, height: s)
        var trailing = w - edgeInset
        // The trailing slot holds whichever of Save / Share is currently visible.
        if let slot = [saveButton, shareButton].first(where: { $0.superview != nil && !$0.isHidden }) {
            let fit = slot.sizeThatFits(CGSize(width: w, height: s))
            let sw = max(fit.width, s)
            slot.frame = CGRect(x: w - sw - edgeInset, y: y, width: sw, height: s)
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
        currentRole = role
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

    /// Hides the header's back pill. The host hides it on the root layer of a
    /// permanently-embedded reader (a carousel card), where there is nothing to
    /// pop to; deeper layers and pushed fullscreen readers keep it.
    public func setBackButtonHidden(_ hidden: Bool) {
        guard backButton.isHidden != hidden else { return }
        backButton.isHidden = hidden
        view.setNeedsLayout()
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
        // Toggling OFF while the app-wide center is voicing THIS layer's page
        // pauses it (the re-embed below renders silently); other articles'
        // playback is untouched. No-op on the legacy (extension-less) path.
        if !audioOn, let itemID = embeddedReaderItemID {
            ReaderAudioLauncher.pauseIfPlaying(itemID: itemID)
        }
        guard isArticle else { return }
        // The re-embed restores the reading position from the descriptor, which is only
        // written on dive/pop/background — capture the live position first or the
        // article jumps back to the last-persisted one.
        syncReadingPosition()
        embedReader(mode: readerMode, forceReembed: true)
    }

    @objc private func saveTapped() { performSave() }

    @objc private func shareTapped() { performShare(from: shareButton) }

    // MARK: - Mode switching

    public func setMode(_ mode: ReadingListItem.ReaderMode) {
        guard isArticle, mode != readerMode else { return }
        // Capture the OUTGOING mode's reading position into the descriptor now (the
        // crossfade embeds synchronously, before any persist runs) so the incoming
        // mode resumes from it.
        syncReadingPosition()
        if let index = orderedModes.firstIndex(of: mode) {
            modeControl.selectedSegmentIndex = index
        }
        embedReader(mode: mode)
        descriptor.readerMode = mode
        onModeChanged?(mode)
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
        removeReaderChild()
        let web = WKWebView(frame: view.bounds, configuration: WebJunkBlocker.makeConfiguration())
        webView = web
        let themed = view.backgroundColor ?? ReaderDepth.backgroundColor(for: 0)
        web.isOpaque = false
        web.backgroundColor = themed
        web.scrollView.backgroundColor = themed
        web.underPageBackgroundColor = themed
        let topInset = showsHeaderChrome ? contentTopInset : externalChromeContentInset
        web.scrollView.contentInset.top = topInset
        web.scrollView.verticalScrollIndicatorInsets.top = topInset
        view.insertSubview(web, belowSubview: header)
        HorizonScrollIndicator.install(on: web.scrollView, in: view)
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
            // Restore the archive's OWN disjoint offset — never the shared reading position.
            originalReader.configure(item: transient, savedScrollOffset: descriptor.originalScrollOffset)
            showChild(originalReader)
            readerMode = .original
            return
        }
        removeLiveWebView()
        let readerItem = readerItem(for: url)
        embeddedReaderItemID = readerItem.id

        if mode == .rsvp {
            rsvpReader.configureForReuse(item: readerItem, content: content, audioEnabled: audioOn)
            rsvpReader.onLinkActivatedAtPoint = { [weak self] url, point in
                guard let self else { return }
                self.onLinkActivatedAtPoint?(url, nil, self.view.convert(point, from: self.rsvpReader.view))
            }
            rsvpReader.onFinishedReading = { [weak self] in self?.markEmbeddedItemRead() }
            rsvpReader.onMovedAwayFromEnd = { [weak self] in self?.unmarkEmbeddedItemReadIfAutoMarked() }
            showChild(rsvpReader)
        } else {
            scrollReader.configureForReuse(
                item: readerItem, content: content, audioEnabled: audioOn,
                fullRenderUpFront: rendersFullContentUpFront)
            scrollReader.onLinkActivatedWithRange = { [weak self] url, range in
                guard let self else { return }
                let lineText = self.lineText(for: range)
                let point = self.scrollReader.linkActivationPoint(forCharacterRange: range)
                self.onLinkActivatedAtPoint?(
                    url, lineText, self.view.convert(point, from: self.scrollReader.view))
            }
            scrollReader.onFinishedReading = { [weak self] in self?.markEmbeddedItemRead() }
            scrollReader.onMovedAwayFromEnd = { [weak self] in self?.unmarkEmbeddedItemReadIfAutoMarked() }
            showChild(scrollReader)
        }
        readerMode = mode
        view.setNeedsLayout()
    }

    /// The `ReadingListItem` handed to the embedded scroll/RSVP reader. When this
    /// layer's page IS a saved reading-list item (always true for the root layer,
    /// and for any dived-into link the user happens to have saved), the REAL store
    /// item is used so read-aloud plays under its durable identity — mark-read,
    /// the autoplay queue's exclusion, spoken-position resume, and the
    /// mini-player's thumbnail/navigation all key off `item.id`. Unsaved pages
    /// get a transient whose id is DETERMINISTICALLY seeded from the URL, so the
    /// identity stays stable across re-embeds (mode/audio toggles) within the
    /// layer instead of regenerating per embed. Either way the per-session
    /// scroll offset comes from the descriptor.
    private func readerItem(for url: URL) -> ReadingListItem {
        var item = ReadingListStore.shared.item(forURLString: url.absoluteString)
            ?? ReadingListItem(
                urlString: url.absoluteString,
                id: ReadingListItem.deterministicUUID(from: "rabbithole:\(url.absoluteString)"))
        item.state = .ready
        item.title = descriptor.title ?? item.title
        // Feed the shared scroll/RSVP reading position from the descriptor: the word
        // anchor plus, when the scroll reader still owns it, the exact pixels. The
        // archive's own offset (`descriptor.originalScrollOffset`) is kept disjoint and
        // routed straight to the original reader in `embedReader`, never here.
        item.lastWordIndex = descriptor.wordIndex
        item.lastScrollOffset = descriptor.scrollOffset
        return item
    }

    /// The embedded reader reached the end → mark its item finished (read + archived).
    /// For the root layer this is the real saved item; for a dived-into saved link it's
    /// that item; for an unsaved transient page `markFinishedReading` is a no-op (the id
    /// isn't in the store). Remembers a from-unread auto-mark so it can be reverted.
    private func markEmbeddedItemRead() {
        guard let id = embeddedReaderItemID else { return }
        if ReadingListStore.shared.item(withID: id)?.readState != .read {
            autoMarkedRead = (id, ReadingListStore.shared.item(withID: id)?.readingProgress)
        }
        ReadingListStore.shared.markFinishedReading(id)
    }

    /// The reader moved back before the end → undo a completion we auto-applied this
    /// session (so an article the user is still reading isn't left archived after a
    /// glance at the bottom). Only reverts our own from-unread mark on the same item.
    private func unmarkEmbeddedItemReadIfAutoMarked() {
        guard let auto = autoMarkedRead, auto.id == embeddedReaderItemID else { return }
        autoMarkedRead = nil
        ReadingListStore.shared.restoreFinishedReadingState(
            readState: .opened, readingProgress: auto.priorProgress, for: auto.id)
    }

    private func showChild(_ child: UIViewController) {
        if readerChild !== child {
            removeReaderChild()
            addChild(child)
        }
        child.view.frame = CGRect(x: 0, y: contentTopInset, width: view.bounds.width,
                                  height: max(view.bounds.height - contentTopInset, 0))
        view.insertSubview(child.view, belowSubview: header)
        if child.parent === self, child !== readerChild {
            child.didMove(toParent: self)
        }
        readerChild = child
        child.view.isUserInteractionEnabled = (currentRole == .focused)
        (child as? ScrollReaderViewController)?
            .activateVisibleReader(deferFullContentUntilHostCompletion: false)
    }

    private func removeReaderChild() {
        guard let child = readerChild else { return }
        child.willMove(toParent: nil)
        child.view.removeFromSuperview()
        child.removeFromParent()
        readerChild = nil
    }

    private func removeLiveWebView() {
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
    }

    // MARK: - Scroll access

    /// The layer's primary scroll view, found by walking the embedded reader's view
    /// tree (UITextView is a UIScrollView). Used for overscroll-pop + offset capture.
    public var contentScrollView: UIScrollView? {
        if let web = webView { return web.scrollView }
        guard let root = readerChild?.view else { return nil }
        return Self.firstScrollView(in: root)
    }

    public var isRSVPPlaying: Bool? {
        readerMode == .rsvp ? rsvpReader.isPlaying : nil
    }

    private static func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        for sub in view.subviews {
            if let found = firstScrollView(in: sub) { return found }
        }
        return nil
    }

    /// Capture the active mode's reading position into the descriptor (call before a
    /// mode switch or persist). Each mode writes ONLY its own state so the archive can
    /// never clobber the shared scroll/RSVP position:
    ///  • scroll → the shared word + its exact pixels;
    ///  • RSVP → the shared word, and it clears the exact pixels (no pixels exist);
    ///  • original → its own disjoint offset, leaving the shared position untouched.
    public func syncReadingPosition() {
        guard isArticle else { return }
        if readerMode == .rsvp {
            descriptor.wordIndex = rsvpReader.currentReadingWordIndex
            descriptor.scrollOffset = nil
        } else if readerMode == .original {
            descriptor.originalScrollOffset = originalReader.currentScrollOffset
        } else {
            descriptor.wordIndex = scrollReader.currentReadingWordIndex
            descriptor.scrollOffset = Double(scrollReader.currentReadingScrollOffsetY)
        }
    }

    /// Best-effort text of the line containing the tapped link range, for the bottom
    /// lip. The range comes directly from UIKit's link tap resolution, so this avoids
    /// scanning every link in the attributed string during the tap.
    private func lineText(for linkRange: NSRange) -> String? {
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
                 withError error: Error) {
        finishLoading()
        // The navigation never committed, so the card is a permanently blank
        // themed rectangle — surface the error state (the watchdog can't: it
        // only fires while webView is nil). NSURLErrorCancelled is a redirect
        // or an intentional stop, not a dead load.
        if articleContent == nil, (error as NSError).code != NSURLErrorCancelled {
            showLoadError()
        }
    }
}
