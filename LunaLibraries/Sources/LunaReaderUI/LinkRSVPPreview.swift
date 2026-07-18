//
//  LinkRSVPPreview.swift
//  LunaReaderUI
//
//  A touch-tracking, miniature RSVP reader for links held in either reader.
//

import LunaDesignSystem
import LunaAudioPlayback
import LunaFetch
import LunaHTMLClassification
import LunaModels
import LunaReaderEngine
import LunaStorage
import UIKit

/// Pure gesture policy shared by the UIKit interaction and its unit tests.
public enum LinkRSVPPreviewGesturePolicy {
    public enum VerticalMode: Equatable {
        case playback
        case menu
        case lock
    }

    public static let horizontalDeadZone: CGFloat = 24
    public static let horizontalPauseThreshold: CGFloat = -174
    public static let verticalThreshold: CGFloat = 56
    public static let verticalHapticRampStart: CGFloat = 24

    public static func verticalMode(translation: CGPoint) -> VerticalMode {
        if translation.y <= -verticalThreshold { return .menu }
        if translation.y >= verticalThreshold { return .lock }
        return .playback
    }

    /// A temporary, continuous half-speed…double-speed range with a small dead zone.
    /// It deliberately never writes `ReaderSettings.baseWPM`.
    public static func effectiveWPM(baseWPM: Double, horizontalTranslation: CGFloat) -> Double {
        let magnitude = max(0, abs(horizontalTranslation) - horizontalDeadZone)
        let signed = horizontalTranslation < 0 ? -magnitude : magnitude
        let factor = pow(2, Double(signed / 150))
        return min(max(baseWPM * factor, baseWPM * 0.5), baseWPM * 2)
    }

    public static func pausesForContext(horizontalTranslation: CGFloat) -> Bool {
        horizontalTranslation <= horizontalPauseThreshold
    }

    /// Three increasingly firm soft ticks lead into the directional threshold.
    /// Zero means the finger is outside the haptic ramp.
    public static func verticalHapticStep(translationY: CGFloat) -> Int {
        let distance = abs(translationY)
        guard distance >= verticalHapticRampStart, distance < verticalThreshold else { return 0 }
        let progress = (distance - verticalHapticRampStart) /
            (verticalThreshold - verticalHapticRampStart)
        return min(3, Int(progress * 3) + 1)
    }

    public static func cardOriginY(
        touchY: CGFloat, cardHeight: CGFloat, boundsHeight: CGFloat,
        safeTop: CGFloat, safeBottom: CGFloat
    ) -> CGFloat {
        let topLimit = safeTop + 8
        let bottomLimit = boundsHeight - safeBottom - cardHeight - 8
        let aboveFinger = touchY - cardHeight - 38
        if aboveFinger >= topLimit { return min(aboveFinger, bottomLimit) }
        return min(max(touchY + 30, topLimit), bottomLimit)
    }

    public static func titleDuration(baseWPM: Double) -> TimeInterval {
        max(1.4, (60 / max(baseWPM, 1)) * 5)
    }

    public static func titleText(title: String, resumeIndex: Int) -> String {
        resumeIndex > 0 ? "Resuming: \(title)" : title
    }
}

/// The one canonical set of actions used by the drag-up link menu.
private enum LinkPreviewAction: CaseIterable {
    case share, copy, open

    var title: String {
        switch self {
        case .share: return "Share Link"
        case .copy: return "Copy Link"
        case .open: return "Open Link"
        }
    }

    var symbol: String {
        switch self {
        case .share: return "square.and.arrow.up"
        case .copy: return "doc.on.doc"
        case .open: return "safari"
        }
    }
}

private struct LinkPreviewArticle {
    let item: ReadingListItem
    let content: ArticleContent
    let resumeIndex: Int
    let isSaved: Bool
}

private enum LinkPreviewLoader {
    static func load(url: URL) async -> LinkPreviewArticle? {
        let canonical = PreloadStore.canonicalString(for: url)
        let store = ReadingListStore.shared
        if let saved = store.items().first(where: {
            guard let candidate = $0.url else { return false }
            return PreloadStore.canonicalString(for: candidate) == canonical
        }), let content = store.content(for: saved) {
            return LinkPreviewArticle(
                item: saved, content: content, resumeIndex: saved.lastWordIndex ?? 0, isSaved: true)
        }

        let content: ArticleContent
        if let cached = PreloadStore.shared.articleContent(for: url) {
            content = cached
        } else {
            guard let html = try? await ArticleFetcher().fetchHTML(from: url),
                  let extracted = try? ArticleExtractor().extract(html: html, baseURL: url),
                  extracted.isArticleLike else { return nil }
            content = extracted
        }

        var transient = ReadingListItem(urlString: canonical)
        transient.title = content.title
        let resume = ReaderSettings.linkPreviewWordIndex(for: canonical)
        transient.lastWordIndex = resume
        return LinkPreviewArticle(item: transient, content: content, resumeIndex: resume, isSaved: false)
    }
}

/// The link-preview RSVP experience for an ALREADY-LOADED article, driven by an
/// external long-press (the Reader card carousel long-presses a card): same
/// glass card, appearance animation, drag left/right/up gestures, lock-arming,
/// and haptics as holding a link — but with no URL resolution or fetch.
public final class ArticleRSVPPreviewSession {
    private weak var host: UIViewController?
    private weak var preview: LinkRSVPPreviewViewController?
    private let url: URL
    private let initialHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let rampHaptic = UIImpactFeedbackGenerator(style: .soft)
    private var hapticDirection = 0
    private var hapticRampStep = 0

