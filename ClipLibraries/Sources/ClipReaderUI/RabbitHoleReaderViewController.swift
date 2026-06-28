//
//  RabbitHoleReaderViewController.swift
//  Clip
//
//  Forked, EXPERIMENTAL reader (opt-in via ReaderSettings.rabbitHoleReaderEnabled).
//  The whole reader is a persistent stack of "layers": layer 0 is the save; tapping a
//  link pushes a new focused layer on top, leaving previous layers as tappable lips
//  (title on top, the tapped line on the bottom) plus a leading indent — so you can
//  rabbit-hole several links deep without losing your place. The trail is persisted
//  per save and restored on next launch. The standard reader and the existing
//  SplitWebOverlay inline reader are untouched.
//
//  Layers rest at integer focus positions (RabbitHoleLayout). Moving between two
//  positions (dive / pop / interactive overscroll) is rendered by an injected halftone
//  dot-matrix wipe (`RabbitHoleTransitioning`) over before/after snapshots — never by
//  moving the live cards, so there's no per-frame relayout.
//

import ClipDesignSystem
import ClipModels
import ClipStorage
import UIKit

public final class RabbitHoleReaderViewController: UIViewController, UIGestureRecognizerDelegate {

    private let rootItem: ReadingListItem
    private let rootContent: ArticleContent
    private let shareProvider: ReaderShareProviding?
    private let gazeTrackerFactory: GazeTrackerFactory?
    private let transition: RabbitHoleTransitioning?
    private let store = ReadingListStore.shared
    private let stackStore = RabbitHoleStackStore.shared
    private var layout = RabbitHoleLayout()

    private var layers: [RabbitHoleLayerViewController] = []
    /// Focused-layer index (0 = root). Layers always rest at this integer focus.
    private var focus: Int = 0
    private var topIndex: Int { max(layers.count - 1, 0) }

    /// Guards against starting a transition while one is already running.
    private var transitionInFlight = false
    /// The in-flight interactive overscroll wipe (nil when not dragging).
    private var interactive: RabbitHoleInteractiveTransition?
    private var overscrollEdge: CGFloat = 1        // +1 = pulling down from the top edge
    private var overscrollBaseline: CGFloat = 0
    private weak var overscrollScroll: UIScrollView?

    private var overscrollPan: UIPanGestureRecognizer?
    private var didMarkOpened = false

    /// In-memory article content for the focused layer's outbound links, keyed by the
    /// PreloadStore canonical key. Warmed (off-main, from the on-disk preload cache)
    /// whenever the focus settles, so tapping a link renders the new layer synchronously
    /// — the dive's "after" snapshot already shows the real article, and the wipe starts
    /// immediately. Trimmed to the current focus's links to stay bounded.
    private var preloadedContent: [String: ArticleContent] = [:]
    /// The in-flight background materialization of the focused page's links (cancelled
    /// when the focus changes or the reader closes).
    private var warmTask: Task<Void, Never>?
    /// Cap on how many of a page's links we hold in memory at once.
    private static let maxPreloadedLinks = 40

    public init(item: ReadingListItem, content: ArticleContent,
                shareProvider: ReaderShareProviding? = nil,
                gazeTrackerFactory: GazeTrackerFactory? = nil,
                transition: RabbitHoleTransitioning? = nil) {
        self.rootItem = item
        self.rootContent = content
        self.shareProvider = shareProvider
        self.gazeTrackerFactory = gazeTrackerFactory
        self.transition = transition
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    deinit { warmTask?.cancel() }

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ReaderDepth.backgroundColor(for: 0)
        navigationItem.largeTitleDisplayMode = .never
        navigationController?.setNavigationBarHidden(true, animated: false)

        buildInitialStack()
        // Park the Metal overlay now so the first dive doesn't pay its setup cost mid-tap.
        transition?.prewarm(in: view)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleOverscrollPan(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)
        overscrollPan = pan

        NotificationCenter.default.addObserver(
            self, selector: #selector(persist),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyFocus()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        persist()
    }

    public override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate { _ in self.applyFocus() }
    }

