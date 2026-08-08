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

        // The stage: 16:9, and the panel's 10pt padding either side of it.
        XCTAssertTrue(builder.contains(#"aspectRatio: "16 / 9""#))
        XCTAssertTrue(builder.contains(#"padding: "10px""#))
        let stage = overlay.stageFrameForTesting
        XCTAssertEqual(stage.width, panel.width - 20, accuracy: 0.5)
        XCTAssertEqual(stage.height, (stage.width * 9 / 16).rounded(), accuracy: 1)

        // The download button: full width, 44 tall at least, in QUEUE_INDIGO.
        XCTAssertTrue(builder.contains(#"minHeight: "44px""#))
        XCTAssertTrue(content.contains(##"QUEUE_INDIGO = "#5856D6""##))
        XCTAssertTrue(content.contains(##"NIGHT_SURFACE = "#0b0b10""##))
        let download = overlay.downloadFrameForTesting
        XCTAssertEqual(download.width, stage.width, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(download.height, 44)
        assertColour(
            overlay.downloadColourForTesting, isHex: 0x5856D6, "download button")
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

    // MARK: - The growth

    func testTheGrowthExtendsDownwardAndLeavesTheVideoWhereItWas() throws {
        let (overlay, window) = makeOverlay()
        defer { window.isHidden = true }

        let stageBefore = overlay.stageFrameForTesting
        let panelBefore = overlay.panelFrameForTesting
        XCTAssertFalse(overlay.isShowingSetupInstructionsForTesting)

        overlay.revealSetupInstructions()
        overlay.layoutIfNeeded()
        let stageAfter = overlay.stageFrameForTesting
        let panelAfter = overlay.panelFrameForTesting

        XCTAssertTrue(overlay.isShowingSetupInstructionsForTesting)

        // The stage never resizes: it is measured once, for both states, so the
        // clip cannot change shape under the growth.
        XCTAssertEqual(stageBefore.height, stageAfter.height, accuracy: 0.5)
        XCTAssertEqual(stageBefore.width, stageAfter.width, accuracy: 0.5)
        XCTAssertEqual(stageBefore.minX, stageAfter.minX, accuracy: 0.5)

        // The growth is a BOTTOM edge travelling down. The top may rise, but
        // only as far as keeping the taller panel on the page requires — here,
        // an order of magnitude less than the bottom travels.
        let bottomTravel = panelAfter.maxY - panelBefore.maxY
        let topTravel = panelBefore.minY - panelAfter.minY
        XCTAssertGreaterThan(
            bottomTravel, 100,
            "the setup block has to have made the panel meaningfully taller")
        XCTAssertGreaterThanOrEqual(topTravel, 0, "the panel never sinks")
        XCTAssertGreaterThan(bottomTravel, topTravel * 5)
        XCTAssertEqual(
            stageBefore.minY - stageAfter.minY, topTravel, accuracy: 0.5,
            "the stage is rigid inside the panel; it moves only with its top")
        XCTAssertLessThanOrEqual(
            panelAfter.maxY,
            overlay.bounds.height - SafariBottomBar.reservedPageHeight,
            "the grown panel still clears the mock browser bar")
    }

    /// The shortest phone Luna ships to is the one the setup block does not fit
    /// on at a full-height stage; it letterboxes the clip rather than pushing
    /// the buttons off the page.
    func testTheGrownPanelStaysOnTheShortestPhone() throws {
        let (overlay, window) = makeOverlay(in: CGSize(width: 375, height: 667))
        defer { window.isHidden = true }
        overlay.revealSetupInstructions()
        overlay.layoutIfNeeded()

        let panel = overlay.panelFrameForTesting
        XCTAssertGreaterThanOrEqual(panel.minY, 0)
        XCTAssertLessThanOrEqual(
            panel.maxY,
            overlay.bounds.height - SafariBottomBar.reservedPageHeight)
        XCTAssertTrue(
            overlay.activateButtonForTesting.isUserInteractionEnabled,
            "the Safari button is the way out of the lesson and must be live")
    }

    // MARK: - Nothing else answers a tap

    func testOnlyTheLessonsOwnActionsTakeATouch() throws {
        let (overlay, window) = makeOverlay()
        defer { window.isHidden = true }
        overlay.revealSetupInstructions()
        overlay.layoutIfNeeded()

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

        let activate = overlay.activateButtonForTesting
        let centre = overlay.convert(
            CGPoint(x: activate.bounds.midX, y: activate.bounds.midY),
            from: activate)
        let target = hit(centre)
        XCTAssertTrue(
            target === activate || target?.isDescendant(of: activate) == true,
            "Activate Safari is shadowed by \(String(describing: target))")
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
