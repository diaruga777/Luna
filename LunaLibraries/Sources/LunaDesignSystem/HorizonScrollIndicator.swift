//
//  HorizonScrollIndicator.swift
//  Luna
//

import UIKit

/// A custom vertical scroll indicator drawn in the "moon horizon" visual
/// language of `MoonHorizonProgressBar`, rotated upright: a thin, faint warm
/// line for the full scroll track and one brilliant point of light — the sun
/// core with its radial bloom — riding it at the current scroll position.
///
/// Unlike the system indicator (which lives inside the scroll view and so sits
/// at the scroll view's own trailing edge), this overlay is pinned to the
/// trailing edge of whatever container it's installed in, so it hugs the edge
/// of the screen even when the scrolled content is inset from it. It hides the
/// scroll view's native indicator and mirrors its behaviour: it flashes in as
/// you scroll and fades out once you stop.
///
/// Two ways to use it:
/// - `install(on:in:)` — the self-installed overlay above: pinned by Auto Layout
///   to a container's trailing edge and to a scroll view's vertical extent.
///   Inside a carousel card the card's clip would trap it at the card edge, so
///   there it removes itself and lets the card host place a `makeHosted()`
///   indicator that can escape the clip (see `ArticleCardsViewController`).
/// - `makeHosted()` — a host-driven overlay: the owner sets its `frame`, its
///   `trackInsets`, and `track(_:)`s whichever scroll view is live, and can
///   slide it (frame only — never the scroll view) between the card edge and
///   the screen edge as the card immerses.
public final class HorizonScrollIndicator: UIView {

    // The line and point geometry, echoing `MoonHorizonProgressBar`'s
    // `litLineWidth`, bloom (26pt) and core (3pt).
    private static let lineWidth: CGFloat = MoonHorizonStyle.litLineWidth
    public static let bloomDiameter: CGFloat = 26
    private static let coreDiameter: CGFloat = 3
    /// How far the line sits in from the trailing edge — matches the system
    /// indicator's inset closely enough to read as "on the edge".
    private static let trailingMargin: CGFloat = 3.5
    /// The faint track evokes the progress bar's lit line but unlit: same warm
    /// hue, low alpha, so the bright point clearly reads as the head.
    private static let trackAlpha: CGFloat = 0.22
    private static let idleFadeDelay: TimeInterval = 1.1

    private weak var scrollView: UIScrollView?
    private var offsetObservation: NSKeyValueObservation?
    private var sizeObservation: NSKeyValueObservation?
    private var hideWorkItem: DispatchWorkItem?
    /// Host-managed indicators are placed and sized by their owner and never
    /// self-remove; self-installed ones retreat when trapped inside a card.
    private let isHostManaged: Bool

    /// When set (host mode), the track runs from `trackInsets.top` below the
    /// view's top to `trackInsets.bottom` above its bottom. When nil
    /// (self-installed mode) the track mirrors the scroll view's own content
    /// insets, since the overlay is pinned to the scroll view's extent.
    public var trackInsets: UIEdgeInsets? {
        didSet { setNeedsLayout() }
    }

    /// The faint warm track line spanning the scrollable range.
    private let trackLayer = CAShapeLayer()
    /// The sun's steep radial bloom around the point.
    private let bloomLayer = CAGradientLayer()
    /// The white-hot core point itself.
    private let coreLayer = CALayer()

    // MARK: - Install

    /// Hides `scrollView`'s native vertical indicator and installs a horizon
    /// indicator pinned to `container`'s trailing edge, spanning the same
    /// vertical extent as the scroll view. The returned indicator is retained
    /// by the view hierarchy; callers don't need to hold it.
    @discardableResult
    public static func install(
        on scrollView: UIScrollView, in container: UIView
    ) -> HorizonScrollIndicator {
        let indicator = HorizonScrollIndicator(hostManaged: false)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(indicator)
        // `didMoveToWindow` deliberately removes self-installed indicators when
        // the container lives inside a carousel card (the card host owns the
        // escape-the-clip indicator). If that synchronous retreat happened during
        // `addSubview`, activating constraints against the now-detached indicator
        // would raise an Objective-C Auto Layout exception.
        guard indicator.superview === container else { return indicator }
        NSLayoutConstraint.activate([
            indicator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            indicator.topAnchor.constraint(equalTo: scrollView.topAnchor),
            indicator.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            indicator.widthAnchor.constraint(equalToConstant: bloomDiameter),
        ])
        indicator.track(scrollView)
        return indicator
    }

    /// Creates a host-driven indicator. The caller adds it to a non-clipping
    /// container, sets its `frame` and `trackInsets`, and `track(_:)`s the live
    /// scroll view. Frame-based (no Auto Layout), so the host can slide it.
    public static func makeHosted() -> HorizonScrollIndicator {
        HorizonScrollIndicator(hostManaged: true)
    }

    // MARK: - Init

    private init(hostManaged: Bool) {
        self.isHostManaged = hostManaged
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        clipsToBounds = false
        alpha = 0

        trackLayer.fillColor = nil
        trackLayer.lineCap = .round
        trackLayer.lineWidth = Self.lineWidth
        layer.addSublayer(trackLayer)

        bloomLayer.type = .radial
        bloomLayer.bounds = CGRect(
            x: 0, y: 0, width: Self.bloomDiameter, height: Self.bloomDiameter)
        bloomLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        bloomLayer.endPoint = CGPoint(x: 1, y: 1)
        bloomLayer.locations = [0, 0.12, 0.42, 1]
        layer.addSublayer(bloomLayer)

        coreLayer.bounds = CGRect(
            x: 0, y: 0, width: Self.coreDiameter, height: Self.coreDiameter)
        coreLayer.cornerRadius = Self.coreDiameter / 2
        coreLayer.shadowOpacity = 1
        coreLayer.shadowRadius = 3
        coreLayer.shadowOffset = .zero
        layer.addSublayer(coreLayer)

        updateColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            (self: Self, _: UITraitCollection) in self.updateColors()
        }
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Tracking