    // MARK: - Stack construction

    private func buildInitialStack() {
        var descriptors: [RabbitHoleLayerDescriptor] = []
        if let restored = stackStore.load(forRootID: rootItem.id),
           let first = restored.layers.first,
           first.urlString == rootItem.urlString, !restored.layers.isEmpty {
            descriptors = restored.layers
        } else {
            descriptors = [rootDescriptor()]
        }
        for (i, descriptor) in descriptors.enumerated() {
            _ = addLayer(descriptor, preloadedContent: i == 0 ? rootContent : nil)
        }
        focus = topIndex
        applyFocus()
        markOpenedIfNeeded()
        warmPreloadsForFocusedLayer()
    }

    private func rootDescriptor() -> RabbitHoleLayerDescriptor {
        RabbitHoleLayerDescriptor(
            urlString: rootItem.urlString,
            scrollOffset: rootItem.lastScrollOffset ?? 0,
            readerMode: rootItem.lastReaderMode ?? .scroll,
            title: rootItem.title ?? rootContent.title,
            bottomLipText: nil)
    }

    @discardableResult
    private func addLayer(_ descriptor: RabbitHoleLayerDescriptor,
                          preloadedContent: ArticleContent? = nil) -> RabbitHoleLayerViewController {
        let layer = RabbitHoleLayerViewController(
            descriptor: descriptor, preloadedContent: preloadedContent,
            shareProvider: shareProvider,
            gazeTrackerFactory: gazeTrackerFactory, layout: layout)
        layer.onLinkActivated = { [weak self, weak layer] url, lineText in
            guard let self, let layer, layer === self.layers.last else { return }
            self.pushLayer(url: url, lineText: lineText, from: layer)
        }
        layer.onPopToHere = { [weak self, weak layer] in
            guard let self, let layer, let index = self.layers.firstIndex(where: { $0 === layer })
            else { return }
            self.popToLayer(index)
        }
        layer.onModeChanged = { [weak self] _ in self?.persist() }
        layer.onBack = { [weak self] in self?.handleBack() }
        // Once a (focused) layer resolves to an article, preload its links into memory.
        layer.onBecameArticle = { [weak self, weak layer] in
            guard let self, let layer, layer === self.layers[safe: self.focus] else { return }
            self.warmPreloadsForFocusedLayer()
        }
        addChild(layer)
        view.addSubview(layer.view)
        layer.didMove(toParent: self)
        layers.append(layer)
        return layer
    }

    // MARK: - Static placement (the only writer of layer frames)

    private func applyFocus(focusedIndex: Int? = nil, hiding hidden: RabbitHoleLayerViewController? = nil) {
        guard !layers.isEmpty else { return }
        let f = focusedIndex ?? focus
        let bounds = view.bounds
        let safe = view.safeAreaInsets
        for (i, layer) in layers.enumerated() {
            if layer === hidden { layer.view.isHidden = true; continue }
            let p = layout.placement(layerIndex: i, focusedIndex: f, bounds: bounds, safeArea: safe)
            layer.view.frame = p.cardFrame
            layer.view.layer.zPosition = p.z
            layer.view.alpha = p.cardAlpha
            layer.view.isHidden = p.cardAlpha <= 0.001
            layer.applyDepth(p.depth)
            layer.setChrome(role: p.role, alpha: p.chromeAlpha)
        }
    }

    // MARK: - Dive / pop

    private func pushLayer(url: URL, lineText: String?, from focused: RabbitHoleLayerViewController) {
        guard !transitionInFlight else { return }
        focused.setBottomLipText(lineText)

        // Hand the new layer its already-decoded content (if we preloaded this link) so
        // it renders synchronously — the "after" snapshot then shows the real article.
        let preloaded = preloadedContent[PreloadStore.key(for: url)]
        runTransition(applyState: { [weak self] in
            guard let self else { return }
            self.addLayer(RabbitHoleLayerDescriptor(urlString: url.absoluteString),
                          preloadedContent: preloaded)
            self.focus = self.topIndex
            self.applyFocus()
        }, completion: { [weak self] in
            self?.playHeaderEntrance()
            self?.persist()
            self?.warmPreloadsForFocusedLayer()
        })
    }

