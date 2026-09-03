//
//  AnnotationLayerTests.swift
//  LunaTests
//

import UIKit
import XCTest
import LunaWriterModels
@testable import LunaWriterReadAlong

final class AnnotationLayerTests: XCTestCase {

    private func makeLayer() -> (AnnotationLayer, RenderingInvalidationSpy) {
        let layer = AnnotationLayer()
        let spy = RenderingInvalidationSpy()
        layer.invalidationDelegate = spy
        return (layer, spy)
    }

    private func mark(
        _ location: Int, _ length: Int, _ kind: Annotation.Kind
    ) -> ResolvedAnnotation {
        ResolvedAnnotation(
            id: AnnotationID(), range: NSRange(location: location, length: length), kind: kind)
    }

    func testEachKindDrawsItsOwnUnderlineColour() {
        let (layer, _) = makeLayer()
        let kinds: [Annotation.Kind] = [.needsWork, .expand, .cut, .keep]
        layer.setAnnotations(kinds.enumerated().map { mark($0.offset * 10, 5, $0.element) })

        for (index, kind) in kinds.enumerated() {
            let runs = layer.attributes(in: NSRange(location: index * 10, length: 5))
            XCTAssertEqual(runs.count, 1)
            XCTAssertEqual(
                runs.first?.1[.underlineColor] as? UIColor, ReadAlongTheme.colour(for: kind))
            XCTAssertNil(
                runs.first?.1[.backgroundColor], "only a comment washes the text behind it")
        }
    }

    func testACommentAlsoWashesTheTextBehindIt() {
        let (layer, _) = makeLayer()
        layer.setAnnotations([mark(0, 8, .comment)])
        let runs = layer.attributes(in: NSRange(location: 0, length: 8))
        XCTAssertEqual(runs.first?.1[.underlineColor] as? UIColor, ReadAlongTheme.comment)
        XCTAssertEqual(
            runs.first?.1[.backgroundColor] as? UIColor,
            ReadAlongTheme.comment.withAlphaComponent(ReadAlongTheme.commentWashAlpha))
    }

    func testRunsAreClippedToTheRangeTheDrawerAskedFor() {
        let (layer, _) = makeLayer()
        layer.setAnnotations([mark(10, 20, .cut)])

        XCTAssertEqual(
            layer.attributes(in: NSRange(location: 0, length: 15)).first?.0,
            NSRange(location: 10, length: 5))
        XCTAssertTrue(layer.attributes(in: NSRange(location: 40, length: 10)).isEmpty)
    }

    func testTheTopmostMarkWinsATapWhereTwoOverlap() {
        let (layer, _) = makeLayer()
        let under = mark(0, 20, .keep)
        let over = mark(5, 5, .cut)
        layer.setAnnotations([under, over])

        XCTAssertEqual(layer.annotation(at: 6)?.id, over.id)
        XCTAssertEqual(layer.annotation(at: 15)?.id, under.id)
        XCTAssertNil(layer.annotation(at: 30))
    }

    func testEveryChangeInvalidatesTheTextItCouldHaveChanged() {
        let (layer, spy) = makeLayer()
        layer.setAnnotations([mark(10, 5, .cut)])
        XCTAssertEqual(spy.ranges.last, NSRange(location: 10, length: 5))

        let second = mark(40, 5, .keep)
        layer.add(second)
        XCTAssertEqual(spy.ranges.last, NSRange(location: 40, length: 5))

        layer.remove(second.id)
        XCTAssertEqual(spy.ranges.last, NSRange(location: 40, length: 5))

        layer.removeAll()
        XCTAssertEqual(
            spy.ranges.last, NSRange(location: 10, length: 5),
            "clearing must repaint what the last mark covered")
    }

    func testAnEmptyRangeIsNotAMark() {
        let (layer, spy) = makeLayer()
        layer.add(mark(4, 0, .cut))
        XCTAssertTrue(layer.annotations.isEmpty)
        XCTAssertEqual(spy.count, 0)
    }

    func testAddingTheSameMarkAgainReplacesItRatherThanStacking() {
        let (layer, _) = makeLayer()
        let id = AnnotationID()
        layer.add(ResolvedAnnotation(id: id, range: NSRange(location: 0, length: 5), kind: .cut))
        layer.add(ResolvedAnnotation(id: id, range: NSRange(location: 0, length: 5), kind: .keep))

        XCTAssertEqual(layer.annotations.count, 1)
        XCTAssertEqual(layer.annotations.first?.kind, .keep)
    }
}
