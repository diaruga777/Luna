//
//  RabbitHoleReaderViewController.swift
//  Clip
//
//  Forked, EXPERIMENTAL reader (opt-in via ReaderSettings.rabbitHoleReaderEnabled).
//  A hard fork of the inline reader: instead of a modal split overlay, the whole
//  reader is a persistent stack of "layers". Layer 0 is the save; tapping a link
//  pushes a new focused layer on top, leaving the previous layers as tappable lips
//  (title on top, the tapped line on the bottom) plus a leading indent — so you can
//  rabbit-hole several links deep without losing your place. The trail is persisted
//  per save and restored on next launch. The standard ReaderViewController and the
//  existing SplitWebOverlay inline reader are untouched.
//
//  All motion is one continuous `focus` (the focused layer's fractional stack index),
//  driven by a critically-damped spring on a display link so pushes, pops, and the
//  interactive overscroll-pop share one code path and interrupt each other cleanly.
//

import ClipStorage
import ClipModels
import UIKit

final class RabbitHoleReaderViewController: UIViewController, UIGestureRecognizerDelegate {

    private let rootItem: ReadingListItem
    private let rootContent: ArticleContent
    private let shareProvider: ReaderShareProviding?
    private let gazeTrackerFactory: GazeTrackerFactory?
    private let store = ReadingListStore.shared
    private let stackStore = RabbitHoleStackStore.shared
    private var layout = RabbitHoleLayout()

    private var layers: [RabbitHoleLayerViewController] = []
    /// Continuous focused-layer index (0 = root). Integer at rest.
    private var focus: CGFloat = 0
    private var topIndex: Int { max(layers.count - 1, 0) }

    /// Split line (container y) the currently-animating top layer emerges from / dies
    /// into, so push/pop grow from the tapped line rather than the screen edges.
    private var activeSplitY: CGFloat?

    // Focus spring (display-link integrator).
    private var displayLink: CADisplayLink?
    private var targetFocus: CGFloat = 0
    private var focusVelocity: CGFloat = 0
    private var lastTimestamp: CFTimeInterval = 0
    private var onSettle: (() -> Void)?

    private var overscrollPan: UIPanGestureRecognizer?
    private var didMarkOpened = false

    // Overscroll-pop gesture state.
    private var overscrollEngaged = false
    private var overscrollEdge: CGFloat = 1        // +1 = pulling down from the top edge
    private var overscrollBaseline: CGFloat = 0
    private weak var overscrollScroll: UIScrollView?

