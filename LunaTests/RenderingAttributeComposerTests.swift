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

private final class FakeViewport: RenderingViewportProviding {
    var hasViewport: Bool
    var renderingViewportRange: NSRange
    init(hasViewport: Bool, range: NSRange) {
        self.hasViewport = hasViewport
        self.renderingViewportRange = range
    }
}

/// Records every range the composer asked to paint, instead of actually
/// drawing it, so a test can tell whether a pass ran at all.
private final class RecordingLayoutManager: NSTextLayoutManager {
    var paintedRanges: [NSTextRange] = []
    override func setRenderingAttributes(_ renderingAttributes: [NSAttributedString.Key: Any], for textRange: NSTextRange) {
        paintedRanges.append(textRange)
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
        // Inside the focus range nothing dims, so the syntax colour stands,
        // whichever order the two layers were added in.
        let inside = FixedLayer(
            identifier: "inside", range: NSRange(location: 10, length: 5),
            attributes: [.foregroundColor: EditorTheme.syntaxVerb])
        composer.addLayer(inside)
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

    func testLongMarkdownCompositionPerformance() {
        let text = String(repeating: "A **bold phrase** and `code` in a paragraph.\n\n", count: 1_000)
        let storage = MarkdownTextStorage(text: text)
        let composer = RenderingAttributeComposer(layoutManager: nil, storage: storage)
        composer.addLayer(MarkupLayer(model: storage.model))
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTClockMetric()], options: options) {
            let runs = composer.composedRuns(in: NSRange(location: 0, length: storage.length))
            XCTAssertEqual(runs.first?.range.location, 0)
            XCTAssertEqual(runs.last.map { NSMaxRange($0.range) }, storage.length)
        }
    }

    // MARK: - applyNow, with a real layout manager

    private func makeLayoutManager(storage: NSTextStorage) -> RecordingLayoutManager {
        let layoutManager = RecordingLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.textContainer = container
        let contentStorage = NSTextContentStorage()
        contentStorage.addTextLayoutManager(layoutManager)
        contentStorage.textStorage = storage
        return layoutManager
    }

    func testApplyNowNeverPaintsTheWholeDocumentAsAStandInWhileTheViewportIsUnknown() {
        let storage = MarkdownTextStorage(text: text)
        let layoutManager = makeLayoutManager(storage: storage)
        let composer = RenderingAttributeComposer(layoutManager: layoutManager, storage: storage)
        let viewport = FakeViewport(hasViewport: false, range: NSRange(location: 0, length: 9))
        composer.viewportProvider = viewport
        composer.addLayer(FixedLayer(
            identifier: .syntax, range: NSRange(location: 0, length: 5),
            attributes: [.foregroundColor: EditorTheme.syntaxNoun]))

        composer.applyNow()
        XCTAssertTrue(layoutManager.paintedRanges.isEmpty)
    }

    func testApplyNowPaintsTheDeferredRequestOnceTheViewportResolves() {
        let storage = MarkdownTextStorage(text: text)
        let layoutManager = makeLayoutManager(storage: storage)
        let composer = RenderingAttributeComposer(layoutManager: layoutManager, storage: storage)
        let viewport = FakeViewport(hasViewport: false, range: NSRange(location: 0, length: 9))
        composer.viewportProvider = viewport
        composer.addLayer(FixedLayer(
            identifier: .syntax, range: NSRange(location: 0, length: 5),
            attributes: [.foregroundColor: EditorTheme.syntaxNoun]))
        composer.applyNow()
        XCTAssertTrue(layoutManager.paintedRanges.isEmpty)

        viewport.hasViewport = true
        composer.applyNow()
        XCTAssertFalse(layoutManager.paintedRanges.isEmpty, "the request stayed pending, so it paints once a viewport exists")
    }

    func testALargePasteOnlyPaintsTheVisibleRegion() {
        let storage = MarkdownTextStorage(text: String(repeating: "a", count: 10_000))
        let layoutManager = makeLayoutManager(storage: storage)
        let composer = RenderingAttributeComposer(layoutManager: layoutManager, storage: storage)
        let viewport = FakeViewport(hasViewport: true, range: NSRange(location: 500, length: 100))
        composer.viewportProvider = viewport
        composer.invalidate(NSRange(location: 0, length: storage.length))
        composer.applyNow()
        let content = layoutManager.textContentManager!
        XCTAssertFalse(layoutManager.paintedRanges.isEmpty)
        for range in layoutManager.paintedRanges {
            let start = content.offset(from: content.documentRange.location, to: range.location)
            let end = content.offset(from: content.documentRange.location, to: range.endLocation)
            XCTAssertGreaterThanOrEqual(start, 300)
            XCTAssertLessThanOrEqual(end, 800)
        }
    }

    /// TextKit 2 drops a fragment's rendering attributes when it lays the
    /// fragment out again, and asks the layout manager's validator to paint
    /// it. The composer must answer that call, or every edit erases the
    /// markup grey and the focus dim on the line it touched.
    func testTheLayoutManagerValidatorPaintsAFragmentFromTheLayers() throws {
        let storage = MarkdownTextStorage(text: text)
        let layoutManager = makeLayoutManager(storage: storage)
        let composer = RenderingAttributeComposer(layoutManager: layoutManager, storage: storage)
        composer.viewportProvider = FakeViewport(hasViewport: false, range: NSRange(location: 0, length: 0))
        composer.addLayer(FixedLayer(
            identifier: .syntax, range: NSRange(location: 0, length: 3),
            attributes: [.foregroundColor: EditorTheme.syntaxNoun]))
        let validator = try XCTUnwrap(layoutManager.renderingAttributesValidator)

        layoutManager.ensureLayout(for: layoutManager.documentRange)
        var fragment: NSTextLayoutFragment?
        layoutManager.enumerateTextLayoutFragments(from: nil, options: []) { fragment = $0; return false }
        validator(layoutManager, try XCTUnwrap(fragment))

        XCTAssertFalse(layoutManager.paintedRanges.isEmpty, "the validator painted nothing")
        let content = try XCTUnwrap(layoutManager.textContentManager)
        let starts = layoutManager.paintedRanges.map { content.offset(from: content.documentRange.location, to: $0.location) }
        XCTAssertTrue(starts.contains(0))
    }

    func testApplyNowWithARealTextViewSmokeTest() {
        let storage = MarkdownTextStorage(text: text)
        let textView = WriterTextView(metrics: EditorMetrics(), textStorage: storage)
        textView.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        textView.layoutIfNeeded()
        let composer = RenderingAttributeComposer(layoutManager: textView.textLayoutManager, storage: storage)
        let viewport = FakeViewport(
            hasViewport: true, range: NSRange(location: 0, length: (text as NSString).length))
        composer.viewportProvider = viewport
        composer.addLayer(FixedLayer(
            identifier: .syntax, range: NSRange(location: 0, length: 5),
            attributes: [.foregroundColor: EditorTheme.syntaxNoun]))

        composer.applyNow()
        // No crash against a real NSTextLayoutManager is the assertion.
    }
}
