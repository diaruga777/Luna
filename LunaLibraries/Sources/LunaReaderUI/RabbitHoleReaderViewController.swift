//
//  RabbitHoleReaderViewController.swift
//  Luna
//
//  The full-screen reader a save opens into (built by ReaderHostFactory). The whole
//  reader is a persistent stack of "layers": layer 0 is the save; tapping a link pushes
//  a new focused layer on top, leaving previous layers as tappable lips (title on top,
//  the tapped line on the bottom) plus a leading indent — so you can rabbit-hole several
//  links deep without losing your place. The trail is persisted per save and restored on
//  next launch. Catch-Up embeds `ReaderViewController` directly; the SplitWebOverlay
//  inline reader is a separate surface.
//
//  Layers rest at integer focus positions (RabbitHoleLayout). Moving between two
//  positions (dive / pop / interactive overscroll) is rendered by an injected Dot Matrix
//  dot-matrix wipe (`RabbitHoleTransitioning`) over before/after snapshots — never by
//  moving the live cards, so there's no per-frame relayout.
//

import LunaDesignSystem
import LunaModels
import LunaStorage
import LunaTransitions
import UIKit

public final class RabbitHoleReaderViewController: UIViewController, UIGestureRecognizerDelegate {

    private let rootItem: ReadingListItem
    private let rootContent: ArticleContent
    private let shareProvider: ReaderShareProviding?
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
    /// Left-edge swipe that pops ONE layer interactively (or, at the root, lets the nav
    /// controller's own edge pan pop the whole reader).
    private var edgePopPan: UIScreenEdgePanGestureRecognizer?
    private var didMarkOpened = false

    /// In-memory article content for the focused layer's outbound links, keyed by the
    /// PreloadStore canonical key. Warmed (off-main, from the on-disk preload cache)
    /// whenever the focus settles, so tapping a link renders the new layer synchronously
    /// — the dive's "after" snapshot already shows the real article, and the wipe starts
    /// immediately. Trimmed to the current focus's links to stay bounded.
    private var preloadedContent: [String: ArticleContent] = [:]
    /// A single pre-created, blank layer shell parked offscreen (chrome already built),
    /// promoted on the next dive so tapping a link never builds a view controller. It
    /// deliberately carries no article content while scrolling; tapped content is applied
    /// only on activation so scroll never rotates/render-preps child VCs.
    private var spareLayer: RabbitHoleLayerViewController?
    /// The in-flight background materialization of the focused page's links (cancelled
    /// when the focus changes or the reader closes).
    private var warmTask: Task<Void, Never>?
    /// The focused page's outbound links in document order — the live, reprioritizable
    /// warm queue (tapping a link promotes it to the front; see `promote`).
    private var warmURLs: [URL] = []
    /// Cap on how many of a page's links we hold in memory at once.
    private static let maxPreloadedLinks = 80
    /// Owner id for this reader open's SPECULATIVE preloads — the pages one depth beyond
    /// `ReaderSettings.preloadDepth` that we materialize while reading. They're owned only
    /// by this session, so they're deleted when the reader is exited (see
    /// `viewDidDisappear`). Pages within the durable depth are owned by `rootItem.id` and
    /// persist.
    private let sessionID = UUID()