    /// Points the indicator at `scrollView` (hiding its native indicator) and
    /// begins observing it. Pass a different scroll view to retarget — the host
    /// does this as the reader swaps its live layer — or nil to detach.
    public func track(_ scrollView: UIScrollView?) {
        guard scrollView !== self.scrollView else { return }
        offsetObservation = nil
        sizeObservation = nil
        self.scrollView = scrollView
        guard let scrollView else {
            setNeedsLayout()
            return
        }
        scrollView.showsVerticalScrollIndicator = false
        offsetObservation = scrollView.observe(\.contentOffset, options: [.new]) {
            [weak self] _, _ in self?.scrollChanged()
        }
        sizeObservation = scrollView.observe(\.contentSize) {
            [weak self] _, _ in self?.setNeedsLayout()
        }
        setNeedsLayout()
    }

    // MARK: - Card-clip retreat

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        // A self-installed indicator trapped inside a card surface (the root
        // carousel's own cards, or a host that reuses CardSurfaceView for its
        // own nested card chrome — e.g. SplitWebOverlayViewController) can
        // only reach the card's (clipped) edge; the card host places its own
        // escape-the-clip indicator instead, so step aside.
        guard !isHostManaged, window != nil, isInsideCardSurface else { return }
        track(nil)
        removeFromSuperview()
    }

    private var isInsideCardSurface: Bool {
        var ancestor = superview
        while let current = ancestor {
            if current is CardSurfaceView { return true }
            ancestor = current.superview
        }
        return false
    }

    // MARK: - Layout

    public override func layoutSubviews() {
        super.layoutSubviews()
        guard let scrollView else {
            trackLayer.isHidden = true
            bloomLayer.isHidden = true
            coreLayer.isHidden = true
            return
        }

        // Scroll math (progress) comes from the scroll view's own geometry…
        let scrollInsetTop = scrollView.adjustedContentInset.top
        let scrollInsetBottom = scrollView.adjustedContentInset.bottom
        let visibleHeight = scrollView.bounds.height - scrollInsetTop - scrollInsetBottom
        let range = max(scrollView.contentSize.height - visibleHeight, 0)

        // Nothing to scroll → nothing to show.
        guard range > 0.5, visibleHeight > 0 else {
            trackLayer.isHidden = true
            bloomLayer.isHidden = true
            coreLayer.isHidden = true
            return
        }
        trackLayer.isHidden = false
        bloomLayer.isHidden = false
        coreLayer.isHidden = false

        // …while the track's on-screen extent comes from THIS view's bounds:
        // self-installed, it's pinned to the scroll view so mirroring the scroll
        // insets lines up; host-managed, the owner supplies the insets.
        let insets = trackInsets
            ?? UIEdgeInsets(top: scrollInsetTop, left: 0, bottom: scrollInsetBottom, right: 0)
        let trackTop = insets.top
        let trackBottom = bounds.height - insets.bottom
        let lineX = bounds.width - Self.trailingMargin

        let path = CGMutablePath()
        path.move(to: CGPoint(x: lineX, y: trackTop))
        path.addLine(to: CGPoint(x: lineX, y: trackBottom))

        let fraction = min(1, max(0, (scrollView.contentOffset.y + scrollInsetTop) / range))
        let pointY = trackTop + fraction * (trackBottom - trackTop)
        let head = CGPoint(x: lineX, y: pointY)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackLayer.path = path
        bloomLayer.position = head
        coreLayer.position = head
        CATransaction.commit()
    }

    // MARK: - Colours

    private func updateColors() {
        let sunlight = MoonHorizonStyle.sunlight.resolvedColor(with: traitCollection)
        let sunCore = MoonHorizonStyle.sunCore.resolvedColor(with: traitCollection)
        trackLayer.strokeColor = sunlight.withAlphaComponent(Self.trackAlpha).cgColor
        bloomLayer.colors = [
            sunCore.cgColor,
            sunCore.withAlphaComponent(MoonHorizonStyle.headBloomInnerAlpha).cgColor,
            sunlight.withAlphaComponent(MoonHorizonStyle.headBloomOuterAlpha).cgColor,
            sunlight.withAlphaComponent(0).cgColor,
        ]
        coreLayer.backgroundColor = sunCore.cgColor
        coreLayer.shadowColor = sunCore.cgColor
    }

    // MARK: - Flash / fade

    private func scrollChanged() {
        setNeedsLayout()
        flash()
    }

    /// Show the indicator, then schedule a fade-out after a spell of no
    /// scrolling — the system indicator's flash-and-recede behaviour.
    private func flash() {
        // Don't flash when there's nothing scrollable to indicate.
        guard let scrollView,
            scrollView.contentSize.height
                - (scrollView.bounds.height - scrollView.adjustedContentInset.top
                    - scrollView.adjustedContentInset.bottom) > 0.5
        else { return }

        hideWorkItem?.cancel()
        if alpha < 1 {
            // Self-installed overlays sit above late-added sibling chrome
            // (footers); a host-managed one is placed by its owner, which keeps
            // it below the screen chrome — don't fight that ordering.
            if !isHostManaged { superview?.bringSubviewToFront(self) }
            UIView.animate(withDuration: 0.15) { self.alpha = 1 }
        }
        let work = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.4) { self?.alpha = 0 }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleFadeDelay, execute: work)
    }
}