    public init?(
        host: UIViewController,
        item: ReadingListItem,
        content: ArticleContent,
        anchorPoint: CGPoint
    ) {
        guard let url = item.url ?? URL(string: item.urlString) else { return nil }
        self.host = host
        self.url = url
        initialHaptic.impactOccurred(intensity: 0.7)
        rampHaptic.prepare()
        let article = LinkPreviewArticle(
            item: item, content: content,
            resumeIndex: item.lastWordIndex ?? 0, isSaved: true)
        let preview = LinkRSVPPreviewViewController(
            article: article, url: url, anchorPoint: anchorPoint)
        preview.onDismiss = { [weak self] in self?.teardown() }
        preview.onAction = { [weak self] action in self?.perform(action) }
        self.preview = preview
        host.addChild(preview)
        preview.view.frame = host.view.bounds
        preview.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.addSubview(preview.view)
        preview.didMove(toParent: host)
        preview.beginPlayback()
    }

    /// Forward every .changed of the driving long-press (translation from the
    /// press's start, finger point in the HOST view's coordinates).
    public func update(translation: CGPoint, fingerPoint: CGPoint) {
        updateDirectionalHaptics(translationY: translation.y)
        preview?.update(translation: translation, fingerPoint: fingerPoint)
    }

    /// The finger lifted: lock into playback or dismiss, per the drag state.
    public func finish() {
        resetDirectionalHaptics()
        guard let preview else { return }
        preview.releaseFinger()
    }

    public func cancel() {
        resetDirectionalHaptics()
        preview?.dismissPreview()
    }

    private func teardown() {
        guard let preview else { return }
        preview.willMove(toParent: nil)
        preview.view.removeFromSuperview()
        preview.removeFromParent()
    }

    private func perform(_ action: LinkPreviewAction) {
        guard let host else { return }
        switch action {
        case .share:
            let activity = UIActivityViewController(
                activityItems: [url], applicationActivities: nil)
            activity.popoverPresentationController?.sourceView = host.view
            activity.popoverPresentationController?.sourceRect = CGRect(
                x: host.view.bounds.midX, y: host.view.bounds.midY, width: 1, height: 1)
            host.present(activity, animated: true)
        case .copy:
            UIPasteboard.general.url = url
        case .open:
            UIApplication.shared.open(url)
        }
    }

    private func updateDirectionalHaptics(translationY: CGFloat) {
        let direction = translationY < 0 ? -1 : (translationY > 0 ? 1 : 0)
        if direction != hapticDirection {
            hapticDirection = direction
            hapticRampStep = 0
        }
        let step = LinkRSVPPreviewGesturePolicy.verticalHapticStep(translationY: translationY)
        guard step > hapticRampStep else { return }
        hapticRampStep = step
        rampHaptic.impactOccurred(intensity: 0.4 + 0.15 * CGFloat(step))
    }

    private func resetDirectionalHaptics() {
        hapticDirection = 0
        hapticRampStep = 0
    }
}

/// Owns one recognizer and one preview. The recognizer remains attached to the source
/// view, so it continues receiving changes even while the noninteractive overlay is up.
final class LinkRSVPPreviewInteraction: NSObject, UIGestureRecognizerDelegate {
    typealias URLResolver = (CGPoint) -> URL?

    private weak var host: UIViewController?
    private weak var sourceView: UIView?
    private let resolveURL: URLResolver
    private let sourcePlaybackChanged: (Bool) -> Void
    private let gesture = UILongPressGestureRecognizer()
    private var startPoint = CGPoint.zero
    private var loadTask: Task<Void, Never>?
    private weak var preview: LinkRSVPPreviewViewController?
    private weak var loadingOverlay: UIView?
    private let initialHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let rampHaptic = UIImpactFeedbackGenerator(style: .soft)
    private let thresholdHaptic = UIImpactFeedbackGenerator(style: .medium)
    private var hapticDirection = 0
    private var hapticRampStep = 0
    private var didFireThresholdHaptic = false

