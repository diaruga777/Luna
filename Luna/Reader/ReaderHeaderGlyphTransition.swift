import CoreText
import UIKit

/// The masthead uses UILabel, outside the body's TextKit storage. Match its
/// characters between the two fitted layouts instead of stretching a screenshot.
@MainActor
final class ReaderHeaderGlyphTransition {
    struct Glyph {
        let key: String
        let image: UIImage
        let frame: CGRect
    }

    private struct Move {
        let view: UIImageView
        let sourceFrame: CGRect
        let sourceAlpha: CGFloat
        let destinationFrame: CGRect
        let destinationAlpha: CGFloat
    }
    private var moves: [Move] = []
    var glyphViews: [UIImageView] { moves.map(\.view) }

    init(source: [Glyph], destination: [Glyph], in host: UIView) {
        let destinations = Dictionary(destination.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let sources = Set(source.map(\.key))
        for glyph in source {
            let target = destinations[glyph.key]
            let image = UIImageView(image: glyph.image)
            // Font fitting changes both dimensions together. Preserve the glyph's
            // aspect ratio even for fractional rasterization/rounding differences.
            image.contentMode = .scaleAspectFit
            image.frame = glyph.frame
            host.addSubview(image)
            moves.append(Move(view: image, sourceFrame: glyph.frame, sourceAlpha: 1,
                              destinationFrame: target?.frame ?? glyph.frame, destinationAlpha: target == nil ? 0 : 1))
        }
        for glyph in destination where !sources.contains(glyph.key) {
            let image = UIImageView(image: glyph.image)
            image.contentMode = .scaleAspectFit
            image.frame = glyph.frame
            image.alpha = 0
            host.addSubview(image)
            moves.append(Move(view: image, sourceFrame: glyph.frame, sourceAlpha: 0,
                              destinationFrame: glyph.frame, destinationAlpha: 1))
        }
    }

    func animate(returnToSource: Bool = false) {
        for move in moves {
            move.view.frame = returnToSource ? move.sourceFrame : move.destinationFrame
            move.view.alpha = returnToSource ? move.sourceAlpha : move.destinationAlpha
        }
    }

    /// CoreText uses the same wrapping and font metrics as the title's fitting
    /// policy. Keys refer to UTF-16 positions in the complete headline, including
    /// characters that move between its main label and overflow continuation.
    static func glyphs(
        in label: UILabel, key: String, offset: Int = 0,
        syntheticPrefixLength: Int = 0, relativeTo host: UIView
    ) -> [Glyph] {
        guard !label.isHidden, let text = label.text, !text.isEmpty else { return [] }
        let textRect = label.textRect(forBounds: label.bounds, limitedToNumberOfLines: label.numberOfLines)
        guard textRect.width > 0 else { return [] }
        let style = NSMutableParagraphStyle()
        style.alignment = label.textAlignment
        // UILabel wraps its leading lines before truncating the last. A
        // CoreText frame with .byTruncatingTail truncates its FIRST line instead.
        style.lineBreakMode = label.numberOfLines == 1 ? label.lineBreakMode : .byWordWrapping
        let string = NSAttributedString(string: text, attributes: [
            .font: label.font as Any, .foregroundColor: label.textColor as Any, .paragraphStyle: style])
        let height: CGFloat = 100_000
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
            CGPath(rect: CGRect(x: 0, y: 0, width: textRect.width, height: height), transform: nil), nil)
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        let origin = label.convert(textRect.origin, to: host)
        var result: [Glyph] = []
        var characterGlyphCounts: [Int: Int] = [:]
        for (lineIndex, line) in lines.enumerated() {
            if label.numberOfLines > 0, lineIndex >= label.numberOfLines { break }
            for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
                let count = CTRunGetGlyphCount(run)
                var indices = [CFIndex](repeating: 0, count: count)
                CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
                for index in 0..<count {
                    let range = CFRange(location: index, length: 1)
                    let ink = CTRunGetImageBounds(run, nil, range)
                    guard !ink.isEmpty, !ink.isNull else { continue }
                    let padding: CGFloat = 1
                    let imageRect = ink.insetBy(dx: -padding, dy: -padding)
                    let image = UIGraphicsImageRenderer(size: imageRect.size).image { context in
                        let cg = context.cgContext
                        cg.translateBy(x: -imageRect.minX, y: imageRect.maxY)
                        cg.scaleBy(x: 1, y: -1)
                        cg.textMatrix = .identity
                        CTRunDraw(run, cg, range)
                    }
                    let rect = CGRect(x: origin.x + origins[lineIndex].x + imageRect.minX,
                        y: origin.y + height - origins[lineIndex].y - imageRect.maxY,
                        width: imageRect.width, height: imageRect.height)
                    let character = indices[index] + offset
                    let ordinal = characterGlyphCounts[character, default: 0]
                    characterGlyphCounts[character] = ordinal + 1
                    let glyphKey = indices[index] < syntheticPrefixLength
                        ? "\(key).prefix:\(indices[index]):\(ordinal)" : "\(key):\(character):\(ordinal)"
                    result.append(Glyph(key: glyphKey, image: image, frame: rect))
                }
            }
        }
        return result
    }
}
