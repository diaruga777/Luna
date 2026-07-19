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
//  Layers rest at integer focus positions (RabbitHoleLayout).
//

import LunaDesignSystem
import LunaModels
import LunaStorage
import UIKit

/// Snapshot of the focused layer's chrome (modes, audio, save/share, back) for
/// hosts that render the reader's controls OUTSIDE the reader — the Reader card
/// carousel's screen-level pill row (`providesOwnChrome = false`).
public struct ReaderChromeState: Equatable {
    public var isArticle: Bool
    public var modes: [ReadingListItem.ReaderMode]
    public var selectedMode: ReadingListItem.ReaderMode
    public var isAudioOn: Bool
    /// True when a layer is stacked above the root (back pops one layer).
    public var showsBack: Bool
    public var offersSaveShare: Bool
    public var isSaved: Bool
}

/// A reader whose controls are rendered by a stable host view. Both the root
/// rabbit-hole reader and an inline reader conform, so the host can retarget the
/// same buttons without replacing or moving them when a link opens.
public protocol ReaderChromeControlling: AnyObject {
    var chromeState: ReaderChromeState? { get }
    func chromeSetMode(_ mode: ReadingListItem.ReaderMode)
    func chromeToggleAudio()
    func chromeSave()
    func chromeShare(from sourceView: UIView)
    func chromeBack()
}