    init(
        host: UIViewController,
        sourceView: UIView,
        resolveURL: @escaping URLResolver,
        sourcePlaybackChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.host = host
        self.sourceView = sourceView
        self.resolveURL = resolveURL
        self.sourcePlaybackChanged = sourcePlaybackChanged
        super.init()
        // The preview begins only after a short STATIONARY hold on the link:
        // `allowableMovement` is deliberately tight, so a touch that starts
        // moving within the hold window (a scroll that happens to land on a
        // link) fails this press instead of mounting the preview mid-drag.
        // Once the press HAS begun, movement is unrestricted — the drag
        // left/right/up interactions ride the same touch.
        gesture.minimumPressDuration = 0.35
        gesture.allowableMovement = 10
        gesture.cancelsTouchesInView = true
        gesture.delegate = self
        gesture.addTarget(self, action: #selector(handleGesture(_:)))
        sourceView.addGestureRecognizer(gesture)
        initialHaptic.prepare()
        // UITextView's private link/context-menu recognizer otherwise wins the same
        // hold, emits its haptic, and leaves our custom interaction in `.failed`.
        // Make every recognizer that was already installed wait for the link-only
        // recognizer. On non-links our delegate rejects immediately, so scrolling,
        // selection, and normal taps retain their existing behavior. Pans are
        // exempt (matching `shouldBeRequiredToFailBy` below): the text view's own
        // scroll pan must never wait on the hold, or a scroll that starts on a
        // link tap target is eaten by the press.
        for competing in sourceView.gestureRecognizers ?? []
        where competing !== gesture && !(competing is UIPanGestureRecognizer) {
            competing.require(toFail: gesture)
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let sourceView else { return false }
        return resolveURL(touch.location(in: sourceView)) != nil
    }

    /// Every non-pan recognizer sharing this touch — including ones installed
    /// AFTER us or on ancestor views (the text view's context-menu interaction,
    /// a host carousel's long-press), which the init-time `require(toFail:)`
    /// loop can't reach — must wait for the link-only press to fail. On a link
    /// our press begins, so they all fail and none of them can cancel the
    /// preview mid-hold: it appears and starts playback immediately, finger
    /// stationary. On non-links `shouldReceive` refuses the touch, so
    /// everything else behaves exactly as before. Pans stay independent — a
    /// drag that starts on a link must still scroll.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        !(otherGestureRecognizer is UIPanGestureRecognizer)
    }

    @objc private func handleGesture(_ gesture: UILongPressGestureRecognizer) {
        guard let sourceView, let host else { return }
        let point = gesture.location(in: sourceView)
        switch gesture.state {
        case .began:
            guard let url = resolveURL(point) else { return }
            startPoint = point
            resetDirectionalHaptics()
            initialHaptic.impactOccurred(intensity: 0.7)
            rampHaptic.prepare()
            sourcePlaybackChanged(true)
            let anchorPoint = sourceView.convert(point, to: host.view)
            showLoading(in: host, touchPoint: anchorPoint)
            loadTask?.cancel()
            loadTask = Task { [weak self, weak host] in
                let article = await LinkPreviewLoader.load(url: url)
                guard !Task.isCancelled, let self, let host,
                      host.viewIfLoaded?.window != nil else { return }
                guard let article else {
                    self.showLoadingFailure()
                    return
                }
                self.loadingOverlay?.removeFromSuperview()
                let preview = LinkRSVPPreviewViewController(
                    article: article, url: url, anchorPoint: anchorPoint)
                preview.onDismiss = { [weak self] in self?.finishPreview() }
                preview.onAction = { [weak self] action in self?.perform(action, url: url) }
                self.preview = preview
                host.addChild(preview)
                preview.view.frame = host.view.bounds
                preview.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                host.view.addSubview(preview.view)
                preview.didMove(toParent: host)
                preview.beginPlayback()
                let current = gesture.location(in: sourceView)
                preview.update(translation: CGPoint(x: current.x - self.startPoint.x,
                                                    y: current.y - self.startPoint.y),
                               fingerPoint: sourceView.convert(current, to: host.view))
            }
        case .changed:
            let translation = CGPoint(x: point.x - startPoint.x, y: point.y - startPoint.y)
            updateDirectionalHaptics(translationY: translation.y)
            preview?.update(translation: translation, fingerPoint: sourceView.convert(point, to: host.view))
        case .ended:
            resetDirectionalHaptics()
            loadTask?.cancel()
            loadingOverlay?.removeFromSuperview()
            guard let preview else { finishPreview(); return }
            preview.releaseFinger()
        case .cancelled, .failed:
            resetDirectionalHaptics()
            loadTask?.cancel()
            loadingOverlay?.removeFromSuperview()
            preview?.dismissPreview()
            if preview == nil { finishPreview() }
        default:
            break
        }
    }

    private func perform(_ action: LinkPreviewAction, url: URL) {
        guard let host else { return }
        switch action {
        case .share:
            let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            activity.popoverPresentationController?.sourceView = host.view
            activity.popoverPresentationController?.sourceRect = CGRect(
                x: host.view.bounds.midX, y: host.view.bounds.midY, width: 1, height: 1)
            host.present(activity, animated: true)
        case .copy:
            UIPasteboard.general.url = url
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .open:
            UIApplication.shared.open(url)
        }
    }

    private func finishPreview() {
        loadingOverlay?.removeFromSuperview()
        preview = nil
        sourcePlaybackChanged(false)
    }

    private func showLoading(in host: UIViewController, touchPoint: CGPoint) {
        loadingOverlay?.removeFromSuperview()
        let panel = UIVisualEffectView(effect: GlassStyle.barEffect())
        panel.layer.cornerRadius = 22
        panel.clipsToBounds = true
        panel.frame = CGRect(x: (host.view.bounds.width - 220) / 2,
                             y: LinkRSVPPreviewGesturePolicy.cardOriginY(
                                touchY: touchPoint.y, cardHeight: 92,
                                boundsHeight: host.view.bounds.height,
                                safeTop: host.view.safeAreaInsets.top,
                                safeBottom: host.view.safeAreaInsets.bottom),
                             width: 220, height: 92)
        panel.autoresizingMask = [.flexibleTopMargin, .flexibleBottomMargin,
                                  .flexibleLeftMargin, .flexibleRightMargin]
        panel.isUserInteractionEnabled = false
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        spinner.frame = CGRect(x: 24, y: 30, width: 32, height: 32)
        spinner.tag = 1
        let label = UILabel(frame: CGRect(x: 65, y: 0, width: 135, height: 92))
        label.text = "Loading preview…"
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.tag = 2
        panel.contentView.addSubview(spinner)
        panel.contentView.addSubview(label)
        host.view.addSubview(panel)
        loadingOverlay = panel
    }

    private func showLoadingFailure() {
        guard let panel = loadingOverlay as? UIVisualEffectView else { return }
        panel.contentView.viewWithTag(1)?.removeFromSuperview()
        let label = panel.contentView.viewWithTag(2) as? UILabel
        label?.frame = panel.contentView.bounds.insetBy(dx: 18, dy: 0)
        label?.textAlignment = .center
        label?.text = "Preview unavailable"
    }

    private func updateDirectionalHaptics(translationY: CGFloat) {
        let direction = translationY == 0 ? 0 : (translationY < 0 ? -1 : 1)
        let distance = abs(translationY)
        if direction != hapticDirection {
            hapticDirection = direction
            hapticRampStep = 0
            didFireThresholdHaptic = false
        }
        if distance < LinkRSVPPreviewGesturePolicy.verticalHapticRampStart {
            hapticRampStep = 0
            didFireThresholdHaptic = false
            return
        }
        if distance >= LinkRSVPPreviewGesturePolicy.verticalThreshold {
            guard !didFireThresholdHaptic else { return }
            didFireThresholdHaptic = true
            thresholdHaptic.impactOccurred(intensity: 0.78)
            return
        }
        let step = LinkRSVPPreviewGesturePolicy.verticalHapticStep(translationY: translationY)
        guard step > hapticRampStep else { return }
        hapticRampStep = step
        rampHaptic.impactOccurred(intensity: 0.12 + CGFloat(step) * 0.12)
        rampHaptic.prepare()
    }

    private func resetDirectionalHaptics() {
        hapticDirection = 0
        hapticRampStep = 0
        didFireThresholdHaptic = false
    }
}

private final class LinkRSVPPreviewViewController: UIViewController, AudioPlaybackObserver {
    private let article: LinkPreviewArticle
    private let url: URL
    private let anchorPoint: CGPoint
    private let engine: RSVPEngine
    private var index: Int
    private var timer: Timer?
    private var titleTimer: Timer?
    private var isShowingTitle = true
    private var isPausedByMenu = false
    private var isPausedByHorizontalDrag = false
    private var isPausedByControl = false
    private var isAudioMode = false
    private var isLockArmed = false
    private var isLocked = false
    private var currentWPM = ReaderSettings.baseWPM
    private var selectedAction: LinkPreviewAction?
    private var intervalStartedAt: Date?
    private var intervalDuration: TimeInterval?

