//
//  RenderingAttributeComposerTests.swift
//  LunaTests
//

import XCTest
import UIKit
@testable import LunaWriterEditor
import LunaWriterModels

/// A layer that always wants the same attributes over the same range.
private final class FixedLayer: RenderingAttributeLayer {
    let identifier: LayerID
    var range: NSRange
    var attributes: [NSAttributedString.Key: Any]

    init(identifier: LayerID, range: NSRange, attributes: [NSAttributedString.Key: Any]) {
        self.identifier = identifier
        self.range = range
        self.attributes = attributes
    }

    func contributions(in range: NSRange, text: NSString) -> [RangedAttributes] {
        [RangedAttributes(range: self.range, attributes: attributes)]
    }
}

private final class StubFocus: FocusRangeProviding {
    var focusRange: NSRange?
    init(_ range: NSRange?) { focusRange = range }
}

private final class StubAnnotations: AnnotationRangeProviding {
    var annotations: [ResolvedAnnotation] = []
    func resolvedAnnotations(in range: NSRange) -> [ResolvedAnnotation] {
        annotations.filter { NSIntersectionRange($0.range, range).length > 0 }
    }
}

final class RenderingAttributeComposerTests: XCTestCase {

    private let text = "The quick brown fox jumps over the lazy dog."
    private var traits: UITraitCollection {
        UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: .dark),
            UITraitCollection { $0.lunaSky = .night },
        ])
    }

    private func makeComposer() -> (RenderingAttributeComposer, MarkdownTextStorage) {
        let storage = MarkdownTextStorage(text: text)
        return (RenderingAttributeComposer(layoutManager: nil, storage: storage), storage)
    }

    private func attributes(
        _ composer: RenderingAttributeComposer, at location: Int
    ) -> [NSAttributedString.Key: Any] {
        let whole = NSRange(location: 0, length: (text as NSString).length)
        for run in composer.composedRuns(in: whole) where NSLocationInRange(location, run.range) {
            return run.attributes
        }
        return [:]
    }

    private func colour(
        _ composer: RenderingAttributeComposer, at location: Int, key: NSAttributedString.Key = .foregroundColor
    ) -> UIColor? {
        (attributes(composer, at: location)[key] as? UIColor)?.resolvedColor(with: traits)
    }

    func testFocusDimsAWordTheSyntaxLayerColoured() {
        let (composer, _) = makeComposer()
        let syntax = FixedLayer(
            identifier: .syntax, range: NSRange(location: 0, length: 9),
            attributes: [.foregroundColor: EditorTheme.syntaxNoun])
        composer.addLayer(syntax)
        let focus = StubFocus(NSRange(location: 10, length: 9))
        composer.addLayer(FocusLayer(provider: focus))

        XCTAssertEqual(colour(composer, at: 2), EditorTheme.dimmed.resolvedColor(with: traits))
        // Inside the focus range nothing dims, so the syntax colour stands.
        let inside = FixedLayer(
            identifier: "inside", range: NSRange(location: 10, length: 5),
            attributes: [.foregroundColor: EditorTheme.syntaxVerb])
        composer.addLayer(inside, before: .focus)
        XCTAssertEqual(colour(composer, at: 11), EditorTheme.syntaxVerb.resolvedColor(with: traits))
    }

    func testAnnotationUnderlineSurvivesTheFocusDim() {
        let (composer, _) = makeComposer()
        let focus = StubFocus(NSRange(location: 30, length: 4))
        composer.addLayer(FocusLayer(provider: focus))
        let annotations = StubAnnotations()
        annotations.annotations = [
            ResolvedAnnotation(id: AnnotationID(), range: NSRange(location: 4, length: 5), kind: .cut)
        ]
        composer.addLayer(AnnotationLayer(provider: annotations))

        let attributes = attributes(composer, at: 5)
        XCTAssertEqual(attributes[.underlineStyle] as? Int, NSUnderlineStyle.thick.rawValue)
        XCTAssertEqual(
            (attributes[.underlineColor] as? UIColor)?.resolvedColor(with: traits),
            EditorTheme.annotationCut.resolvedColor(with: traits))
        XCTAssertEqual(
            (attributes[.foregroundColor] as? UIColor)?.resolvedColor(with: traits),
            EditorTheme.dimmed.resolvedColor(with: traits))
    }

    func testCommentAnnotationWashesItsWords() {
        let (composer, _) = makeComposer()
        let annotations = StubAnnotations()
        annotations.annotations = [
            ResolvedAnnotation(id: AnnotationID(), range: NSRange(location: 0, length: 3), kind: .comment)
        ]
        composer.addLayer(AnnotationLayer(provider: annotations))
        XCTAssertNotNil(attributes(composer, at: 1)[.backgroundColor])
        XCTAssertNil(attributes(composer, at: 10)[.backgroundColor])
    }

    func testAnInstalledReadingLayerPaintsItsBand() {
        let (composer, _) = makeComposer()
        let focus = StubFocus(NSRange(location: 0, length: 3))
        composer.addLayer(FocusLayer(provider: focus))
        let band = FixedLayer(
            identifier: .reading, range: NSRange(location: 4, length: 5),
            attributes: [.backgroundColor: EditorTheme.readingBand])
        composer.addLayer(band)

        XCTAssertEqual(
            colour(composer, at: 5, key: .backgroundColor),
            EditorTheme.readingBand.resolvedColor(with: traits))

        composer.removeLayer(.reading)
        XCTAssertNil(colour(composer, at: 5, key: .backgroundColor))
    }

    func testRunsTileTheRequestedRangeExactlyOnce() {
        let (composer, _) = makeComposer()
        composer.addLayer(FixedLayer(
            identifier: .markup, range: NSRange(location: 4, length: 5),
            attributes: [.foregroundColor: EditorTheme.markup]))
        let whole = NSRange(location: 0, length: (text as NSString).length)
        let runs = composer.composedRuns(in: whole)
        XCTAssertEqual(runs.first?.range.location, 0)
        var next = 0
        for run in runs {
            XCTAssertEqual(run.range.location, next)
            next = NSMaxRange(run.range)
        }
        XCTAssertEqual(next, whole.length)
    }

    func testALaterLayerWinsTheSameKey() {
        let (composer, _) = makeComposer()
        composer.addLayer(FixedLayer(
            identifier: .syntax, range: NSRange(location: 0, length: 5),
            attributes: [.foregroundColor: EditorTheme.syntaxNoun]))
        composer.addLayer(FixedLayer(
            identifier: .authorship, range: NSRange(location: 0, length: 5),
            attributes: [.foregroundColor: EditorTheme.authorshipPasted]))
        XCTAssertEqual(colour(composer, at: 2), EditorTheme.authorshipPasted.resolvedColor(with: traits))
    }
}