    public init(item: ReadingListItem, content: ArticleContent,
                shareProvider: ReaderShareProviding? = nil,
                transition: RabbitHoleTransitioning? = nil) {
        self.rootItem = item
        self.rootContent = content
        self.shareProvider = shareProvider
        self.transition = transition
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    /// The saved reading-list item this reader was opened for — how the
    /// window-level audio mini-player finds an already-open reader for the
    /// playing article in the nav stack (tap-to-return navigation).
    public var rootItemID: UUID { rootItem.id }

    /// Whether the article playing under `itemID` is embedded anywhere in this
    /// reader's layer trail (the root, or a dived-into page — saved pages play
    /// under their real store id, unsaved ones under a URL-seeded transient id).
    public func containsReaderItem(withID itemID: UUID) -> Bool {
        rootItem.id == itemID || layers.contains { $0.embeddedReaderItemID == itemID }
    }

    deinit {
        warmTask?.cancel()
        // Backstop: ensure this session's speculative (+1 depth) preloads are released even
        // if `viewDidDisappear` didn't run. Idempotent with the timely release there.
        PreloadStore.shared.releaseTree(rootID: sessionID)
    }

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ReaderDepth.backgroundColor(for: 0)
        navigationItem.largeTitleDisplayMode = .never

        buildInitialStack()
        // Park the Metal overlay now so the first dive doesn't pay its setup cost mid-tap.
        transition?.prewarm(in: view)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleOverscrollPan(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)
        overscrollPan = pan

        // Left-edge swipe pops one layer (back to the previous page in the trail). At the
        // root layer it refuses to begin so the nav controller's edge pan exits the reader.
        let edge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgePopPan(_:)))
        edge.edges = .left
        edge.delegate = self
        view.addGestureRecognizer(edge)
        edgePopPan = edge

        NotificationCenter.default.addObserver(
            self, selector: #selector(persist),
            name: UIApplication.didEnterBackgroundNotification, object: nil)

        addSimulatorDiveHooksIfNeeded()
    }

    /// Sim-only alternative tap targets for the dive/pop transitions: the automation
    /// harness can't tap text-view link glyphs (see claudedocs/simulator-testing.md),
    /// so these buttons drive the same `pushLayer`/`popToLayer` paths a link tap and
    /// the header back button use. Never ships on device.
    private func addSimulatorDiveHooksIfNeeded() {
        #if targetEnvironment(simulator)
        // Suppressed during deterministic UI-test launches (matches UITestLaunch.isActive,
        // which lives in the app target — inlined here to avoid an upward dependency).
        let uiTestArgs = ["-uiTestState", "-uiTestScreen", "-uiTestOnboardingStep"]
        if ProcessInfo.processInfo.arguments.contains(where: uiTestArgs.contains) { return }
        func hookButton(_ title: String, action: @escaping () -> Void) -> UIButton {
            var config = UIButton.Configuration.filled()
            config.title = title
            config.baseBackgroundColor = .systemPurple
            let button = UIButton(configuration: config)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.layer.zPosition = 500   // above the layer cards, below the wipe overlay
            button.addAction(UIAction { _ in action() }, for: .touchUpInside)
            view.addSubview(button)
            return button
        }
        let dive = hookButton("Sim Dive") { [weak self] in
            guard let self, let focused = self.layers[safe: self.focus],
                  let url = URL(string: "https://en.wikipedia.org/wiki/Swift_(programming_language)")
            else { return }
            self.pushLayer(url: url, lineText: "Sim Dive", from: focused)
        }
        let pop = hookButton("Sim Pop") { [weak self] in
            guard let self, self.topIndex > 0 else { return }
            self.popToLayer(self.topIndex - 1)
        }
        NSLayoutConstraint.activate([
            dive.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            dive.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -24),
            pop.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            pop.topAnchor.constraint(equalTo: dive.bottomAnchor, constant: 12),
        ])
        #endif
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The reader's own entry (push) animation has finished — let the focused (root)
        // layer's embedded reader run its progressive-load Phase 2 now, aligned with the
        // open animation. Idempotent; the embedded reader also self-triggers as a backstop.
        if let coordinator = transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                guard let self else { return }
                self.layers[safe: self.focus]?.entryAnimationDidFinish()
            }
        } else {
            layers[safe: focus]?.entryAnimationDidFinish()
        }
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // This reader draws its own per-layer (de-glassed) header, so the shared nav bar must
        // be hidden. Assert it on every appear (not just viewDidLoad) — the custom
        // Dot Matrix push runs viewWillAppear, and re-asserting here also clears any
        // leftover transform/alpha so a later restore lands on a clean bar.
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyFocus()
        if let spareLayer {
            parkInactiveLayerOffscreen(spareLayer, zPosition: -200)
        }
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        persist()
        // Hand the shared nav bar back to whatever screen we're returning to: restore it
        // (and clear any leftover mutation) on the way out so the reading list — which
        // shares this bar — comes back with its full header. The destination also
        // re-asserts its own state in viewWillAppear; this is the belt to that suspenders.
        if isMovingFromParent || isBeingDismissed, let nav = navigationController {
            nav.navigationBar.transform = .identity
            nav.navigationBar.alpha = 1
            nav.setNavigationBarHidden(false, animated: false)
            // If this is a CANCELLABLE interactive pop (edge-swipe) and it gets
            // cancelled, the reader stays but we already showed the shared bar above —
            // re-hide it explicitly instead of relying on UIKit re-firing viewWillAppear.
            transitionCoordinator?.notifyWhenInteractionChanges { [weak self] ctx in
                guard ctx.isCancelled else { return }
                self?.navigationController?.setNavigationBarHidden(true, animated: false)
            }
        }
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Exiting the reader (popped/dismissed back to the reading list): the speculative
        // pages we materialized one depth beyond the setting are temporary — release this
        // session's ownership so any page no other save/session still owns is deleted (its
        // images too, via the image refcount). Within-depth pages keep the durable item id.
        guard isMovingFromParent || isBeingDismissed else { return }
        warmTask?.cancel()
        let session = sessionID
        Task.detached(priority: .utility) {
            PreloadStore.shared.releaseTree(rootID: session)
        }
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
        ensureSpareLayer()   // pre-build the next layer so the first dive has nothing to build
    }

    private func rootDescriptor() -> RabbitHoleLayerDescriptor {
        RabbitHoleLayerDescriptor(
            urlString: rootItem.urlString,
            wordIndex: rootItem.lastWordIndex,
            scrollOffset: rootItem.lastScrollOffset,
            originalScrollOffset: rootItem.lastOriginalScrollOffset ?? 0,
            readerMode: rootItem.lastReaderMode ?? .scroll,
            title: rootItem.title ?? rootContent.title,
            bottomLipText: nil)
    }

    /// Promote a pre-created blank shell into a real, content-loaded layer and append it
    /// to the stack. The shell already exists in the hierarchy (chrome built) — diving
    /// only sets its content here and its frame via `applyFocus`, never builds a VC.
    @discardableResult
    private func addLayer(_ descriptor: RabbitHoleLayerDescriptor,
                          preloadedContent: ArticleContent? = nil) -> RabbitHoleLayerViewController {
        let layer = takeSpareLayer()
        layer.configure(descriptor: descriptor, preloadedContent: preloadedContent)
        layers.append(layer)
        return layer
    }

    /// Build a BLANK layer shell, wire its callbacks, and add it to the hierarchy so its
    /// view loads and chrome (incl. the header) is built now — off the tap path.
    private func makeLayerShell() -> RabbitHoleLayerViewController {
        let layer = RabbitHoleLayerViewController(
            shareProvider: shareProvider, layout: layout)
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
        view.addSubview(layer.view)   // loads the view → builds chrome immediately
        layer.didMove(toParent: self)
        return layer
    }

    /// Pre-create the next layer shell offscreen so a dive has nothing to build.
    /// Built on a later runloop so it never hitches a just-finished transition; if a dive
    /// beats it, `takeSpareLayer` falls back to building one synchronously.
    private func ensureSpareLayer() {
        guard spareLayer == nil, isViewLoaded else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.spareLayer == nil, self.isViewLoaded else { return }
            let layer = self.makeLayerShell()
            self.parkInactiveLayerOffscreen(layer, zPosition: -200)
            self.spareLayer = layer
        }
    }

    /// The ready-and-waiting blank shell (created offscreen ahead of time), or a fresh
    /// one if the spare wasn't ready yet.
    private func takeSpareLayer() -> RabbitHoleLayerViewController {
        if let spare = spareLayer {
            spareLayer = nil
            return spare
        }
        return makeLayerShell()
    }

    // MARK: - Static placement (the only writer of layer frames)

    private func applyFocus(focusedIndex: Int? = nil, hiding hidden: RabbitHoleLayerViewController? = nil) {
        guard !layers.isEmpty else { return }
        let f = focusedIndex ?? focus
        let bounds = view.bounds
        let safe = view.safeAreaInsets
        for (i, layer) in layers.enumerated() {
            if layer === hidden {
                parkInactiveLayerOffscreen(layer, zPosition: layer.view.layer.zPosition)
                continue
            }
            let p = layout.placement(layerIndex: i, focusedIndex: f, bounds: bounds, safeArea: safe)
            layer.view.frame = p.cardFrame
            layer.view.layer.zPosition = p.z
            layer.view.alpha = p.cardAlpha
            layer.applyDepth(p.depth)
            layer.setChrome(role: p.role, alpha: p.chromeAlpha)
        }
    }

    // MARK: - Changed-region diffing (UIView-level, never pixel-by-pixel)

    /// The layer placements for a hypothetical (focus, layerCount) arrangement, as
    /// changed-region `Item`s keyed by layer index. The opaque `state` token folds in the
    /// role and whole-card alpha so a layer that merely changes role (e.g. focused →
    /// ancestor) is still treated as changed even when its frame is unchanged.
    private func placementItems(focus f: Int, layerCount n: Int) -> [DotMatrixRegion.Item] {
        guard n > 0 else { return [] }
        let bounds = view.bounds
        let safe = view.safeAreaInsets
        return (0..<n).map { i in
            let p = layout.placement(layerIndex: i, focusedIndex: f, bounds: bounds, safeArea: safe)
            // role + a coarse alpha bucket (hidden vs shown) form the non-geometric token.
            let token = "\(p.role)|\(p.cardAlpha > 0.001)"
            return DotMatrixRegion.Item(id: i, frame: p.cardFrame, state: token)
        }
    }

    /// The screen region that actually changes moving from one (focus, layerCount) to
    /// another — the union of the frames of every layer whose frame OR role/visibility
    /// changed (plus any added/removed layer). Genuinely-unchanged layers (e.g. the
    /// layer-0 lip on a layer-2 push/pop) are excluded so they never pixelate.
    /// Returns nil ⇒ wipe the whole screen (full change, or region == full bounds).
    private func changedRegion(fromFocus: Int, fromCount: Int,
                               toFocus: Int, toCount: Int) -> CGRect? {
        let before = placementItems(focus: fromFocus, layerCount: fromCount)
        let after = placementItems(focus: toFocus, layerCount: toCount)
        guard let region = DotMatrixRegion.changedRegion(before: before, after: after, in: view.bounds),
              !DotMatrixRegion.isFullScreen(region, bounds: view.bounds) else { return nil }
        return region
    }

    /// The CONTENT area (the card below its floating header) of the layer that will
    /// be focused once the transition lands, at its final placement — the only part of
    /// the screen the wipe pixelates. Header/lip/card chrome inside the changed region
    /// crossfades instead (see `RabbitHoleTransitioning`'s `contentRegion`).
    private func destinationContentRegion(focus f: Int) -> CGRect {
        let p = layout.placement(layerIndex: f, focusedIndex: f,
                                 bounds: view.bounds, safeArea: view.safeAreaInsets)
        let content = RabbitHoleLayerViewController.contentWipeRegion(
            in: CGRect(origin: .zero, size: p.cardFrame.size))
        return content.offsetBy(dx: p.cardFrame.minX, dy: p.cardFrame.minY).integral
    }

    // MARK: - Dive / pop

    private func pushLayer(url: URL, lineText: String?, from focused: RabbitHoleLayerViewController) {
        guard !transitionInFlight else { return }
        focused.setBottomLipText(lineText)

        // Tapped link → front of the preload queue, materialized now (req: instant + durable).
        promote(url)

        // Hand the new layer its already-decoded content (if we preloaded this link) so
        // it renders synchronously — the "after" snapshot then shows the real article.
        let key = PreloadStore.key(for: url)
        let preloaded = preloadedContent[key]
            ?? PreloadStore.shared.synchronousArticleContent(for: url)
        if let preloaded, preloadedContent[key] == nil {
            preloadedContent[key] = preloaded
        }
        // Diving: focus f→f+1, one layer appended. Unchanged layers (e.g. the layer-0
        // lip on a depth-2 push) are excluded so they stay perfectly static.
        let region = changedRegion(fromFocus: focus, fromCount: layers.count,
                                   toFocus: focus + 1, toCount: layers.count + 1)
        runTransition(region: region,
                      contentRegion: destinationContentRegion(focus: focus + 1),
                      applyState: { [weak self] in
            guard let self else { return }
            self.addLayer(RabbitHoleLayerDescriptor(urlString: url.absoluteString),
                          preloadedContent: preloaded)
            self.focus = self.topIndex
            self.applyFocus()
        }, completion: { [weak self] in
            guard let self else { return }
            self.persist()
            self.warmPreloadsForFocusedLayer()
            self.ensureSpareLayer()   // this dive consumed the spare — rebuild the next one
            // Dive wipe done: let the now-focused layer's reader swap in its full content.
            self.layers[safe: self.focus]?.entryAnimationDidFinish()
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
        // Popping: focus topIndex→index, layers above `index` removed. Unchanged
        // ancestor lips are excluded from the wipe.
        let region = changedRegion(fromFocus: focus, fromCount: layers.count,
                                   toFocus: index, toCount: index + 1)
        runTransition(region: region,
                      contentRegion: destinationContentRegion(focus: index),
                      applyState: { [weak self] in
            guard let self else { return }
            self.trimLayers(above: index)
            self.focus = index
            self.applyFocus()
        }, completion: { [weak self] in
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
    /// the user sees on tap.
    /// `region` (in `view`'s coordinate space, nil ⇒ full bounds) confines the wipe to
    /// just the changed area: the overlay and both snapshots cover only that sub-rect, so
    /// unchanged regions (e.g. the layer-0 lip) keep their live views and never pixelate.
    private func runTransition(region: CGRect? = nil,
                               contentRegion: CGRect? = nil,
                               applyState: @escaping () -> Void,
                               completion: @escaping () -> Void) {
        guard let transition else {   // no Metal → instant cut
            applyState(); view.layoutIfNeeded(); completion(); return
        }
        transitionInFlight = true
        transition.play(prepare: { [weak self] in
            guard let self else { return (UIImage(), UIImage()) }
            // `before` is already-displayed content → afterScreenUpdates:false is correct
            // and cheap. `after` is captured after applying state and forcing layout, so it
            // can use the current hierarchy without asking UIKit to flush screen updates
            // during a CoreAnimation commit.
            // The focused header is left VISIBLE in the after capture, so the dissolve resolves straight to the
            // final header — there's no headerless frame to blink before it reappears.
            // When `region` is set both snapshots are that-rect-sized so they align to the
            // region-framed overlay.
            let before = self.snapshot(region: region, afterScreenUpdates: false)
            applyState()
            self.view.layoutIfNeeded()
            let after = self.snapshot(region: region, afterScreenUpdates: false)
            return (before, after)
        }, in: view, region: region, contentRegion: contentRegion) { [weak self] in
            self?.transitionInFlight = false
            completion()
        }
    }

    /// Snapshot the whole view (region nil) or just `region` (in `view`'s coordinate
    /// space). For a region the hierarchy is drawn through a translated context so the
    /// captured pixels line up exactly with that sub-rect — matching the region-framed
    /// overlay so the before/after textures register.
    private func snapshot(region: CGRect? = nil, afterScreenUpdates: Bool) -> UIImage {
        let rect = (region ?? view.bounds).intersection(view.bounds)
        guard rect.width > 1, rect.height > 1 else {
            return UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
                view.drawHierarchy(in: view.bounds, afterScreenUpdates: afterScreenUpdates)
            }
        }
        return UIGraphicsImageRenderer(bounds: CGRect(origin: .zero, size: rect.size)).image { ctx in
            ctx.cgContext.translateBy(x: -rect.origin.x, y: -rect.origin.y)
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: afterScreenUpdates)
        }
    }

    // MARK: - Overscroll-to-pop (interactive Dot Matrix wipe)

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
            // Only a RELEASED gesture commits — a system-cancelled one (incoming
            // call, interruption) must settle back, same as the edge-pop twin.
            let committed = pan.state == .ended && (pull > 0.32 || velocity > 900)
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

        // Popping one layer: focus topIndex→topIndex-1, top layer removed. Confine the
        // wipe to the changed area so unchanged ancestor lips never pixelate.
        let region = changedRegion(fromFocus: topIndex, fromCount: layers.count,
                                   toFocus: topIndex - 1, toCount: topIndex)
        let before = snapshot(region: region, afterScreenUpdates: false)
        // Compose the after state (parent focused, top layer gone) hidden under the overlay.
        let dying = layers[topIndex]
        applyFocus(focusedIndex: topIndex - 1, hiding: dying)
        // The parent's header stays VISIBLE in the after capture, so as the finger drives the wipe the header
        // dissolves in proportionally along with the rest of the content — instead of being
        // absent and snapping in only on commit.
        view.layoutIfNeeded()
        let after = snapshot(region: region, afterScreenUpdates: false)
        applyFocus()                     // restore the live before state
        interactive = transition.begin(before: before, after: after, in: view, region: region,
                                       contentRegion: destinationContentRegion(focus: topIndex - 1))
    }

    private func endOverscroll() {
        overscrollScroll?.isScrollEnabled = true
        overscrollScroll = nil
    }

    // MARK: - Left-edge-swipe-to-pop-one-layer (interactive Dot Matrix wipe)

    /// Width used to normalise the edge drag into a 0…1 fraction (set on .began).
    private var edgePopWidth: CGFloat = 1

    @objc private func handleEdgePopPan(_ pan: UIScreenEdgePanGestureRecognizer) {
        // Only meaningful above the root; at the root the gesture refuses to begin (see
        // gestureRecognizerShouldBegin) so the nav controller exits the reader instead.
        guard topIndex > 0 else { return }

        switch pan.state {
        case .began:
            guard !transitionInFlight, interactive == nil else { return }
            edgePopWidth = max(view.bounds.width, 1)
            beginEdgePop()
            interactive?.update(progress: 0)
        case .changed:
            interactive?.update(progress: max(pan.translation(in: view).x, 0) / edgePopWidth)
        case .ended, .cancelled, .failed:
            guard let handle = interactive else { return }
            interactive = nil
            let fraction = max(pan.translation(in: view).x, 0) / edgePopWidth
            let velocity = pan.velocity(in: view).x
            let committed = pan.state == .ended && (fraction > 0.4 || velocity > 800)
            if committed {
                // Apply the one-layer pop now, hidden under the overlay; the wipe then
                // settles to the after state and reveals it.
                trimLayers(above: topIndex - 1)
                focus = topIndex
                applyFocus()
                persist()
            }
            transitionInFlight = true
            handle.finish(committed: committed) { [weak self] in
                self?.transitionInFlight = false
                if committed {
                    self?.warmPreloadsForFocusedLayer()
                }
            }
        default:
            break
        }
    }

    /// Compose the "pop one layer" before/after snapshots and start the interactive wipe —
    /// the horizontal-drag analogue of `beginOverscroll`, popping the top layer to its parent.
    private func beginEdgePop() {
        guard let transition, layers.count > 1 else { return }
        // Popping one layer (focus topIndex→topIndex-1) — confine the wipe to the changed
        // area so unchanged ancestor lips stay static.
        let region = changedRegion(fromFocus: topIndex, fromCount: layers.count,
                                   toFocus: topIndex - 1, toCount: topIndex)
        let before = snapshot(region: region, afterScreenUpdates: false)
        let dying = layers[topIndex]
        applyFocus(focusedIndex: topIndex - 1, hiding: dying)
        // Keep the parent's header in the after capture so it tracks the interactive edge
        // swipe (dissolving in proportionally) rather than snapping in only on commit.
        view.layoutIfNeeded()
        let after = snapshot(region: region, afterScreenUpdates: false)
        applyFocus()   // restore the live before state
        interactive = transition.begin(before: before, after: after, in: view, region: region,
                                       contentRegion: destinationContentRegion(focus: topIndex - 1))
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                  shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // The edge-pop pan must NOT run together with the overscroll pan.
        if gestureRecognizer === edgePopPan || other === edgePopPan { return false }
        return true
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // The left-edge pop only owns the swipe when there's a layer to pop to; at the root
        // it steps aside so the nav controller's edge pan exits the reader.
        if gestureRecognizer === edgePopPan {
            return topIndex > 0 && !transitionInFlight && interactive == nil
        }
        return true
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
        guard let focused = layers[safe: focus], focused.isArticle else {
            warmURLs = []
            warmTask?.cancel()
            return
        }
        warmURLs = Array(focused.outboundLinkURLs.prefix(Self.maxPreloadedLinks))
        let wantedSet = Set(warmURLs.map { PreloadStore.key(for: $0) })
        // Drop in-memory entries no longer reachable from the focused page.
        preloadedContent = preloadedContent.filter { wantedSet.contains($0.key) }
        runWarm()
    }

    private func parkInactiveLayerOffscreen(_ layer: RabbitHoleLayerViewController,
                                            zPosition: CGFloat) {
        let width = max(view.bounds.width, 1)
        let height = max(view.bounds.height, 1)
        layer.view.frame = CGRect(x: -width - 32, y: 0, width: width, height: height)
        layer.view.alpha = 0
        layer.view.layer.zPosition = zPosition
    }

    /// (Re)start the background drain of `warmURLs` in order. Restarting is cheap: an
    /// already-materialized page short-circuits in `materialize`. The materialized pages
    /// one level beyond `preloadDepth` are owned by `sessionID` (temporary — cleaned up on
    /// exit); within-depth pages keep the durable `rootItem.id`.
    private func runWarm() {
        let urls = warmURLs
        guard !urls.isEmpty else { warmTask?.cancel(); return }
        let wantedSet = Set(urls.map { PreloadStore.key(for: $0) })
        let alreadyLoaded = Set(preloadedContent.keys)
        let owner = preloadOwnerForFocusedLinks()

        warmTask?.cancel()
        warmTask = Task.detached(priority: .utility) { [weak self] in
            for url in urls {
                if Task.isCancelled { return }
                let key = PreloadStore.key(for: url)
                if alreadyLoaded.contains(key) { continue }
                guard let content = await RabbitHolePreloader.materialize(url: url, owner: owner)
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

    /// The owner for pages reachable from the focused layer (one level deeper than it):
    /// durable (`rootItem.id`) when that depth is within the preload-depth setting, else
    /// the temporary `sessionID`.
    private func preloadOwnerForFocusedLinks() -> UUID {
        (focus + 1 <= ReaderSettings.preloadDepth) ? rootItem.id : sessionID
    }

    /// A tapped link jumps to the front of the preload queue and is materialized
    /// immediately on an independent high-priority task, so it (and its images) lands on
    /// disk even though the focus — and the cancellable warm task — is about to move to the
    /// new layer.
    private func promote(_ url: URL) {
        let key = PreloadStore.key(for: url)
        if let idx = warmURLs.firstIndex(where: { PreloadStore.key(for: $0) == key }), idx != 0 {
            warmURLs.insert(warmURLs.remove(at: idx), at: 0)
        }
        let owner = preloadOwnerForFocusedLinks()
        Task.detached(priority: .userInitiated) {
            _ = await RabbitHolePreloader.materialize(url: url, owner: owner)
        }
    }

    // MARK: - Persistence

    @objc private func persist() {
        guard !layers.isEmpty else { return }
        for layer in layers { layer.syncReadingPosition() }
        stackStore.save(RabbitHoleStack(layers: layers.map { $0.descriptor }), forRootID: rootItem.id)
        if let root = layers.first {
            // Mirror the root layer's shared reading position (word + exact pixels, the
            // pixels cleared when RSVP owns it) and its disjoint archive offset onto the
            // durable item, so a plain reopen restores both consistently.
            let d = root.descriptor
            store.saveReaderExitPosition(
                scrollOffset: d.scrollOffset,
                clearScrollOffset: d.scrollOffset == nil,
                lastWordIndex: d.wordIndex,
                lastOriginalScrollOffset: d.originalScrollOffset,
                for: rootItem.id)
            // Persist the root's reader mode onto the durable item too. The stack file
            // isn't enough: `RabbitHoleStackStore.save` DELETES a single-layer (undived)
            // trail, so a plain read that only switched mode would lose it. Writing it to
            // the item makes `rootDescriptor()` (rootItem.lastReaderMode) restore it.
            store.setReaderMode(root.descriptor.readerMode, for: rootItem.id)
        }
    }

    private func markOpenedIfNeeded() {
        guard !didMarkOpened else { return }
        didMarkOpened = true
        store.markReadState(.opened, for: rootItem.id)
    }
}