    var onDismiss: (() -> Void)?
    var onAction: ((LinkPreviewAction) -> Void)?

    private let dimView = UIView()
    private let card = UIVisualEffectView(effect: GlassStyle.barEffect())
    private let focusLabel = UILabel()
    private let topMark = GlassStyle.reticuleMark()
    private let bottomMark = GlassStyle.reticuleMark()
    private let lockImage = UIImageView(image: UIImage(systemName: "lock.fill"))
    private let speedLabel = UILabel()
    private let previousContextLabel = UILabel()
    private let nextContextLabel = UILabel()
    private let chin = UIView()
    private let chinStack = UIStackView()
    private let skipBackButton = UIButton(type: .system)
    private let slowButton = UIButton(type: .system)
    private let playPauseButton = UIButton(type: .system)
    private let fastButton = UIButton(type: .system)
    private let skipForwardButton = UIButton(type: .system)
    private let audioButton = UIButton(type: .system)
    private let menu = UIVisualEffectView(effect: GlassStyle.barEffect())
    private var actionRows: [(LinkPreviewAction, UIView)] = []
    /// Drag-up affordance floating above the card: an up arrow + "More actions".
    /// Visible while the driving press is live; hidden once the menu is up
    /// (drag-up arrived) or the card is locked (the press ended).
    private let moreActionsHint = UIVisualEffectView(effect: GlassStyle.barEffect())

