import LunaDesignSystem
import UIKit
import XCTest
@testable import Luna

@MainActor
final class ReaderHeaderGlyphTransitionTests: XCTestCase {
    func testTitleCharactersMoveBetweenLinesWithoutChangingShape() throws {
        let source = UILabel(frame: CGRect(x: 0, y: 0, width: 220, height: 150))
        source.text = "A headline moves smoothly between its lines"
        source.font = ReaderSettings.font.font(size: 30, weight: .bold)
        source.numberOfLines = 3
        source.textColor = .white
        let destination = UILabel(frame: CGRect(x: 0, y: 0, width: 400, height: 150))
        destination.text = source.text
        destination.font = source.font
        destination.numberOfLines = 3
        destination.textColor = .white
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        host.backgroundColor = .black
        host.addSubview(source)
        let before = ReaderHeaderGlyphTransition.glyphs(in: source, key: "title", relativeTo: host)
        source.removeFromSuperview()
        host.addSubview(destination)
        let after = ReaderHeaderGlyphTransition.glyphs(in: destination, key: "title", relativeTo: host)
        destination.removeFromSuperview()
        let transition = ReaderHeaderGlyphTransition(source: before, destination: after, in: host)
        XCTAssertGreaterThan(transition.glyphViews.count, 20)
        XCTAssertGreaterThan(Set(before.map { Int($0.frame.minY / 25) }).count, 1,
                             "A multiline UILabel must not turn into a truncated single line")
        let sourceFrames = transition.glyphViews.map(\.frame)
        transition.animate()
        XCTAssertTrue(zip(transition.glyphViews, sourceFrames).contains { $0.0.frame.origin != $0.1.origin })
        for (glyph, frame) in zip(transition.glyphViews, sourceFrames) where glyph.alpha == 1 {
            XCTAssertEqual(glyph.bounds.size, frame.size, "Wrapping must only translate characters at the same font size")
        }
    }
}