    /// Header back: pop one layer, or exit the reader entirely at the root.
    private func handleBack() {
        if topIndex == 0 {
            navigationController?.popViewController(animated: true)
        } else {
            popToLayer(topIndex - 1)
        }
    }

    private func popToLayer(_ index: Int) {
        guard !transitionInFlight, index >= 0, index < layers.count, index != topIndex else { return }
        runTransition(applyState: { [weak self] in
            guard let self else { return }
            self.trimLayers(above: index)
            self.focus = index
            self.applyFocus()
        }, completion: { [weak self] in
            self?.playHeaderEntrance()
            self?.persist()
            self?.warmPreloadsForFocusedLayer()
        })
    }

    private func trimLayers(above index: Int) {
        while layers.count - 1 > index {
            let dying = layers.removeLast()
            dying.willMove(toParent: nil)
            dying.view.removeFromSuperview()
            dying.removeFromParent()
        }
    }

    /// Drive a dive/pop wipe with ZERO perceived tap lag: the transition masks the
    /// screen with `before` immediately, then — hidden behind that mask, on the next
    /// runloop — runs `applyState` (the layer rebuild/relayout) and snapshots the
    /// result, and only then dissolves. So the expensive build never blocks the frame
    /// the user sees on tap. `afterScreenUpdates: false` keeps the snapshot cheap (the
    /// focused header is hidden first to avoid the missing-blur artifact, then animated
    /// back in by `playHeaderEntrance`).
    private func runTransition(applyState: @escaping () -> Void,
                               completion: @escaping () -> Void) {
        guard let transition else {   // no Metal → instant cut
            applyState(); view.layoutIfNeeded(); completion(); return
        }
        transitionInFlight = true
        transition.play(prepare: { [weak self] in
            guard let self else { return (UIImage(), UIImage()) }
            let before = self.snapshot(afterScreenUpdates: false)
            applyState()
            self.layers[safe: self.focus]?.prepareForTransitionSnapshot()
            self.view.layoutIfNeeded()
            let after = self.snapshot(afterScreenUpdates: false)
            return (before, after)
        }, in: view) { [weak self] in
            self?.transitionInFlight = false
            completion()
        }
    }

    private func playHeaderEntrance() { layers.last?.playHeaderEntrance() }

