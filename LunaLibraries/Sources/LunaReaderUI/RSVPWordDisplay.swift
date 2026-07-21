//
//  RSVPWordDisplay.swift
//  LunaReaderUI
//

import LunaDesignSystem
import LunaReaderEngine
import UIKit

/// The ORP-highlighted single-word attributed string, shared by the full
/// RSVP reader's word label and the link preview's focus label: same ORP
/// index math (`RSVPWord.orpIndex`, clamped to the word's length) and the
/// same highlight color over the reading-accent tint. Font/scale stay a
/// caller-supplied parameter — the reader sizes its font from the device
/// width, the preview always uses a fixed size — this only unifies how the
/// string itself is built.
public enum RSVPWordDisplay {
    /// `word.text` in `font`/`textColor`, with the ORP letter tinted in
    /// `highlightColor`. Safe on an empty word (returns the plain string).
    public static func attributedText(
        for word: RSVPWord, font: UIFont,
        textColor: UIColor = .label, highlightColor: UIColor = GlassStyle.readingAccent
    ) -> NSAttributedString {
        let attributed = NSMutableAttributedString(
            string: word.text, attributes: [.font: font, .foregroundColor: textColor])
        let characters = Array(word.text)
        guard !characters.isEmpty else { return attributed }
        let orp = min(word.orpIndex, characters.count - 1)
        let orpStart = String(characters.prefix(orp)).utf16.count
        let orpLength = String(characters[orp]).utf16.count
        attributed.addAttribute(
            .foregroundColor, value: highlightColor,
            range: NSRange(location: orpStart, length: orpLength))
        return attributed
    }

    /// Width, in `font`, of the text preceding the ORP letter and of the ORP
    /// letter itself — the reader's word label uses these to place the ORP
    /// letter on a fixed focal column; a centered label (the preview's) has
    /// no need for them.
    public static func orpOffsets(for word: RSVPWord, font: UIFont) -> (prefixWidth: CGFloat, orpWidth: CGFloat) {
        let characters = Array(word.text)
        guard !characters.isEmpty else { return (0, 0) }
        let orp = min(word.orpIndex, characters.count - 1)
        let prefixWidth = NSAttributedString(
            string: String(characters.prefix(orp)), attributes: [.font: font]).size().width
        let orpWidth = NSAttributedString(
            string: String(characters[orp]), attributes: [.font: font]).size().width
        return (prefixWidth, orpWidth)
    }
}