    init(article: LinkPreviewArticle, url: URL, anchorPoint: CGPoint) {
        self.article = article
        self.url = url
        self.anchorPoint = anchorPoint
        let engine = RSVPEngine(content: article.content)
        self.engine = engine
        self.index = min(max(article.resumeIndex, 0), max(0, engine.words.count - 1))
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        dimView.backgroundColor = UIColor.black.withAlphaComponent(0.08)
        dimView.frame = view.bounds
        dimView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dimView.isUserInteractionEnabled = false
        view.addSubview(dimView)

        card.layer.cornerRadius = 24
        card.clipsToBounds = true
        view.addSubview(card)

        focusLabel.textAlignment = .center
        focusLabel.textColor = .label
        focusLabel.font = .systemFont(ofSize: 25, weight: .semibold)
        focusLabel.numberOfLines = 2
        focusLabel.adjustsFontSizeToFitWidth = true
        focusLabel.minimumScaleFactor = 0.55
        focusLabel.lineBreakMode = .byTruncatingTail
        card.contentView.addSubview(focusLabel)
        card.contentView.addSubview(topMark)
        card.contentView.addSubview(bottomMark)

        lockImage.tintColor = .label
        lockImage.alpha = 0
        lockImage.contentMode = .scaleAspectFit
        card.contentView.addSubview(lockImage)

        speedLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        speedLabel.textColor = .secondaryLabel
        speedLabel.textAlignment = .center
        card.contentView.addSubview(speedLabel)

        for label in [previousContextLabel, nextContextLabel] {
            label.font = .systemFont(ofSize: 12, weight: .regular)
            label.textColor = .secondaryLabel
            label.textAlignment = .center
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.alpha = 0
            card.contentView.addSubview(label)
        }

        configureChin()

        configureMoreActionsHint()
        configureMenu()
        let outsideTap = UITapGestureRecognizer(target: self, action: #selector(outsideTapped(_:)))
        view.addGestureRecognizer(outsideTap)
        view.isUserInteractionEnabled = false
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = min(360, view.bounds.width - 32)
        let baseHeight: CGFloat = 190
        let chinHeight: CGFloat = isLocked ? 82 : 0
        let height = baseHeight + chinHeight
        card.frame = CGRect(x: (view.bounds.width - width) / 2,
                            y: LinkRSVPPreviewGesturePolicy.cardOriginY(
                                touchY: anchorPoint.y, cardHeight: height,
                                boundsHeight: view.bounds.height,
                                safeTop: view.safeAreaInsets.top,
                                safeBottom: view.safeAreaInsets.bottom),
                            width: width, height: height)
        // This focus region is fixed at two lines for both title and word playback.
        focusLabel.frame = CGRect(x: 22, y: 42, width: width - 44, height: 82)
        let markWidth: CGFloat = 42
        topMark.frame = CGRect(x: (width - markWidth) / 2, y: 25, width: markWidth, height: 5)
        bottomMark.frame = CGRect(x: (width - markWidth) / 2, y: 136, width: markWidth, height: 5)
        lockImage.frame = CGRect(x: (width - 64) / 2, y: 63, width: 64, height: 64)
        previousContextLabel.frame = CGRect(x: 24, y: 9, width: width - 48, height: 18)
        nextContextLabel.frame = CGRect(x: 24, y: 146, width: width - 48, height: 18)
        speedLabel.frame = CGRect(x: 16, y: baseHeight - 27, width: width - 32, height: 18)
        chin.frame = CGRect(x: 0, y: baseHeight, width: width, height: chinHeight)
        chinStack.frame = CGRect(x: 12, y: 10, width: width - 24, height: max(0, chinHeight - 18))
        // Only the menu's SIZE is layout-derived. Its origin belongs exclusively
        // to `positionMenu` (anchored to the press's start point): re-deriving a
        // default origin here teleported the menu — visibly, whenever a layout
        // pass landed while it was up or still fading out — to a spot above the
        // card before the next drag event snapped it back.
        menu.frame.size = CGSize(width: width, height: 136)
        let hintSize = CGSize(width: 118, height: 44)
        moreActionsHint.frame = CGRect(
            x: card.frame.midX - hintSize.width / 2,
            y: max(view.safeAreaInsets.top + 2, card.frame.minY - hintSize.height - 8),
            width: hintSize.width, height: hintSize.height)
        layoutMenuRows()
    }

    func beginPlayback() {
        loadViewIfNeeded()
        // The driving gesture forwards a `.changed` immediately after mounting;
        // the menu/card geometry that `update` positions against must be real
        // before that first call, not zero-sized pre-layout frames.
        view.layoutIfNeeded()
        focusLabel.text = LinkRSVPPreviewGesturePolicy.titleText(
            title: article.content.title, resumeIndex: article.resumeIndex)
        speedLabel.text = "\(Int(currentWPM.rounded())) wpm"
        view.alpha = 0
        UIView.animate(withDuration: 0.16) { self.view.alpha = 1 }
        scheduleTitleTransition()
    }

    private func scheduleTitleTransition() {
        titleTimer?.invalidate()
        titleTimer = Timer.scheduledTimer(
            withTimeInterval: LinkRSVPPreviewGesturePolicy.titleDuration(baseWPM: currentWPM), repeats: false
        ) { [weak self] _ in
            self?.isShowingTitle = false
            self?.showCurrentWord()
            self?.scheduleNext()
        }
    }

    func update(translation: CGPoint, fingerPoint: CGPoint) {
        let mode = LinkRSVPPreviewGesturePolicy.verticalMode(translation: translation)
        isLockArmed = mode == .lock
        UIView.animate(withDuration: 0.12) {
            self.lockImage.alpha = self.isLockArmed ? 0.18 : 0
        }

        if mode == .menu {
            endHorizontalContextPause(shouldResume: false)
            pauseForMenu()
            positionMenu(aroundStartPoint: CGPoint(
                x: fingerPoint.x - translation.x, y: fingerPoint.y - translation.y))
            selectedAction = action(at: fingerPoint)
            updateMenuHighlight()
        } else {
            hideMenuAndResume()
            selectedAction = nil
            if mode == .playback,
               LinkRSVPPreviewGesturePolicy.pausesForContext(
                horizontalTranslation: translation.x) {
                pauseForHorizontalContext()
            } else {
                endHorizontalContextPause(shouldResume: true)
                let adjusted = LinkRSVPPreviewGesturePolicy.effectiveWPM(
                    baseWPM: ReaderSettings.baseWPM, horizontalTranslation: translation.x)
                applyTemporaryWPM(adjusted)
                updateSpeedLabel()
            }
        }
    }

    func releaseFinger() {
        if let selectedAction {
            let action = selectedAction
            dismissPreview { [weak self] in self?.onAction?(action) }
        } else if isLockArmed {
            isLocked = true
            isLockArmed = false
            view.isUserInteractionEnabled = true
            UIView.animate(withDuration: 0.22, animations: {
                self.lockImage.alpha = 0
                self.moreActionsHint.alpha = 0
                self.view.setNeedsLayout()
                self.view.layoutIfNeeded()
                self.chin.alpha = 1
            })
        } else {
            dismissPreview()
        }
    }

    func dismissPreview(completion: (() -> Void)? = nil) {
        persistPosition()
        timer?.invalidate()
        titleTimer?.invalidate()
        if isAudioMode, ReaderAudioLauncher.center?.currentItemInfo?.itemID == article.item.id {
            ReaderAudioLauncher.center?.pause()
        }
        UIView.animate(withDuration: 0.14, animations: { self.view.alpha = 0 }) { _ in
            self.willMove(toParent: nil)
            self.view.removeFromSuperview()
            self.removeFromParent()
            self.onDismiss?()
            completion?()
        }
    }

    @objc private func outsideTapped(_ gesture: UITapGestureRecognizer) {
        guard isLocked, !card.frame.contains(gesture.location(in: view)) else { return }
        dismissPreview()
    }

    private var isPlaybackPaused: Bool {
        isPausedByMenu || isPausedByHorizontalDrag || isPausedByControl
    }

    private func showCurrentWord() {
        guard engine.words.indices.contains(index) else { return }
        let word = engine.words[index]
        let characters = Array(word.text)
        guard !characters.isEmpty else { return }
        let orp = min(word.orpIndex, characters.count - 1)
        let attributed = NSMutableAttributedString(
            string: word.text,
            attributes: [.font: UIFont.monospacedSystemFont(ofSize: 31, weight: .medium),
                         .foregroundColor: UIColor.label])
        let start = String(characters.prefix(orp)).utf16.count
        let length = String(characters[orp]).utf16.count
        attributed.addAttribute(.foregroundColor, value: GlassStyle.readingAccent,
                                range: NSRange(location: start, length: length))
        focusLabel.numberOfLines = 1
        focusLabel.font = .monospacedSystemFont(ofSize: 31, weight: .medium)
        focusLabel.attributedText = attributed
        if isPausedByHorizontalDrag || isPausedByControl { updateContext() }
    }

    private func updateContext() {
        let radius = 12
        let lower = max(0, index - radius)
        let upper = min(engine.words.count, index + radius + 1)
        previousContextLabel.text = engine.words[lower..<index].map(\.text).joined(separator: " ")
        nextContextLabel.text = engine.words[(index + 1)..<upper].map(\.text).joined(separator: " ")
    }

    private func setContextVisible(_ visible: Bool) {
        if visible { updateContext() }
        UIView.animate(withDuration: 0.14) {
            self.previousContextLabel.alpha = visible ? 1 : 0
            self.nextContextLabel.alpha = visible ? 1 : 0
            self.speedLabel.alpha = visible ? 0 : 1
        }
    }

    private func pauseForHorizontalContext() {
        guard !isPausedByHorizontalDrag else { return }
        isPausedByHorizontalDrag = true
        timer?.invalidate()
        titleTimer?.invalidate()
        if isShowingTitle {
            isShowingTitle = false
            showCurrentWord()
        }
        setContextVisible(true)
        playPauseButton.configuration?.image = UIImage(systemName: "play.fill")
    }

    private func endHorizontalContextPause(shouldResume: Bool) {
        guard isPausedByHorizontalDrag else { return }
        isPausedByHorizontalDrag = false
        setContextVisible(isPausedByControl)
        if shouldResume { resumePlaybackIfNeeded() }
    }

    private func resumePlaybackIfNeeded() {
        guard !isPlaybackPaused, !isAudioMode else { return }
        playPauseButton.configuration?.image = UIImage(systemName: "pause.fill")
        if isShowingTitle { scheduleTitleTransition() } else { scheduleNext() }
    }

    private func updateSpeedLabel() {
        speedLabel.text = "\(Int(currentWPM.rounded())) wpm"
    }

    private func scheduleNext() {
        guard !isShowingTitle, !isPlaybackPaused, !isAudioMode,
              engine.words.indices.contains(index) else { return }
        startWordTimer(engine.duration(at: index, wpm: currentWPM))
    }

    private func startWordTimer(_ duration: TimeInterval) {
        timer?.invalidate()
        intervalStartedAt = Date()
        intervalDuration = duration
        timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) {
            [weak self] _ in
            guard let self, self.index < self.engine.words.count - 1 else { return }
            self.index += 1
            self.showCurrentWord()
            self.scheduleNext()
        }
    }

