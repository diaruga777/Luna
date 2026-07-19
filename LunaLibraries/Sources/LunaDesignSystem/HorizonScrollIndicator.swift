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
public final class HorizonScrollIndicator: UIView {

    // The line and point geometry, echoing `MoonHorizonProgressBar`'s
    // `litLineWidth`, bloom (26pt) and core (3pt).
    private static let lineWidth: CGFloat = MoonHorizonStyle.litLineWidth
    private static let bloomDiameter: CGFloat = 26
    private static let coreDiameter: CGFloat = 3
    /// How far the line sits in from the trailing edge — matches the system
    /// indicator's inset closely enough to read as "on the edge".
    private static let trailingMargin: CGFloat = 3.5
    /// The faint track evokes the progress bar's lit line but unlit: same warm
    /// hue, low alpha, so the bright point clearly reads as the head.
    private static let trackAlpha: CGFloat = 0.22
    private static let idleFadeDelay: TimeInterval = 1.1

    private weak var scrollView: UIScrollView?
    private var observations: [NSKeyValueObservation] = []
    private var hideWorkItem: DispatchWorkItem?

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
        scrollView.showsVerticalScrollIndicator = false
        let indicator = HorizonScrollIndicator(scrollView: scrollView)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(indicator)
        NSLayoutConstraint.activate([
            indicator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            indicator.topAnchor.constraint(equalTo: scrollView.topAnchor),
            indicator.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            indicator.widthAnchor.constraint(equalToConstant: bloomDiameter),
        ])
        return indicator
    }

    // MARK: - Init

    private init(scrollView: UIScrollView) {
        self.scrollView = scrollView
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

        observations.append(scrollView.observe(\.contentOffset, options: [.new]) {
            [weak self] _, _ in self?.scrollChanged()
        })
        observations.append(scrollView.observe(\.contentSize) {
            [weak self] _, _ in self?.setNeedsLayout()
        })
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Layout

    public override func layoutSubviews() {
        super.layoutSubviews()
        guard let scrollView else { return }

        let insetTop = scrollView.adjustedContentInset.top
        let insetBottom = scrollView.adjustedContentInset.bottom
        let visibleHeight = scrollView.bounds.height - insetTop - insetBottom
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

        // The overlay is pinned to the scroll view's top/bottom, so its own
        // coordinates line up with the scroll view's — the track region is the
        // visible window between the two insets.
        let trackTop = insetTop
        let trackBottom = bounds.height - insetBottom
        let lineX = bounds.width - Self.trailingMargin

        let path = CGMutablePath()
        path.move(to: CGPoint(x: lineX, y: trackTop))
        path.addLine(to: CGPoint(x: lineX, y: trackBottom))

        let fraction = min(1, max(0, (scrollView.contentOffset.y + insetTop) / range))
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
            superview?.bringSubviewToFront(self)
            UIView.animate(withDuration: 0.15) { self.alpha = 1 }
        }
        let work = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.4) { self?.alpha = 0 }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleFadeDelay, execute: work)
    }
}
