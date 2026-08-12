//
//  SafariVideoOverlayReplicaTests.swift
//  LunaTests
//

import LunaModels
import XCTest
@testable import Luna

/// The Downloader's Safari lesson replicates a panel that lives in another
/// language, in another process, in a file no compiler checks against this one:
/// `presentVideoOverlay` in `LunaSafari/Resources/content.js`. Nothing but this
/// suite can notice the two drifting apart.
///
/// It holds the numbers the two share against the JS SOURCE rather than against
/// a copy of them, so changing the extension's panel fails here naming the value
/// that moved — the same shape as `LeanProductURLParityTests`.
@MainActor
final class SafariVideoOverlayReplicaTests: XCTestCase {

    private var repositoryRoot: URL {
        URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8)
    }

    /// Just the player panel's own builder, so a measurement that happens to
    /// appear elsewhere in a 2,500-line file cannot satisfy an assertion here.
    private func videoOverlayBuilder() throws -> String {
        let content = try source("LunaSafari/Resources/content.js")
        let start = try XCTUnwrap(
            content.range(of: "function presentVideoOverlay("),
            "content.js no longer builds the player panel in presentVideoOverlay")
        let end = try XCTUnwrap(
            content.range(
                of: "\n    function autoPresentVideoOverlay(",
                range: start.upperBound..<content.endIndex))
        return String(content[start.lowerBound..<end.lowerBound])
    }

    private func makeOverlay(
        in size: CGSize = CGSize(width: 393, height: 852)
    ) -> (OnboardingVideoDownloadOverlayView, UIWindow) {
        let overlay = OnboardingVideoDownloadOverlayView(
            configuration: .configuration(for: .downloader))
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.addSubview(overlay)
        overlay.frame = window.bounds
        window.makeKeyAndVisible()
        // The player state, without the clock or the decoder — every assertion
        // here is about the panel, not about how long it waits.
        overlay.enterPlayerStateForTesting()
        return (overlay, window)
    }

    // MARK: - Which lesson each app runs

    func testOnlyTheDownloaderTeachesSafariThroughTheBlockedPost() {
        XCTAssertEqual(
            OnboardingSurfaceConfiguration.configuration(for: .downloader)
                .safariLesson,
            .videoDownload)
        XCTAssertEqual(
            OnboardingSurfaceConfiguration.configuration(for: .downloader)
                .demoPages,
            [.instaTok],
            """
            The blocked post IS the Downloader's lesson: a browser that rotated \
            away from it would take the panel's own page out from under it.
            """)
        XCTAssertEqual(
            OnboardingSurfaceConfiguration.configuration(for: .priceTracker)
                .safariLesson,
            .priceComparison,
            "the price tracker has its own demonstration, on its own page")
        for app in [LunaApp.luna, .reader] {
            XCTAssertEqual(
                OnboardingSurfaceConfiguration.configuration(for: app)
                    .safariLesson,
                .extensionExplainer,
                "\(app) teaches the extension on a page, not on a video")
            XCTAssertTrue(
                OnboardingSurfaceConfiguration.configuration(for: app)
                    .demoPages.contains(.lunaPage))
        }
    }

    // MARK: - The panel is the extension's panel

    func testThePanelRepeatsTheExtensionsOwnMeasurements() throws {
        let builder = try videoOverlayBuilder()
        let content = try source("LunaSafari/Resources/content.js")
        let (overlay, window) = makeOverlay()
        defer { window.isHidden = true }

        // The panel: `calc(100vw - 24px)`, capped, at radius 20.
        XCTAssertTrue(builder.contains(#"width: "calc(100vw - 24px)""#))
        XCTAssertTrue(builder.contains(#"maxWidth: "640px""#))
        XCTAssertTrue(builder.contains(#"borderRadius: "20px""#))
        let panel = overlay.panelFrameForTesting
        XCTAssertEqual(panel.width, min(393 - 24, 640), accuracy: 0.5)
        XCTAssertEqual(overlay.panelCornerRadiusForTesting, 20, accuracy: 0.01)

        // The close button: a 34pt circle.
        XCTAssertTrue(builder.contains(#"width: "34px", height: "34px""#))
        XCTAssertEqual(overlay.closeFrameForTesting.width, 34, accuracy: 0.01)
        XCTAssertEqual(overlay.closeFrameForTesting.height, 34, accuracy: 0.01)

        // The stage: the panel's 10pt padding either side of it. Its ASPECT is
        // a deliberate deviation from the extension's own 16:9 — the lesson's
        // bundled clip is portrait, so the replica's stage is 9:16 — so that
        // one parity check is intentionally not pinned here; see
        // `OnboardingVideoDownloadOverlayView.stageAspect`.
        XCTAssertTrue(builder.contains(#"aspectRatio: "16 / 9""#))
        XCTAssertTrue(builder.contains(#"padding: "10px""#))
        let stage = overlay.stageFrameForTesting
        XCTAssertEqual(stage.width, panel.width - 20, accuracy: 0.5)
        XCTAssertEqual(stage.height, (stage.width * 16 / 9).rounded(), accuracy: 1)

        // The download button: full width, 44 tall at least, in the media kind's
        // tint — which is the Downloader's identity colour, so the lesson's
        // button and the extension's are the same button.
        XCTAssertTrue(builder.contains(#"minHeight: "44px""#))
        XCTAssertTrue(content.contains(##"downloader: "#CC7609""##))
        XCTAssertTrue(content.contains(##"NIGHT_SURFACE = "#0b0b10""##))
        XCTAssertTrue(
            builder.contains(#"background: tint, color: tintForeground(tint)"#),
            "the extension's download button no longer takes the pill's tint")
        let download = overlay.downloadFrameForTesting
        XCTAssertEqual(download.width, stage.width, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(download.height, 44)
        assertColour(
            overlay.downloadColourForTesting, isHex: 0xCC7609, "download button")
        assertColour(overlay.panelColourForTesting, isHex: 0x0b0b10, "panel")
    }

    /// One string, in two files, because one of the two is a web extension.
    func testTheDownloadButtonSaysWhatTheExtensionSays() throws {
        let messages = try source("LunaSafari/Resources/_locales/en/messages.json")
        let parsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(messages.utf8))
                as? [String: [String: Any]])
        XCTAssertEqual(
            OnboardingStrings.Safari.playerDownload.value(for: .downloader),
            parsed["downloadInLuna"]?["message"] as? String)
    }

    // MARK: - The page it is an answer to stays on screen

    /// The one place the replica deliberately parts company with `content.js`.
    /// In Safari the backdrop buries the page you already know; in the lesson
    /// that page is the question the panel answers, so it has to stay legible
    /// behind it for the whole demonstration — which is now just the one
    /// player state, since the panel no longer grows a second one.
    func testTheBlockedPostIsStillVisibleBehindThePanel() throws {
        let builder = try videoOverlayBuilder()
        XCTAssertTrue(
            builder.contains(#"background: "rgba(0, 0, 0, 0.78)""#),
            "the extension's own backdrop moved; the deviation below is stated against it")

        let (overlay, window) = makeOverlay()
        defer { window.isHidden = true }

        XCTAssertLessThan(
            overlay.backdropDarknessForTesting, 0.5,
            "the player state buries the post the lesson is about")
        XCTAssertGreaterThan(
            overlay.backdropDarknessForTesting, 0,
            "the panel still has to read as something in FRONT of the page")
        XCTAssertLessThan(overlay.backdropBlurWeightForTesting, 1)
    }

    /// The wall still establishes the premise, while the player only needs a
    /// short beat before the shared setup flow advances.
    func testPlayerAdvancesAfterAShortPlaybackBeat() {
        XCTAssertGreaterThanOrEqual(
            OnboardingVideoDownloadTiming.pageHoldDuration, 2.5,
            "the sign-up wall is the lesson's premise and has to be read")
        XCTAssertLessThanOrEqual(
            OnboardingVideoDownloadTiming.playbackHoldDuration, 1,
            "the next onboarding stage should not wait through the video")
        XCTAssertGreaterThan(
            OnboardingVideoDownloadTiming.playbackHoldDuration,
            OnboardingVideoDownloadTiming.presentDuration,
            "the player should be visibly underway before advancing")
    }

    // MARK: - The stage fits on the shortest phone

    /// The panel stays in its one player state for the whole lesson now — the
    /// grow beat that used to swap the download button for enable steps is
    /// gone, that ask having moved to the shared setup popup. What remains to
    /// verify is that the now-portrait stage still fits: the shortest phone
    /// Luna ships to is the one a full-height 9:16 stage does not fit on, and
    /// letterboxing the clip is the give that costs the lesson nothing.
    func testTheStageLetterboxesToFitOnTheShortestPhone() throws {
        let (overlay, window) = makeOverlay(in: CGSize(width: 375, height: 667))
        defer { window.isHidden = true }

        let panel = overlay.panelFrameForTesting
        let stage = overlay.stageFrameForTesting
        XCTAssertGreaterThanOrEqual(panel.minY, 0)
        XCTAssertLessThanOrEqual(
            panel.maxY,
            overlay.bounds.height - SafariBottomBar.reservedPageHeight)
        // Letterboxed rather than its full portrait height: on this phone the
        // ideal 9:16 box would overrun the panel's own budget.
        XCTAssertLessThan(
            stage.height, (stage.width * 16 / 9).rounded(),
            "the shortest phone has to letterbox the portrait clip")
        XCTAssertGreaterThan(
            stage.height, 0, "a stage collapsed to nothing is not a letterbox")
    }

    // MARK: - Nothing in the panel answers a tap

    /// Not even an activate/skip pair any more: that ask now lives on the
    /// shared, window-hosted setup popup rather than inside the panel, so
    /// NOTHING in the panel should intercept a touch.
    func testNothingInThePanelAnswersATouch() throws {
        let (overlay, window) = makeOverlay()
        defer { window.isHidden = true }

        func hit(_ point: CGPoint) -> UIView? {
            window.hitTest(window.convert(point, from: overlay), with: nil)
        }
        for (name, frame) in [
            ("close button", overlay.closeFrameForTesting.offsetBy(
                dx: overlay.panelFrameForTesting.minX,
                dy: overlay.panelFrameForTesting.minY)),
            ("video stage", overlay.stageFrameForTesting),
            ("download button", overlay.downloadFrameForTesting),
        ] {
            let target = hit(CGPoint(x: frame.midX, y: frame.midY))
            XCTAssertFalse(
                target is UIControl,
                "\(name) is a picture of a control and must not answer a tap")
        }
    }

    // MARK: -

    private func assertColour(
        _ colour: UIColor?, isHex hex: Int, _ what: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard colour?.getRed(&red, green: &green, blue: &blue, alpha: &alpha) == true
        else {
            XCTFail("\(what) has no resolvable colour", file: file, line: line)
            return
        }
        let components = [red, green, blue].map { Int(($0 * 255).rounded()) }
        let expected = [(hex >> 16) & 0xFF, (hex >> 8) & 0xFF, hex & 0xFF]
        XCTAssertEqual(
            components, expected,
            "\(what) is not the extension's own colour", file: file, line: line)
    }
}
