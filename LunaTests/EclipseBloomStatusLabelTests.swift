//
//  EclipseBloomStatusLabelTests.swift
//  LunaTests
//

import LunaDesignSystem
import UIKit
import XCTest

/// The status label every loading surface uses — the action extension's "Opening in
/// Luna…", the archive reader's "Unlocking article…", and the rotating reassurance
/// underneath both. None of it was tested, which is how the reveal-before-layout
/// deadlock shipped: a reveal asked for in view setup returned before applying the
/// text, the view takes its width FROM that text, so bounds stayed zero and the
/// retry could never satisfy its own guard. No surface ever showed a word.
final class EclipseBloomStatusLabelTests: XCTestCase {

    /// A reveal requested before any layout must still put the words on screen, and
    /// must give the view a real size once laid out. This is the regression.
    func testRevealBeforeLayoutStillShowsTextAndSizesItself() {
        let label = EclipseBloomStatusLabel()
        label.numberOfLines = 0
        XCTAssertEqual(label.bounds.width, 0, "precondition: no bounds yet")

        label.reveal("Unlocking article…")
        XCTAssertEqual(label.text, "Unlocking article…",
                       "the text must be applied even with no bounds to sweep")

        // What Auto Layout would ask for: a view that reports a real size is a view
        // whose bounds can become non-zero. Zero here was the deadlock.
        let fitting = label.systemLayoutSizeFitting(
            CGSize(width: 320, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .fittingSizeLevel,
            verticalFittingPriority: .fittingSizeLevel)
        XCTAssertGreaterThan(fitting.width, 0)
        XCTAssertGreaterThan(fitting.height, 0)
    }

    /// Once bounds exist, the parked sweep runs and the text survives it.
    func testParkedRevealRunsAfterLayout() {
        let label = EclipseBloomStatusLabel()
        label.reveal("Still going…")
        label.frame = CGRect(x: 0, y: 0, width: 300, height: 24)
        label.layoutIfNeeded()
        XCTAssertEqual(label.text, "Still going…")
    }

    /// The ordinary path — bounds first, then reveal — is unchanged.
    func testRevealAfterLayoutShowsText() {
        let label = EclipseBloomStatusLabel()
        label.frame = CGRect(x: 0, y: 0, width: 300, height: 24)
        label.layoutIfNeeded()
        label.reveal("Nearly there…")
        XCTAssertEqual(label.text, "Nearly there…")
        XCTAssertTrue(label.usesOnboardingGlyphBloom)
        XCTAssertEqual(
            label.subviews.compactMap { $0 as? UILabel }.count, 1,
            "the bloom must not stack a second full-text label over the final ink")
    }

    /// Rotating loading copy is a whole-phrase replacement. Unlike the intro
    /// headline's second beat, it must never look for a shared run between two
    /// unrelated status messages before it can bloom the new one.
    func testRevealReplacesCompletelyUnrelatedTextWithTheSameGlyphBloom() {
        let label = EclipseBloomStatusLabel()
        label.frame = CGRect(x: 0, y: 0, width: 300, height: 24)
        label.layoutIfNeeded()

        label.reveal("Opening in Luna…")
        label.reveal("Finding the good part…")

        XCTAssertEqual(label.text, "Finding the good part…")
        XCTAssertTrue(label.usesOnboardingGlyphBloom)
    }

    /// A terminal message must not be overwritten by a reveal that was still owed
    /// from before layout — the rate-limited / un-archivable copy is the last word.
    func testTerminalMessageSurvivesAParkedReveal() {
        let label = EclipseBloomStatusLabel()
        label.reveal("Unlocking article…")     // parked: no bounds yet
        label.setTextImmediately("This site can't be archived right now.")
        label.frame = CGRect(x: 0, y: 0, width: 300, height: 48)
        label.layoutIfNeeded()
        XCTAssertEqual(label.text, "This site can't be archived right now.")
    }

    /// The cycler's rotation is what the user reported missing. It replaces the
    /// initial phrase with one of the alternatives, and never gets stuck empty.
    func testStatusCyclerRotatesThroughItsPhrases() {
        let label = EclipseBloomStatusLabel()
        label.frame = CGRect(x: 0, y: 0, width: 300, height: 24)
        label.layoutIfNeeded()
        // The rotation is what's under test, not the shipped three seconds; the
        // interval is a parameter so this can watch one tick go by in 60ms.
        let cycler = ArticleLoadingStatusCycler(
            label: label, initialText: "Opening in Luna…", interval: 0.05,
            alternatives: ["Still going…", "Nearly there…"])
        cycler.start()
        XCTAssertEqual(label.text, "Opening in Luna…")

        let rotated = expectation(description: "phrase rotated")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertNotEqual(label.text, "Opening in Luna…")
            XCTAssertTrue(["Still going…", "Nearly there…"].contains(label.text ?? ""),
                          "got \(label.text ?? "nil")")
            rotated.fulfill()
        }
        wait(for: [rotated], timeout: 6)
        cycler.stop()
    }

