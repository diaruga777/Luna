//
//  ShareSetupPracticeMediaTests.swift
//  LunaTests
//

import AVFoundation
import LunaMediaDownload
import LunaModels
import UIKit
import XCTest
@testable import LunaShareSurface

/// The save lesson rehearses with a practice link, and which rehearsal that link
/// gets is what this pins. The Downloader's link is a VIDEO POST: showing it the
/// article preview taught the Reader's lesson to someone who came for videos —
/// the same mistake the Safari demonstration used to make on `luna.app`.
@MainActor
final class ShareSetupPracticeMediaTests: XCTestCase {

    private var repositoryRoot: URL {
        URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
    }

    // MARK: - Which link stands for what

    func testOnlyTheInstaTokLinkStandsForAVideoPost() throws {
        XCTAssertTrue(ShareSetupPractice.matchesVideoPractice(
            try XCTUnwrap(URL(string: ShareSetupPractice.instaTokURLString))))
        for page in [
            ShareSetupPractice.lunaURLString, ShareSetupPractice.amayzonURLString,
        ] {
            XCTAssertFalse(
                ShareSetupPractice.matchesVideoPractice(
                    try XCTUnwrap(URL(string: page))),
                "\(page) is a page; its rehearsal is the article preview")
        }
    }

    /// The same canonicalisation `matches` uses, so a trailing slash or a
    /// fragment cannot route one practice link to the other's rehearsal.
    func testTheVideoLinkIsRecognizedInItsOtherSpellings() throws {
        for spelling in [
            ShareSetupPractice.instaTokURLString + "/",
            ShareSetupPractice.instaTokURLString + "#top",
        ] {
            XCTAssertTrue(
                ShareSetupPractice.matchesVideoPractice(
                    try XCTUnwrap(URL(string: spelling))),
                spelling)
        }
    }

    func testOnlyTheAmayzonLinkStandsForAProduct() throws {
        XCTAssertTrue(ShareSetupPractice.matchesProductPractice(
            try XCTUnwrap(URL(string: ShareSetupPractice.amayzonURLString))))
        for page in [
            ShareSetupPractice.lunaURLString, ShareSetupPractice.instaTokURLString,
        ] {
            XCTAssertFalse(
                ShareSetupPractice.matchesProductPractice(
                    try XCTUnwrap(URL(string: page))),
                "\(page) is not the Price Tracker's product rehearsal")
        }
    }

    // MARK: - One clip, named in three places

    /// The mock post plays it, the Safari lesson's panel plays it, and the save
    /// lesson "downloads" it. Two of the three name it in Swift; the third is
    /// markup, which no compiler checks against either.
    func testThePageThePanelAndTheRehearsalPlayTheSameFile() throws {
        let html = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Luna/Resources/InstaTok.html"),
            encoding: .utf8)
        XCTAssertTrue(
            html.contains("src=\"\(ShareSetupPractice.videoResourceName).mp4\""),
            "the mock post no longer sources the clip the rehearsal downloads")
    }

    /// The test host is the central Luna app, so the app bundle is the one this
    /// resolves against — the only kind of bundle that carries the clip.
    func testTheClipIsInTheAppBundle() {
        XCTAssertNotNil(
            ShareSetupPractice.bundledVideoURL,
            "the media rehearsal falls back to the article preview without it")
    }

    // MARK: - The rehearsal is a download that happened

    func testTheDownloadBeatIsLongEnoughToBeADownload() {
        XCTAssertGreaterThanOrEqual(
            ShareSetupPracticeDownloadViewController.downloadDuration, 1,
            "a bar that fills in a frame reads as a screen changing its mind")
        XCTAssertLessThanOrEqual(
            ShareSetupPracticeDownloadViewController.downloadDuration, 2.5,
            "the lesson loops; nobody should wait through this twice")
    }

    /// Nothing on the rehearsal but Done answers a touch. The preview is a
    /// picture of a preview — the clip it stands for plays over the sheet — and
    /// a tap that opened a player would leave the lesson inside a modal the
    /// demonstration cannot dismiss.
    func testNothingButDoneAnswersATouch() throws {
        let controller = ShareSetupPracticeDownloadViewController(
            app: .downloader,
            videoURL: try XCTUnwrap(ShareSetupPractice.bundledVideoURL))
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 700)
        controller.view.layoutIfNeeded()

        let controls = Self.controls(in: controller.view)
        XCTAssertEqual(
            controls.count, 1,
            "exactly one control: \(controls.map { type(of: $0) })")
    }

    private static func controls(in view: UIView) -> [UIControl] {
        view.subviews.flatMap { child -> [UIControl] in
            (child as? UIControl).map { [$0] } ?? controls(in: child)
        }
    }

    // MARK: - The rehearsal's clip is on screen

    /// The media rehearsal in an app that links the kind is the PRODUCTION
    /// media screen (`SavedNonTextualViewController`) over a bundled file, and
    /// the clip plays inline in its preview square. It did not: that screen
    /// asks `MediaDownloadablePlatform.supports` before building its media half
    /// at all, and the practice link's fictional `instatok.com` matches no
    /// platform rule — so the Downloader's save lesson ended on a bare
    /// "Saved to Luna" badge with no video in it anywhere.
    func testThePracticeClipPlaysInThePreviewSquare() throws {
        HostedShareSession.current = nil
        let controller = SavedNonTextualViewController(
            articleURLString: ShareSetupPractice.instaTokURLString,
            practiceVideoURL: try XCTUnwrap(ShareSetupPractice.bundledVideoURL),
            onDone: {})
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 760)
        controller.view.layoutIfNeeded()

        let layer = try XCTUnwrap(
            Self.playerLayers(in: controller.view).first,
            "the rehearsal has no player on screen at all")
        XCTAssertNotNil(layer.player, "a player layer with nothing loaded in it")
        XCTAssertGreaterThan(layer.bounds.width, 100)
        XCTAssertGreaterThan(layer.bounds.height, 100)
    }

    /// The gate itself is untouched for everything that is not a rehearsal: a
    /// link Luna cannot pull media from still gets the confirmation and the
    /// exits alone, with no preview promising a file that is never coming.
    func testTheSameLinkWithoutABundledClipShowsNoPlayer() {
        HostedShareSession.current = nil
        let controller = SavedNonTextualViewController(
            articleURLString: ShareSetupPractice.instaTokURLString, onDone: {})
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 760)
        controller.view.layoutIfNeeded()

        XCTAssertTrue(Self.playerLayers(in: controller.view).isEmpty)
    }

    private static func playerLayers(in view: UIView) -> [AVPlayerLayer] {
        let own = (view.layer as? AVPlayerLayer).map { [$0] } ?? []
        return own + view.subviews.flatMap { playerLayers(in: $0) }
    }
}