    init(item: ReadingListItem, content: ArticleContent,
         shareProvider: ReaderShareProviding? = nil,
         gazeTrackerFactory: GazeTrackerFactory? = nil) {
        self.rootItem = item
        self.rootContent = content
        self.shareProvider = shareProvider
        self.gazeTrackerFactory = gazeTrackerFactory
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { displayLink?.invalidate() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ReaderDepth.backgroundColor(for: 0)
        navigationItem.largeTitleDisplayMode = .never
        // The reader is full-bleed (lips reach the screen edges); the nav bar would
        // sit over the top lip, so hide it for this experiment.
        navigationController?.setNavigationBarHidden(true, animated: false)

        buildInitialStack()

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleOverscrollPan(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)
        overscrollPan = pan

        NotificationCenter.default.addObserver(
            self, selector: #selector(persist),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyFocus()   // re-place for the current bounds / safe area
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        persist()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate { _ in self.applyFocus() }
    }

    // MARK: - Stack construction

    private func buildInitialStack() {
        var descriptors: [RabbitHoleLayerDescriptor] = []
        let restored = stackStore.load(forRootID: rootItem.id)
        if let restored, let first = restored.layers.first,
           first.urlString == rootItem.urlString, restored.layers.count >= 1 {
            descriptors = restored.layers
        } else {
            descriptors = [rootDescriptor()]
        }
        for (i, descriptor) in descriptors.enumerated() {
            // The root layer renders the already-loaded content; deeper layers probe.
            _ = addLayer(descriptor, preloadedContent: i == 0 ? rootContent : nil)
        }
        focus = CGFloat(topIndex)
        targetFocus = focus
        applyFocus()
        markOpenedIfNeeded()
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
            self.pushLayer(url: url, lineText: lineText)
        }
        layer.onPopToHere = { [weak self, weak layer] in
            guard let self, let layer, let index = self.layers.firstIndex(where: { $0 === layer })
            else { return }
            self.popToLayer(index)
        }
        layer.onModeChanged = { [weak self] _ in self?.persist() }
        layer.onBack = { [weak self] in self?.handleBack() }
        addChild(layer)
        view.addSubview(layer.view)
        layer.didMove(toParent: self)
        layers.append(layer)
        return layer
    }

    // MARK: - The single layout writer

    /// Place every layer for the current `focus`. The ONLY writer of layer frames.
    private func applyFocus() {
        guard !layers.isEmpty else { return }
        let bounds = view.bounds
        let safe = view.safeAreaInsets
        for (i, layer) in layers.enumerated() {
            let placement = layout.placement(
                layerIndex: i, focus: focus, bounds: bounds, safeArea: safe,
                splitY: i == topIndex ? activeSplitY : nil)
            layer.view.frame = placement.cardFrame
            layer.view.layer.zPosition = placement.z
            layer.view.alpha = placement.cardAlpha
            layer.view.isHidden = placement.cardAlpha <= 0.001
            layer.applyDepth(placement.depth)
            layer.setChrome(role: placement.role, alpha: placement.chromeAlpha)
        }
    }

    // MARK: - Push / pop

    private func pushLayer(url: URL, lineText: String?) {
        guard let focused = layers.last else { return }
        // Record where the new layer should grow FROM (the tapped line), and the line
        // text to show in the now-receding layer's bottom lip.
        focused.setBottomLipText(lineText)
        if let rect = focused.lineRectInLayer(for: url) {
            activeSplitY = focused.view.convert(rect, to: view).minY
        } else {
            activeSplitY = view.bounds.midY     // non-scroll mode → grow from centre
        }
        let descriptor = RabbitHoleLayerDescriptor(urlString: url.absoluteString)
        _ = addLayer(descriptor)
        applyFocus()                            // place the newcomer at its sliver first
        animateFocus(to: CGFloat(topIndex)) { [weak self] in
            self?.activeSplitY = nil
            self?.persist()
        }
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
        guard index >= 0, index < layers.count, index != topIndex else { return }
        // Collapse the dying top layer back to where it grew from (its parent's bottom
        // lip line); fall back to the screen centre.
        if activeSplitY == nil {
            let parent = layers[max(index, 0)]
            let lipY = parent.view.convert(
                CGRect(x: 0, y: parent.view.bounds.height - layout.lipHeight,
                       width: 1, height: 1), to: view).minY
            activeSplitY = lipY
        }
        animateFocus(to: CGFloat(index)) { [weak self] in
            guard let self else { return }
            while self.layers.count - 1 > index {
                let dying = self.layers.removeLast()
                dying.willMove(toParent: nil)
                dying.view.removeFromSuperview()
                dying.removeFromParent()
            }
            self.activeSplitY = nil
            self.focus = CGFloat(self.topIndex)
            self.targetFocus = self.focus
            self.applyFocus()
            self.persist()
        }
    }

    // MARK: - Focus spring (display-link)

    private func animateFocus(to target: CGFloat, completion: (() -> Void)? = nil) {
        targetFocus = target
        onSettle = completion
        if displayLink == nil {
            lastTimestamp = 0
            let link = CADisplayLink(target: self, selector: #selector(stepFocus(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    @objc private func stepFocus(_ link: CADisplayLink) {
        if lastTimestamp == 0 { lastTimestamp = link.timestamp; return }
        let dt = min(CGFloat(link.timestamp - lastTimestamp), 1.0 / 30.0)
        lastTimestamp = link.timestamp

        // Critically-damped spring toward targetFocus.
        let stiffness: CGFloat = 220
        let damping: CGFloat = 30
        let accel = -stiffness * (focus - targetFocus) - damping * focusVelocity
        focusVelocity += accel * dt
        focus += focusVelocity * dt

        if abs(focus - targetFocus) < 0.001 && abs(focusVelocity) < 0.01 {
            focus = targetFocus
            focusVelocity = 0
            applyFocus()
            stopSpring()
            let settle = onSettle
            onSettle = nil
            settle?()
            return
        }
        applyFocus()
    }

    private func stopSpring() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = 0
    }

    // MARK: - Overscroll-to-pop

    @objc private func handleOverscrollPan(_ pan: UIPanGestureRecognizer) {
        guard layers.count > 1, let focused = layers.last,
              let scroll = focused.contentScrollView else { return }
        let translation = pan.translation(in: view).y

        switch pan.state {
        case .began, .changed:
            if !overscrollEngaged {
                // Engage only once the inner scroll view is already at an edge and the
                // drag pushes further past it — otherwise let it scroll normally.
                let atTop = scroll.contentOffset.y <= -scroll.adjustedContentInset.top + 0.5
                let atBottom = scroll.contentOffset.y >= scroll.contentSize.height
                    - scroll.bounds.height + scroll.adjustedContentInset.bottom - 0.5
                if atTop, translation > 0 { engageOverscroll(scroll, edge: 1, baseline: translation) }
                else if atBottom, translation < 0 { engageOverscroll(scroll, edge: -1, baseline: translation) }
            }
            guard overscrollEngaged else { return }
            // Rubber-band resistance: a long pull yields only a fraction of a layer.
            let raw = max((translation - overscrollBaseline) * overscrollEdge, 0)
            let pull = raw / (raw + 240)
            focus = CGFloat(topIndex) - pull
            applyFocus()
        case .ended, .cancelled:
            guard overscrollEngaged else { return }
            disengageOverscroll()
            let pulled = CGFloat(topIndex) - focus
            let velocity = pan.velocity(in: view).y * overscrollEdge   // >0 continues the pull
            if pulled > 0.32 || velocity > 900 {
                popToLayer(topIndex - 1)
            } else {
                animateFocus(to: CGFloat(topIndex)) { [weak self] in self?.activeSplitY = nil }
            }
        default:
            break
        }
    }

    private func engageOverscroll(_ scroll: UIScrollView, edge: CGFloat, baseline: CGFloat) {
        overscrollEngaged = true
        overscrollEdge = edge
        overscrollBaseline = baseline
        overscrollScroll = scroll
        stopSpring()
        scroll.bounces = false
        scroll.isScrollEnabled = false          // we own the drag now; no fighting bounce
        activeSplitY = view.bounds.midY
    }

    private func disengageOverscroll() {
        overscrollEngaged = false
        overscrollScroll?.bounces = true
        overscrollScroll?.isScrollEnabled = true
        overscrollScroll = nil
    }

    /// Run alongside the inner scroll view's own pan so we can read its edge state.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    // MARK: - Persistence

    @objc private func persist() {
        guard !layers.isEmpty else { return }
        for layer in layers { layer.syncScrollOffset() }
        let descriptors = layers.map { $0.descriptor }
        stackStore.save(RabbitHoleStack(layers: descriptors), forRootID: rootItem.id)
        // Keep the reading list's own resume fields in step for the ROOT layer so the
        // list/standard reader stay consistent if the user flips the toggle off.
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
