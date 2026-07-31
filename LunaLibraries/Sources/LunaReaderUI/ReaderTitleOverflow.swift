//
//  ReaderTitleOverflow.swift
//  LunaReaderUI
//

import CoreText
import UIKit

/// Splits an over-long article title into the part a line-capped label can show
/// and the remainder that would otherwise be lost to a truncating tail.
///
/// A card's title region is capped at a few lines of 30-point type, and a long
/// headline simply ended in an ellipsis with no way to read the rest. The
/// remainder is instead shown below the title in smaller type, so the whole
/// headline is always readable without any expand affordance.
public enum ReaderTitleOverflow {

    /// The head is what fits in `maxLines` when wrapped at `width`; the overflow
    /// is everything after it, or `nil` when the title already fits.
    ///
    /// The break is taken at the wrap point that starts the first line past the
    /// cap — never mid-word — so the two parts read as one continuous headline.
    public static func split(
        _ title: String, font: UIFont, width: CGFloat, maxLines: Int
    ) -> (head: String, overflow: String?) {
        guard maxLines > 0, width > 0, !title.isEmpty else { return (title, nil) }
        let attributed = NSAttributedString(string: title, attributes: [.font: font])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        // A tall-but-finite box: CoreText lays out no lines at all for some
        // unbounded heights, and no real title needs more than this.
        let path = CGPath(
            rect: CGRect(x: 0, y: 0, width: width, height: 100_000), transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter, CFRange(location: 0, length: 0), path, nil)
        guard let lines = CTFrameGetLines(frame) as? [CTLine], lines.count > maxLines
        else { return (title, nil) }

        let breakOffset = CTLineGetStringRange(lines[maxLines]).location
        guard breakOffset > 0, breakOffset < title.utf16.count else { return (title, nil) }
        let breakIndex = String.Index(utf16Offset: breakOffset, in: title)
        let head = String(title[..<breakIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let overflow = String(title[breakIndex...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !head.isEmpty, !overflow.isEmpty else { return (title, nil) }
        return (head, overflow)
    }

    /// The overflow as it is displayed: led by an ellipsis so it reads as the
    /// continuation of the line above rather than a new sentence.
    public static func displayString(forOverflow overflow: String) -> String {
        "…" + overflow
    }
}