public final class RabbitHoleReaderViewController: UIViewController, UIGestureRecognizerDelegate,
    ReaderChromeControlling {

    private let rootItem: ReadingListItem
    private let rootContent: ArticleContent
    private let shareProvider: ReaderShareProviding?
    private let store = ReadingListStore.shared
    private let stackStore = RabbitHoleStackStore.shared
    private var layout = RabbitHoleLayout()

    private var layers: [RabbitHoleLayerViewController] = []
    /// Focused-layer index (0 = root). Layers always rest at this integer focus.
    private var focus: Int = 0
    private var topIndex: Int { max(layers.count - 1, 0) }

    private var overscrollPan: UIPanGestureRecognizer?
    /// Left-edge swipe that pops one layer (or, at the root, lets the nav
    /// controller's own edge pan pop the whole reader).
    private var edgePopPan: UIScreenEdgePanGestureRecognizer?
    private var didMarkOpened = false

    public init(item: ReadingListItem, content: ArticleContent,
                shareProvider: ReaderShareProviding? = nil) {
        self.rootItem = item
        self.rootContent = content
        self.shareProvider = shareProvider
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

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ReaderDepth.backgroundColor(for: 0)
        navigationItem.largeTitleDisplayMode = .never

        buildInitialStack()
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

    /// Sim-only alternative tap targets for dive/pop: the automation
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
            button.layer.zPosition = 500
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

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // This reader draws its own per-layer floating header pills, so the shared nav bar
        // must be hidden. Assert it on every appearance.
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyFocus()
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
            transitionCoordinator?.notifyWhenInteractionChanges { [weak self] ctx in
                guard ctx.isCancelled else { return }
                self?.navigationController?.setNavigationBarHidden(true, animated: false)
            }
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
            _ = addLayer(descriptor, knownContent: i == 0 ? rootContent : nil)
        }
        focus = topIndex
        applyFocus()
        markOpenedIfNeeded()
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

    @discardableResult
    private func addLayer(_ descriptor: RabbitHoleLayerDescriptor,
                          knownContent: ArticleContent? = nil) -> RabbitHoleLayerViewController {
        let layer = makeLayer()
        layer.configure(descriptor: descriptor, knownContent: knownContent)
        layers.append(layer)
        return layer
    }

    private func makeLayer() -> RabbitHoleLayerViewController {
        let layer = RabbitHoleLayerViewController(
            shareProvider: shareProvider, layout: layout)
        layer.rendersFullContentUpFront = rendersFullContentUpFront
        layer.showsHeaderChrome = providesOwnChrome
        layer.externalChromeContentInset = externalChromeContentInset
        layer.onLinkActivated = { [weak self, weak layer] url, lineText in
            guard let self, let layer, layer === self.layers.last else { return }
            self.pushLayer(url: url, lineText: lineText, from: layer)
        }
        layer.onLinkActivatedAtPoint = { [weak self, weak layer] url, lineText, point in
            guard let self, let layer, layer === self.layers.last else { return }
            if self.presentsLinksAsInlineReaders {
                self.presentInlineReader(
                    url: url, lineText: lineText, sourcePoint: point, from: layer)
            } else {
                self.pushLayer(url: url, lineText: lineText, from: layer)
            }
        }
        layer.onPopToHere = { [weak self, weak layer] in
            guard let self, let layer, let index = self.layers.firstIndex(where: { $0 === layer })
            else { return }
            self.popToLayer(index)
        }
        layer.onModeChanged = { [weak self] _ in
            self?.persist()
            self?.onContentHierarchyChanged?()
        }
        layer.onBecameArticle = { [weak self] in self?.onContentHierarchyChanged?() }
        layer.onBack = { [weak self] in self?.handleBack() }
        addChild(layer)
        view.addSubview(layer.view)
        layer.didMove(toParent: self)
        return layer
    }

    /// Fired whenever the live reader hierarchy changes shape — a layer's
    /// article embeds, the mode switches, a dive pushes a layer, or a pop
    /// removes one. Embedding hosts (the Reader card carousel) re-sweep the
    /// hierarchy for scroll views / RSVP controllers to observe.
    public var onContentHierarchyChanged: (() -> Void)?

    // MARK: - Static placement (the only writer of layer frames)

    private func applyFocus() {
        guard !layers.isEmpty else { return }
        let bounds = view.bounds
        let safe = view.safeAreaInsets
        for (i, layer) in layers.enumerated() {
            let p = layout.placement(layerIndex: i, focusedIndex: focus, bounds: bounds, safeArea: safe)
            layer.view.frame = p.cardFrame
            layer.view.layer.zPosition = p.z
            layer.view.alpha = p.cardAlpha
            layer.applyDepth(p.depth)
            layer.setChrome(role: p.role, alpha: p.chromeAlpha)
            // The root layer of an embedded reader (carousel card, onRootBack
            // set) has nothing to pop to — no back pill. Deeper layers and
            // pushed fullscreen readers keep theirs.
            layer.setBackButtonHidden(i == 0 && onRootBack != nil)
        }
    }

    // MARK: - Dive / pop

    private func pushLayer(url: URL, lineText: String?, from focused: RabbitHoleLayerViewController) {
        focused.setBottomLipText(lineText)
        addLayer(RabbitHoleLayerDescriptor(urlString: url.absoluteString))
        focus = topIndex
        applyFocus()
        persist()
        onContentHierarchyChanged?()
    }

    private func presentInlineReader(
        url: URL,
        lineText: String?,
        sourcePoint: CGPoint,
        from focused: RabbitHoleLayerViewController
    ) {
        guard presentedViewController == nil else { return }
        focused.setBottomLipText(lineText)
        let pointInReader = focused.view.convert(sourcePoint, to: view)
        let pointInWindow = view.convert(pointInReader, to: nil)
        let coordinator = inlineReaderPresentationCoordinator
        let overlay = SplitWebOverlayViewController(
            url: url,
            shareProvider: shareProvider,
            lineHeight: 0,
            cutY: pointInWindow.y,
            topHalf: nil,
            bottomHalf: nil,
            sourcePoint: pointInWindow,
            outerURL: focused.descriptor.url ?? url,
            outerTitle: focused.descriptor.title,
            contentTop: coordinator?.inlineReaderTopEdgeInWindow ?? 0)
        overlay.onOpen = { [weak coordinator, weak overlay] in
            guard let overlay else { return }
            coordinator?.inlineReaderWillPresent(overlay)
        }
        overlay.onChromeStateChanged = { [weak coordinator, weak overlay] in
            guard let overlay else { return }
            coordinator?.inlineReaderWillPresent(overlay)
        }
        overlay.onDismiss = { [weak coordinator, weak overlay] in
            guard let overlay else { return }
            coordinator?.inlineReaderDidDismiss(overlay)
        }
        present(overlay, animated: true)
    }

    private var inlineReaderPresentationCoordinator: InlineReaderPresentationCoordinating? {
        var ancestor = parent
        while let controller = ancestor {
            if let coordinator = controller as? InlineReaderPresentationCoordinating {
                return coordinator
            }
            ancestor = controller.parent
        }
        return nil
    }

    /// When set, the reader is embedded outside a push (the Reader card
    /// carousel) and the root layer has nothing to pop to: its back pill is
    /// hidden (re-applied via applyFocus, which reads this).
    public var onRootBack: (() -> Void)? {
        didSet { if isViewLoaded { applyFocus() } }
    }

    /// Render every layer's WHOLE article up front instead of the Phase-1 prefix
    /// + deferred Phase-2 swap. For permanently-embedding hosts (carousel cards):
    /// the card's initial state IS its final state — no post-embed content swap,
    /// no relayout when the card is focused. Set before the view loads.
    public var rendersFullContentUpFront = false

    /// Embedded card readers open links in the dedicated eclipse overlay rather
    /// than adding another in-card rabbit-hole layer.
    public var presentsLinksAsInlineReaders = false

    /// Whether layers draw their own in-card header pills. Hosts that render the
    /// chrome externally (the Reader carousel's screen-level pill row) set this
    /// false BEFORE the view loads and drive the reader through `chromeState` +
    /// the `chrome*` methods below; `onContentHierarchyChanged` fires whenever
    /// the state may have changed (dive, pop, mode switch, article embed).
    public var providesOwnChrome = true

    /// Screen-hosted chrome occlusion measured in this reader's coordinates.
    /// The scroll reader reserves it at rest, but its content continues behind
    /// the host's backdrop blur as the user scrolls.
    public var externalChromeContentInset: CGFloat = 0 {
        didSet {
            guard abs(externalChromeContentInset - oldValue) > 0.5 else { return }
            for layer in layers { layer.externalChromeContentInset = externalChromeContentInset }
        }
    }

    /// The live scroll surface of the focused layer, or nil when it has none
    /// (RSVP). A host that draws its own scroll indicator tracks this and
    /// retargets it whenever `onContentHierarchyChanged` fires (dive, pop, mode
    /// switch, article embed) — the focused layer, and thus its scroll view,
    /// changes across those.
    public var focusedContentScrollView: UIScrollView? { layers[safe: focus]?.contentScrollView }

    // MARK: - External chrome (host-rendered header pills)

    /// The focused layer's chrome state, or nil before any layer exists.
    public var chromeState: ReaderChromeState? {
        guard let layer = layers[safe: focus] else { return nil }
        return ReaderChromeState(
            isArticle: layer.isArticle,
            modes: layer.availableModes,
            selectedMode: layer.readerMode,
            isAudioOn: layer.isAudioOn,
            showsBack: topIndex > 0,
            offersSaveShare: layer.offersSaveShare,
            isSaved: layer.isSavedInLibrary)
    }

    public func chromeSetMode(_ mode: ReadingListItem.ReaderMode) {
        layers[safe: focus]?.setMode(mode)
    }

    public func chromeToggleAudio() {
        layers[safe: focus]?.toggleAudio()
    }

    public func chromeSave() {
        layers[safe: focus]?.performSave()
    }

    public func chromeShare(from sourceView: UIView) {
        layers[safe: focus]?.performShare(from: sourceView)
    }

    /// Pop one layer (the external back pill; shown only above the root).
    public func chromeBack() {
        guard topIndex > 0 else { return }
        popToLayer(topIndex - 1)
    }

    /// Header back: pop one layer, or exit the reader entirely at the root.
    private func handleBack() {
        if topIndex == 0 {
            if let onRootBack {
                onRootBack()
            } else {
                navigationController?.popViewController(animated: true)
            }
        } else {
            popToLayer(topIndex - 1)
        }
    }

    private func popToLayer(_ index: Int) {
        guard index >= 0, index < layers.count, index != topIndex else { return }
        trimLayers(above: index)
        focus = index
        applyFocus()
        persist()
        onContentHierarchyChanged?()
    }

    private func trimLayers(above index: Int) {
        while layers.count - 1 > index {
            let dying = layers.removeLast()
            dying.willMove(toParent: nil)
            dying.view.removeFromSuperview()
            dying.removeFromParent()
        }
    }

    // MARK: - Overscroll-to-pop

    @objc private func handleOverscrollPan(_ pan: UIPanGestureRecognizer) {
        guard pan.state == .ended, layers.count > 1,
              let scroll = layers.last?.contentScrollView else { return }
        let translation = pan.translation(in: view).y
        let velocity = pan.velocity(in: view).y
        let atTop = scroll.contentOffset.y <= -scroll.adjustedContentInset.top + 0.5
        let atBottom = scroll.contentOffset.y >= scroll.contentSize.height
            - scroll.bounds.height + scroll.adjustedContentInset.bottom - 0.5
        guard (atTop && (translation > 100 || velocity > 900))
                || (atBottom && (translation < -100 || velocity < -900)) else { return }
        popToLayer(topIndex - 1)
    }

    // MARK: - Left-edge-swipe-to-pop-one-layer

    @objc private func handleEdgePopPan(_ pan: UIScreenEdgePanGestureRecognizer) {
        // Only meaningful above the root; at the root the gesture refuses to begin (see
        // gestureRecognizerShouldBegin) so the nav controller exits the reader instead.
        guard topIndex > 0 else { return }

        guard pan.state == .ended else { return }
        let fraction = max(pan.translation(in: view).x, 0) / max(view.bounds.width, 1)
        guard fraction > 0.4 || pan.velocity(in: view).x > 800 else { return }
        popToLayer(topIndex - 1)
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
            return topIndex > 0
        }
        return true
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