    private func snapshot(afterScreenUpdates: Bool) -> UIImage {
        UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: afterScreenUpdates)
        }
    }

    // MARK: - Overscroll-to-pop (interactive halftone wipe)

    @objc private func handleOverscrollPan(_ pan: UIPanGestureRecognizer) {
        guard layers.count > 1, !transitionInFlight,
              let focused = layers.last, let scroll = focused.contentScrollView else { return }
        let translation = pan.translation(in: view).y

        switch pan.state {
        case .began, .changed:
            if interactive == nil {
                let atTop = scroll.contentOffset.y <= -scroll.adjustedContentInset.top + 0.5
                let atBottom = scroll.contentOffset.y >= scroll.contentSize.height
                    - scroll.bounds.height + scroll.adjustedContentInset.bottom - 0.5
                if atTop, translation > 0 { beginOverscroll(scroll, edge: 1, baseline: translation) }
                else if atBottom, translation < 0 { beginOverscroll(scroll, edge: -1, baseline: translation) }
            }
            guard interactive != nil else { return }
            let raw = max((translation - overscrollBaseline) * overscrollEdge, 0)
            interactive?.update(progress: raw / (raw + 240))   // rubber-band resistance
        case .ended, .cancelled:
            guard let handle = interactive else { return }
            interactive = nil
            let raw = max((pan.translation(in: view).y - overscrollBaseline) * overscrollEdge, 0)
            let pull = raw / (raw + 240)
            let velocity = pan.velocity(in: view).y * overscrollEdge
            let committed = pull > 0.32 || velocity > 900
            endOverscroll()
            if committed {
                // Apply the pop now, hidden under the still-present overlay; the wipe
                // then settles to the after state and reveals it.
                trimLayers(above: topIndex - 1)
                focus = topIndex
                applyFocus()
                persist()
            }
            transitionInFlight = true
            handle.finish(committed: committed) { [weak self] in
                self?.transitionInFlight = false
                if committed {
                    self?.playHeaderEntrance()
                    self?.warmPreloadsForFocusedLayer()
                }
            }
        default:
            break
        }
    }

    private func beginOverscroll(_ scroll: UIScrollView, edge: CGFloat, baseline: CGFloat) {
        guard let transition, layers.count > 1 else { return }
        overscrollEdge = edge
        overscrollBaseline = baseline
        overscrollScroll = scroll
        scroll.isScrollEnabled = false   // we own the drag

        let before = snapshot(afterScreenUpdates: false)
        // Compose the after state (parent focused, top layer gone) hidden under the overlay.
        let dying = layers[topIndex]
        applyFocus(focusedIndex: topIndex - 1, hiding: dying)
        // Hide the parent's header for the snapshot (animated back in on commit), so the
        // capture is cheap (afterScreenUpdates: false) and free of the glass-blur artifact.
        layers[safe: topIndex - 1]?.prepareForTransitionSnapshot()
        view.layoutIfNeeded()
        let after = snapshot(afterScreenUpdates: false)
        applyFocus()                     // restore the live before state
        interactive = transition.begin(before: before, after: after, in: view)
    }

    private func endOverscroll() {
        overscrollScroll?.isScrollEnabled = true
        overscrollScroll = nil
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                  shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    // MARK: - Link preloading (materialize to disk + in-memory)

    /// Fully materialize the focused page's outbound links — text AND every image to
    /// disk, identical to a root save — and load their content into memory, so a dive
    /// into any of them is instant with zero fetch (see RabbitHolePreloader). Links are
    /// processed in document order (the top of the page is the likeliest next tap) at
    /// background priority; already-cached pages reuse the disk copy without refetching.
    /// The in-memory set is trimmed to the current focus's links to stay bounded, and
    /// any prior warm is cancelled when the focus changes. No-op until the focused layer
    /// has resolved to an article.
    private func warmPreloadsForFocusedLayer() {
        guard let focused = layers[safe: focus], focused.isArticle else { return }
        let urls = Array(focused.outboundLinkURLs.prefix(Self.maxPreloadedLinks))
        let wantedSet = Set(urls.map { PreloadStore.key(for: $0) })
        // Drop in-memory entries no longer reachable from the focused page.
        preloadedContent = preloadedContent.filter { wantedSet.contains($0.key) }
        let alreadyLoaded = Set(preloadedContent.keys)
        let rootID = rootItem.id

        warmTask?.cancel()
        warmTask = Task.detached(priority: .utility) { [weak self] in
            for url in urls {
                if Task.isCancelled { return }
                let key = PreloadStore.key(for: url)
                if alreadyLoaded.contains(key) { continue }
                guard let content = await RabbitHolePreloader.materialize(url: url, rootID: rootID)
                else { continue }
                if Task.isCancelled { return }
                await MainActor.run { [weak self] in
                    // Only keep it if the focus hasn't moved on to a different page.
                    guard let self, wantedSet.contains(key) else { return }
                    self.preloadedContent[key] = content
                }
            }
        }
    }

    // MARK: - Persistence

    @objc private func persist() {
        guard !layers.isEmpty else { return }
        for layer in layers { layer.syncScrollOffset() }
        stackStore.save(RabbitHoleStack(layers: layers.map { $0.descriptor }), forRootID: rootItem.id)
        if let root = layers.first {
            store.setLastScrollOffset(root.descriptor.scrollOffset, for: rootItem.id)
        }
    }

    private func markOpenedIfNeeded() {
        guard !didMarkOpened else { return }
        didMarkOpened = true
        store.markReadState(.opened, for: rootItem.id)
    }
}