    private func pauseForMenu() {
        guard !isPausedByMenu else { return }
        isPausedByMenu = true
        timer?.invalidate()
        titleTimer?.invalidate()
        setMoreActionsHintVisible(false)
        UIView.animate(withDuration: 0.15) { self.menu.alpha = 1 }
    }

    private func hideMenuAndResume() {
        guard isPausedByMenu else { return }
        isPausedByMenu = false
        if !isLocked { setMoreActionsHintVisible(true) }
        UIView.animate(withDuration: 0.15) { self.menu.alpha = 0 }
        resumePlaybackIfNeeded()
    }

    private func applyTemporaryWPM(_ newWPM: Double) {
        guard abs(newWPM - currentWPM) > 0.5 else { return }
        let oldWPM = currentWPM
        currentWPM = newWPM
        guard !isShowingTitle, !isPlaybackPaused, !isAudioMode,
              let started = intervalStartedAt, let oldDuration = intervalDuration,
              oldDuration > 0, timer != nil else { return }
        let remainingFraction = max(0, 1 - Date().timeIntervalSince(started) / oldDuration)
        // Word duration is inversely proportional to WPM; rescale only the remaining
        // portion so a drag takes effect now without restarting the displayed word.
        startWordTimer(oldDuration * (oldWPM / newWPM) * remainingFraction)
    }