    /// The FIRST phrase a spinner shows has nothing to hold continuity with
    /// yet, so its bloom is near-instant; every phrase AFTER it is a real
    /// transition and keeps the full sweep, unchanged.
    func testCyclerBloomsTheFirstPhraseInFastButRotatesAtTheUnchangedSpeed() {
        let label = EclipseBloomStatusLabel()
        label.frame = CGRect(x: 0, y: 0, width: 300, height: 24)
        label.layoutIfNeeded()
        let cycler = ArticleLoadingStatusCycler(
            label: label, initialText: "Opening in Luna…", interval: 0.05,
            alternatives: ["Still going…"])
        cycler.start()

        XCTAssertEqual(
            label.lastResolvedRevealDurationForTesting,
            ArticleLoadingStatusCycler.instantRevealDuration,
            "the spinner's first word must bloom in barely perceptibly")

        let rotated = expectation(description: "phrase rotated")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(label.text, "Still going…")
            XCTAssertEqual(
                label.lastResolvedRevealDurationForTesting, 1.55,
                "the transition between two loading phrases must be untouched")
            rotated.fulfill()
        }
        wait(for: [rotated], timeout: 6)
        cycler.stop()
    }

    func testBloomRasterMatchesVisibleLabelAtDifferentHeights() throws {
        for height: CGFloat in [24, 64] {
            let ink = UILabel(frame: CGRect(x: 0, y: 0, width: 280, height: height))
            ink.font = .systemFont(ofSize: 17)
            ink.text = "Finding the good part…"
            ink.textColor = .white
            ink.textAlignment = .center
            ink.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat()
            format.scale = 3
            let visible = UIGraphicsImageRenderer(size: ink.bounds.size, format: format)
                .image { ink.layer.render(in: $0.cgContext) }
            let bloom = GlyphPixelBloomView(frame: ink.bounds)
            bloom.configure(
                glyphLabel: ink, glyphFrame: ink.bounds,
                circleFrame: CGRect(x: -500, y: 0, width: 1200, height: 1200),
                scale: 3)
            XCTAssertEqual(try XCTUnwrap(bloom.glyphRasterForTesting).pngData(), visible.pngData(),
                           "the bloom must emit from the visible glyphs, including their baseline")
        }
    }

    func testRotationKeepsOutgoingInkUntilTheSameFrontReplacesIt() throws {
        let label = EclipseBloomStatusLabel(frame: CGRect(x: 0, y: 0, width: 300, height: 40))
        label.setTextImmediately("Opening in Luna…")
        label.layoutIfNeeded()
        label.reveal("Still going…", duration: 10)
        let incoming = try XCTUnwrap(label.subviews.compactMap { $0 as? UILabel }.first)
        let old = label.outgoingInkForTesting
        XCTAssertFalse(old.isHidden)
        XCTAssertNotNil(old.contents)
        let incomingMask = try XCTUnwrap(incoming.layer.mask as? CAShapeLayer)
        let outgoingMask = try XCTUnwrap(old.mask as? CAShapeLayer)
        let reveal = try XCTUnwrap(incomingMask.animation(forKey: "eclipseGlyphReveal") as? CABasicAnimation)
        let conceal = try XCTUnwrap(outgoingMask.animation(forKey: "eclipseGlyphConceal") as? CABasicAnimation)
        XCTAssertEqual(reveal.duration, conceal.duration)
        for value in [false, true] {
            let newPath = try XCTUnwrap((value ? reveal.toValue : reveal.fromValue) as! CGPath?)
            let oldPath = try XCTUnwrap((value ? conceal.toValue : conceal.fromValue) as! CGPath?)
            for y in stride(from: CGFloat(1), to: 40, by: 2) {
                let point = CGPoint(x: 150, y: y)
                XCTAssertNotEqual(newPath.contains(point, using: .evenOdd), oldPath.contains(point),
                                  "exactly one phrase supplies ink on either side of the front")
            }
        }
        label.setTextImmediately("Finished")
        XCTAssertTrue(old.isHidden)
        XCTAssertNil(old.contents)
        XCTAssertNil(incoming.layer.mask)
    }

    @MainActor
    func testRotationSettlesIntrinsicLayoutBeforeCapturingBloom() throws {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let label = EclipseBloomStatusLabel()
        LoadingStatusLayout.install(spinner: HorizonSpinnerView(side: 36), label: label, in: container)
        label.setTextImmediately("Loading…")
        container.layoutIfNeeded()
        let oldFrame = label.frame
        label.reveal("Finding the good part…", duration: 10)
        let ink = try XCTUnwrap(label.subviews.compactMap { $0 as? UILabel }.first)
        let bloom = try XCTUnwrap(label.subviews.compactMap { $0 as? GlyphPixelBloomView }.first)
        XCTAssertGreaterThan(label.bounds.width, oldFrame.width)
        XCTAssertEqual(bloom.glyphRasterForTesting?.size, ink.bounds.size)
        let preservedFrame = label.convert(label.outgoingInkForTesting.frame, to: container)
        XCTAssertEqual(preservedFrame.minX, oldFrame.minX, accuracy: 0.001)
        XCTAssertEqual(preservedFrame.minY, oldFrame.minY, accuracy: 0.001)
        XCTAssertEqual(preservedFrame.width, oldFrame.width, accuracy: 0.001)
        XCTAssertEqual(preservedFrame.height, oldFrame.height, accuracy: 0.001)
        let settledFrame = label.frame
        container.layoutIfNeeded()
        XCTAssertEqual(label.frame, settledFrame, "the label must not move away from its captured bloom")
        label.setTextImmediately("Done")
    }

    func testParkedFirstRevealHasNoOutgoingCopy() {
        let label = EclipseBloomStatusLabel()
        label.reveal("Opening in Luna…")
        label.frame = CGRect(x: 0, y: 0, width: 300, height: 24)
        label.layoutIfNeeded()
        XCTAssertTrue(label.outgoingInkForTesting.isHidden)
        XCTAssertNil(label.outgoingInkForTesting.contents)
        label.setTextImmediately(nil)
    }


    @MainActor
    func testRotationFinishesWithOneStableLabel() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        controller.view.backgroundColor = .black
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let label = EclipseBloomStatusLabel()
        let spinner = HorizonSpinnerView(side: 36)
        LoadingStatusLayout.install(spinner: spinner, label: label, in: controller.view)
        label.setTextImmediately("Opening in Luna…")
        window.layoutIfNeeded()
        label.reveal("Finding the good part…", duration: 1.55)
        let stableFrame = label.frame
        for (index, delay) in [0.05, 0.7, 1.2, 1.7].enumerated() {
            let captured = expectation(description: "bloom frame \(index)")
            DispatchQueue.main.asyncAfter(deadline: .now() + (index == 0 ? delay : delay - [0.05, 0.7, 1.2, 1.7][index - 1])) {
                XCTAssertEqual(label.frame, stableFrame)
                let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "Loading bloom \(index)"
                attachment.lifetime = .keepAlways
                self.add(attachment)
                try? image.pngData()?.write(to: URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("luna-bloom-\(index).png"))
                captured.fulfill()
            }
            wait(for: [captured], timeout: 5)
        }
        XCTAssertTrue(label.outgoingInkForTesting.isHidden)
        XCTAssertNil(label.outgoingInkForTesting.contents)
        XCTAssertEqual(label.subviews.compactMap { $0 as? UILabel }.count, 1)
        XCTAssertFalse(label.subviews.contains { $0 is GlyphPixelBloomView })
        XCTAssertEqual(label.text, "Finding the good part…")
    }

}
