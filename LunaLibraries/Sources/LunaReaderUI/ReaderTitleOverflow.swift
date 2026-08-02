//
//  ReaderTitleOverflow.swift
//  LunaReaderUI
//

import CoreText
import UIKit

/// Fits an over-long article title into a line-capped label: first by shrinking
/// the type a little, and only then by splitting off the part that still does
/// not fit so it is not lost to a truncating tail.
///
/// A card's title region is capped at a few lines of 30-point type. A headline
/// one or two words past the cap does not need a second block of type to read
/// whole — it needs slightly smaller type. So the fit is tried at a series of
/// sizes down to `defaultMinimumScale` of the nominal size, and the split is the
/// fallback for titles that overrun even the smallest of them. The remainder is
/// then shown below the title in smaller type, so the whole headline is always
/// readable without any expand affordance.
public enum ReaderTitleOverflow {

    /// The floor of the shrink-to-fit sweep: type no smaller than 80% of
    /// nominal, which still reads as the card's headline.
    public static let defaultMinimumScale: CGFloat = 0.8

    /// How many sizes the sweep tries between nominal and the floor. Eight steps
    /// puts them 2.5% apart at the default floor — finer than the eye resolves
    /// on a headline, and each step is one CoreText framesetting on a string of
    /// a dozen words.
    private static let shrinkSteps = 8

    /// How a title was made to fit: the type size it is set in, the part the
    /// capped label shows, and whatever still had to spill below it.
    public struct Fit: Equatable {
        /// The (possibly shrunken) font the head should be drawn in.
        public let font: UIFont
        /// What the line-capped label shows.
        public let head: String
        /// Everything after the head, or `nil` when the title fits whole.
        public let overflow: String?

        public init(font: UIFont, head: String, overflow: String?) {
            self.font = font
            self.head = head
            self.overflow = overflow
        }
    }

    /// The largest type size, from `font` down to `minimumScale` of it, at which
    /// the whole title fits `maxLines` — and, when even the smallest size cannot
    /// hold it, the split of the title at that smallest size.
    ///
    /// Shrinking is preferred to splitting because a headline that overruns the
    /// cap by a word reads better one notch smaller than it does broken across
    /// two type sizes. The sweep stops at the first size that fits, so a title
    /// is never shrunk further than it has to be.
    public static func fit(
        _ title: String, font: UIFont, width: CGFloat, maxLines: Int,
        minimumScale: CGFloat = defaultMinimumScale
    ) -> Fit {
        guard maxLines > 0, width > 0, !title.isEmpty else {
            return Fit(font: font, head: title, overflow: nil)
        }
        let floorScale = min(max(minimumScale, 0.1), 1)
        var smallest = font
        for step in 0...shrinkSteps {
            let scale = 1 - (1 - floorScale) * CGFloat(step) / CGFloat(shrinkSteps)
            smallest = scale < 1 ? font.withSize(font.pointSize * scale) : font
            if lines(title, font: smallest, width: width).count <= maxLines {
                return Fit(font: smallest, head: title, overflow: nil)
            }
        }
        // Past the floor the type stops shrinking and the tail spills instead —
        // at the smallest size, so the head carries as much of the headline as
        // the cap can hold.
        let split = split(title, font: smallest, width: width, maxLines: maxLines)
        return Fit(font: smallest, head: split.head, overflow: split.overflow)
    }

    /// The head is what fits in `maxLines` when wrapped at `width`; the overflow
    /// is everything after it, or `nil` when the title already fits.
    ///
    /// The break is taken at the wrap point that starts the first line past the
    /// cap — never mid-word — so the two parts read as one continuous headline.
    public static func split(
        _ title: String, font: UIFont, width: CGFloat, maxLines: Int
    ) -> (head: String, overflow: String?) {
        guard maxLines > 0, width > 0, !title.isEmpty else { return (title, nil) }
        let lines = lines(title, font: font, width: width)
        guard lines.count > maxLines else { return (title, nil) }

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

    /// The title wrapped at `width` in `font`, as CoreText lays it out.
    private static func lines(_ title: String, font: UIFont, width: CGFloat) -> [CTLine] {
        let attributed = NSAttributedString(string: title, attributes: [.font: font])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        // A tall-but-finite box: CoreText lays out no lines at all for some
        // unbounded heights, and no real title needs more than this.
        let path = CGPath(
            rect: CGRect(x: 0, y: 0, width: width, height: 100_000), transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter, CFRange(location: 0, length: 0), path, nil)
        return CTFrameGetLines(frame) as? [CTLine] ?? []
    }
}