    private func persistPosition() {
        let token = engine.tokenIndex(forFrameIndex: index) ?? index
        if article.isSaved {
            ReadingListStore.shared.saveReaderExitPosition(
                clearScrollOffset: true, lastWordIndex: token, for: article.item.id)
        } else {
            ReaderSettings.setLinkPreviewWordIndex(token, for: PreloadStore.canonicalString(for: url))
        }
    }

    private func configureChin() {
        chin.alpha = 0
        chin.layer.borderWidth = 0.5
        chin.layer.borderColor = UIColor.separator.withAlphaComponent(0.45).cgColor
        card.contentView.addSubview(chin)

        let buttons: [(UIButton, String, String)] = [
            (skipBackButton, "backward.fill", "Skip back 25 words"),
            (slowButton, "tortoise.fill", "Slow down"),
            (playPauseButton, "pause.fill", "Pause"),
            (fastButton, "hare.fill", "Speed up"),
            (skipForwardButton, "forward.fill", "Skip forward 25 words"),
            (audioButton, "speaker.slash", "Read aloud"),
        ]
        for (button, symbol, label) in buttons {
            button.configuration = GlassStyle.circularButtonConfiguration(symbol: symbol, padding: 10)
            button.accessibilityLabel = label
            button.widthAnchor.constraint(equalToConstant: 42).isActive = true
            button.heightAnchor.constraint(equalToConstant: 42).isActive = true
            chinStack.addArrangedSubview(button)
        }
        chinStack.axis = .horizontal
        chinStack.alignment = .center
        chinStack.distribution = .equalSpacing
        chin.addSubview(chinStack)

        skipBackButton.addTarget(self, action: #selector(skipBack), for: .touchUpInside)
        slowButton.addTarget(self, action: #selector(slowDown), for: .touchUpInside)
        playPauseButton.addTarget(self, action: #selector(toggleControlPlayback), for: .touchUpInside)
        fastButton.addTarget(self, action: #selector(speedUp), for: .touchUpInside)
        skipForwardButton.addTarget(self, action: #selector(skipForward), for: .touchUpInside)
        audioButton.addTarget(self, action: #selector(toggleAudioPlayback), for: .touchUpInside)
        ReaderAudioLauncher.center?.addObserver(self)
    }

    @objc private func skipBack() { skip(by: -25) }
    @objc private func skipForward() { skip(by: 25) }

    private func skip(by delta: Int) {
        let target = RSVPEngine.skipTarget(
            currentIndex: index, by: delta, wordCount: engine.words.count)
        guard target != index else { return }
        index = target
        isShowingTitle = false
        showCurrentWord()
        persistPosition()
        if isAudioMode, let center = ReaderAudioLauncher.center {
            let shouldRemainPaused = !center.currentSnapshot.isAudiblyPlaying
            let token = engine.tokenIndex(forFrameIndex: index) ?? index
            center.play(item: article.item, content: article.content, fromWordIndex: token)
            if shouldRemainPaused {
                DispatchQueue.main.async { center.pause() }
            }
        } else {
            timer?.invalidate()
            resumePlaybackIfNeeded()
        }
    }

    @objc private func slowDown() { adjustLockedSpeed(by: -25) }
    @objc private func speedUp() { adjustLockedSpeed(by: 25) }

    private func adjustLockedSpeed(by delta: Double) {
        currentWPM = min(max(currentWPM + delta, 100), 900)
        ReaderSettings.baseWPM = currentWPM
        updateSpeedLabel()
        if !isPlaybackPaused && !isAudioMode {
            timer?.invalidate()
            scheduleNext()
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    @objc private func toggleControlPlayback() {
        if isAudioMode, let center = ReaderAudioLauncher.center {
            if center.currentItemInfo?.itemID == article.item.id,
               center.currentSnapshot.isAudiblyPlaying {
                center.pause()
            } else if center.currentItemInfo?.itemID == article.item.id {
                center.resume()
            } else {
                let token = engine.tokenIndex(forFrameIndex: index) ?? index
                center.play(item: article.item, content: article.content, fromWordIndex: token)
            }
            return
        }
        if isPausedByControl {
            isPausedByControl = false
            setContextVisible(isPausedByHorizontalDrag)
            resumePlaybackIfNeeded()
        } else {
            isPausedByControl = true
            timer?.invalidate()
            titleTimer?.invalidate()
            if isShowingTitle {
                isShowingTitle = false
                showCurrentWord()
            }
            setContextVisible(true)
            playPauseButton.configuration?.image = UIImage(systemName: "play.fill")
            playPauseButton.accessibilityLabel = "Play"
        }
    }

    @objc private func toggleAudioPlayback() {
        guard let center = ReaderAudioLauncher.center else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        if isAudioMode {
            if center.currentItemInfo?.itemID == article.item.id { center.pause() }
            isAudioMode = false
            isPausedByControl = true
            audioButton.configuration?.image = UIImage(systemName: "speaker.slash")
            audioButton.accessibilityLabel = "Read aloud"
            playPauseButton.configuration?.image = UIImage(systemName: "play.fill")
            setContextVisible(true)
        } else {
            timer?.invalidate()
            titleTimer?.invalidate()
            isShowingTitle = false
            isAudioMode = true
            isPausedByControl = false
            showCurrentWord()
            setContextVisible(true)
            let token = engine.tokenIndex(forFrameIndex: index) ?? index
            center.play(item: article.item, content: article.content, fromWordIndex: token)
            audioButton.configuration?.image = UIImage(systemName: "speaker.wave.2.fill")
            audioButton.accessibilityLabel = "Turn off read aloud"
            playPauseButton.configuration?.image = UIImage(systemName: "pause.fill")
        }
    }

    func audioPlaybackCenter(_ center: AudioPlaybackCenter, didChangeState state: AudioPlaybackState) {
        guard isAudioMode, center.currentItemInfo?.itemID == article.item.id else { return }
        let playing = center.currentSnapshot.isAudiblyPlaying
        playPauseButton.configuration?.image = UIImage(systemName: playing ? "pause.fill" : "play.fill")
        playPauseButton.accessibilityLabel = playing ? "Pause" : "Play"
    }

    func audioPlaybackCenter(_ center: AudioPlaybackCenter, didEmitWordEvent event: AudioWordEvent) {
        guard isAudioMode, center.currentItemInfo?.itemID == article.item.id,
              let token = AudioWordEventTokenMapping.tokenIndex(
                blockIndex: event.blockIndex,
                utf16Location: event.rangeInBlockText.location,
                blocks: article.content.blocks,
                blockTokenStarts: AudioWordEventTokenMapping.blockTokenStarts(
                    blocks: article.content.blocks)),
              let frame = engine.frameIndex(forTokenIndex: token) else { return }
        index = frame
        showCurrentWord()
    }

    private func configureMoreActionsHint() {
        moreActionsHint.layer.cornerRadius = 14
        moreActionsHint.layer.cornerCurve = .continuous
        moreActionsHint.clipsToBounds = true
        moreActionsHint.isUserInteractionEnabled = false

        let arrow = UIImageView(image: UIImage(systemName: "chevron.up"))
        arrow.tintColor = .secondaryLabel
        arrow.contentMode = .scaleAspectFit
        arrow.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 12, weight: .semibold)
        let label = UILabel()
        label.text = "More actions"
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabel
        label.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [arrow, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 1
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        moreActionsHint.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: moreActionsHint.contentView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: moreActionsHint.contentView.centerYAnchor),
        ])
        view.addSubview(moreActionsHint)
    }

    private func setMoreActionsHintVisible(_ visible: Bool) {
        UIView.animate(withDuration: 0.15) {
            self.moreActionsHint.alpha = visible ? 1 : 0
        }
    }

    private func configureMenu() {
        menu.layer.cornerRadius = 18
        menu.clipsToBounds = true
        menu.alpha = 0
        view.addSubview(menu)
        for action in LinkPreviewAction.allCases {
            let row = UIView()
            let image = UIImageView(image: UIImage(systemName: action.symbol))
            image.tintColor = .label
            image.tag = 1
            let label = UILabel()
            label.text = action.title
            label.font = .systemFont(ofSize: 16, weight: .medium)
            label.tag = 2
            row.addSubview(image)
            row.addSubview(label)
            menu.contentView.addSubview(row)
            actionRows.append((action, row))
        }
    }

    private func layoutMenuRows() {
        let rowHeight = menu.bounds.height / CGFloat(max(actionRows.count, 1))
        for (offset, pair) in actionRows.enumerated() {
            pair.1.frame = CGRect(x: 0, y: CGFloat(offset) * rowHeight,
                                  width: menu.bounds.width, height: rowHeight)
            pair.1.viewWithTag(1)?.frame = CGRect(x: 18, y: (rowHeight - 22) / 2, width: 22, height: 22)
            pair.1.viewWithTag(2)?.frame = CGRect(x: 54, y: 0, width: menu.bounds.width - 68, height: rowHeight)
        }
    }

    private func action(at point: CGPoint) -> LinkPreviewAction? {
        guard menu.frame.insetBy(dx: -18, dy: -18).contains(point) else { return nil }
        let local = view.convert(point, to: menu.contentView)
        return actionRows.first(where: { $0.1.frame.contains(local) })?.0
    }

    private func positionMenu(aroundStartPoint start: CGPoint) {
        let width = card.bounds.width
        let x = min(max(8, start.x - width / 2), max(8, view.bounds.width - width - 8))
        let idealBottom = start.y - LinkRSVPPreviewGesturePolicy.verticalThreshold - 8
        let y = max(view.safeAreaInsets.top + 8, idealBottom - menu.bounds.height)
        menu.frame.origin = CGPoint(x: x, y: y)
        layoutMenuRows()
    }

    private func updateMenuHighlight() {
        for (action, row) in actionRows {
            row.backgroundColor = action == selectedAction
                ? GlassStyle.readingAccent.withAlphaComponent(0.2) : .clear
        }
    }
}
