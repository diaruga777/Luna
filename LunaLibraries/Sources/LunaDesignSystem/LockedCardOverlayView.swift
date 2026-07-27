//
//  LockedCardOverlayView.swift
//  LunaDesignSystem
//

import LunaModels
import UIKit

/// The face of a card whose article is locked behind a paywall — an item parked
/// in `.needsCaptcha` for the interactive archive reader.
///
/// Such a card has no body to show, and a bare centred line of text read as a
/// card that had failed rather than one waiting on a tap. So the card wears a
/// lock instead: a large glyph in the app's tint over a wash of the same colour.
///
/// **Transparent twice over, deliberately.** The wash is a low-alpha tint rather
/// than a solid fill so the card's own surface still reads through it — the card
/// is dimmed, not replaced — and the glyph sits under 1.0 alpha too, so it reads
/// as a watermark over the card rather than a control painted on top of it.
/// Nothing here is a button.
///
/// **It never takes touches.** `isUserInteractionEnabled` is false on the view
/// and every subview, because the card's own tap (→ the unlock flow) and
/// long-press (→ Archive / Delete) must pass straight through. An overlay that
/// swallowed them would look right and break both gestures.
public final class LockedCardOverlayView: UIView {

    /// The glyph's side, in points. Large enough to be the card's subject rather
    /// than a badge on it.
    private static let glyphSide: CGFloat = 96

    private let glyph = UIImageView()
    private let caption = UILabel()

    /// - Parameter caption: the line under the glyph, or nil for the glyph alone.
    public init(caption captionText: String? = nil) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        // The wash. `lunaBrandAccent` rather than `GlassStyle.readingAccent`:
        // this says "Luna is holding this for you", which shouldn't change colour
        // with the user's reader-highlight preference.
        backgroundColor = GlassStyle.lunaBrandAccent.withAlphaComponent(0.12)

        glyph.image = UIImage(
            systemName: "lock.fill",
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: Self.glyphSide, weight: .semibold))
        glyph.tintColor = GlassStyle.lunaBrandAccent
        glyph.alpha = 0.55
        glyph.contentMode = .scaleAspectFit
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)

        caption.text = captionText
        caption.isHidden = (captionText ?? "").isEmpty
        caption.font = .preferredFont(forTextStyle: .subheadline)
        caption.textColor = LunaColors.secondaryText
        caption.textAlignment = .center
        caption.numberOfLines = 0
        caption.adjustsFontForContentSizeCategory = true
        caption.translatesAutoresizingMaskIntoConstraints = false
        addSubview(caption)

        NSLayoutConstraint.activate([
            // Seated a little above centre so the glyph and its caption balance
            // as one stack rather than the glyph sitting high of the words.
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -18),
            caption.topAnchor.constraint(equalTo: glyph.bottomAnchor, constant: 18),
            caption.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            caption.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            caption.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])

        isAccessibilityElement = true
        accessibilityLabel = captionText ?? L10n.string("Locked")
        accessibilityTraits = .staticText
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
