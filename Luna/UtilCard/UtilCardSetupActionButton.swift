//
//  UtilCardSetupActionButton.swift
//  Luna
//

import UIKit

/// A setup-block button whose title slides sideways in place — central Luna
/// cycles its Safari and shortcut phrasing while the weekly row turns
/// (`UtilCardSetupTextCycler`).
///
/// The subclass exists for one reason: UIKit positions a configuration
/// button's title by assigning its frame, and assigning a frame to a view
/// that carries a transform makes UIKit solve for the center that puts the
/// *transformed* view at that frame. So every layout pass that lands
/// mid-slide — the cycler's own `layoutIfNeeded` after the swap, or any card
/// reflow that happens to fall inside those 0.55s — bakes the slide's offset
/// into the label's center, and the title walks toward the trailing edge one
/// cycle at a time until it reads as right-aligned. The transform is
/// therefore lifted off for the duration of the layout and put back after,
/// so UIKit always lays the label out at rest and the slide stays a pure
/// overlay on top of that. (`WeeklySaveRowHost` solves the same conflict the
/// other way, by skipping rows it is animating — an option only open to a
/// view that owns the frames itself.)
final class UtilCardSetupActionButton: UIButton {
    /// A news-ticker treatment for a title that does not fit in the space UIKit
    /// allocated beside the button's glyph. The regular title label stays in
    /// the button for configuration layout and accessibility; this overlay is
    /// only its visual replacement while it scrolls.
    private let tickerViewport = UIView()
    private let tickerTrack = UIView()
    private let firstTickerLabel = UILabel()
    private let repeatingTickerLabel = UILabel()
    private var tickerTitle = ""
    private var tickerIsSuspended = false

    /// The blank run between a title's end and its next beginning, expressed
    /// as a fraction of the rendered title width.
    static let tickerSpacingRatio: CGFloat = 0.5
    private static let tickerSpeed: CGFloat = 30

    static func tickerSpacing(forTextWidth textWidth: CGFloat) -> CGFloat {
        textWidth * tickerSpacingRatio
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        installTicker()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installTicker()
    }

    override func layoutSubviews() {
        guard let label = titleLabel, !label.transform.isIdentity else {
            super.layoutSubviews()
            updateTickerIfNeeded()
            return
        }
        let slide = label.transform
        label.transform = .identity
        super.layoutSubviews()
        label.transform = slide
        updateTickerIfNeeded()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateTickerIfNeeded()
    }

    /// The central label cycler calls this before it slides a title away. The
    /// next ticker starts only after the new title's entrance is complete, so
    /// the two animations never draw competing copies of a label.
    func suspendTicker() {
        tickerIsSuspended = true
        stopTicker(restoringTitleLabel: false)
    }

    func resumeTickerIfNeeded() {
        tickerIsSuspended = false
        setNeedsLayout()
        layoutIfNeeded()
    }

    private func installTicker() {
        tickerViewport.clipsToBounds = true
        tickerViewport.isUserInteractionEnabled = false
        tickerViewport.isHidden = true
        tickerViewport.translatesAutoresizingMaskIntoConstraints = true
        tickerTrack.isUserInteractionEnabled = false
        firstTickerLabel.numberOfLines = 1
        repeatingTickerLabel.numberOfLines = 1
        tickerViewport.addSubview(tickerTrack)
        tickerTrack.addSubview(firstTickerLabel)
        tickerTrack.addSubview(repeatingTickerLabel)
        addSubview(tickerViewport)
    }

    private func updateTickerIfNeeded() {
        guard !tickerIsSuspended else {
            stopTicker(restoringTitleLabel: false)
            return
        }
        guard
              window != nil,
              let titleLabel,
              let title = configuration?.title ?? titleLabel.text,
              !title.isEmpty,
              titleLabel.bounds.width > 0
        else {
            stopTicker()
            return
        }

        let titleSize = (title as NSString).size(withAttributes: [
            .font: titleLabel.font ?? UIFont.systemFont(ofSize: 13, weight: .semibold),
        ])
        // Use the title label's resolved frame: it already excludes the
        // configured image, padding, and any per-button content inset.
        let titleArea = titleLabel.frame.integral
        guard titleSize.width > titleArea.width else {
            stopTicker()
            return
        }

        titleLabel.alpha = 0
        tickerViewport.isHidden = false
        tickerViewport.frame = titleArea
        bringSubviewToFront(tickerViewport)
        configureTickerLabels(
            title: title,
            font: titleLabel.font ?? UIFont.systemFont(ofSize: 13, weight: .semibold),
            color: titleLabel.textColor)
    }

    private func configureTickerLabels(title: String, font: UIFont, color: UIColor) {
        let textSize = (title as NSString).size(withAttributes: [.font: font])
        let textWidth = ceil(textSize.width)
        let spacing = Self.tickerSpacing(forTextWidth: textWidth)
        let loopDistance = textWidth + spacing
        let labelFrame = CGRect(x: 0, y: 0, width: textWidth, height: tickerViewport.bounds.height)

        let requiresRestart = tickerTitle != title
            || firstTickerLabel.font != font
            || firstTickerLabel.textColor != color
            || firstTickerLabel.frame.size != labelFrame.size
        tickerTitle = title
        firstTickerLabel.text = title
        repeatingTickerLabel.text = title
        firstTickerLabel.font = font
        repeatingTickerLabel.font = font
        firstTickerLabel.textColor = color
        repeatingTickerLabel.textColor = color
        firstTickerLabel.frame = labelFrame
        repeatingTickerLabel.frame = labelFrame.offsetBy(dx: loopDistance, dy: 0)
        tickerTrack.frame = CGRect(
            x: 0, y: 0, width: loopDistance + textWidth, height: tickerViewport.bounds.height)

        guard requiresRestart || tickerTrack.layer.animation(forKey: "luna.titleTicker") == nil else {
            return
        }
        tickerTrack.layer.removeAnimation(forKey: "luna.titleTicker")
        tickerTrack.transform = .identity
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = 0
        animation.toValue = -loopDistance
        animation.duration = max(TimeInterval(loopDistance / Self.tickerSpeed), 0.1)
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.repeatCount = .infinity
        tickerTrack.layer.add(animation, forKey: "luna.titleTicker")
    }

    private func stopTicker(restoringTitleLabel: Bool = true) {
        tickerTrack.layer.removeAnimation(forKey: "luna.titleTicker")
        tickerTrack.transform = .identity
        tickerViewport.isHidden = true
        if restoringTitleLabel { titleLabel?.alpha = 1 }
        tickerTitle = ""
    }
}
