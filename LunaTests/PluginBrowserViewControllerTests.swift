//
//  PluginBrowserViewControllerTests.swift
//  LunaTests
//

import LunaArchiveReader
import LunaPluginUI
import UIKit
import XCTest

/// The browser step's stage machine (`claudedocs/plans/plugin-platform.md`
/// §8.3): the cover comes off only for a challenge, `done` captures and closes,
/// and an error or a timeout stops the flow with a way out.
@MainActor
final class PluginBrowserViewControllerTests: XCTestCase {

    /// A page that answers scripted probe results and never loads anything.
    private final class FakePage: PluginBrowserPageDriving {
        var stages: [String?] = []
        var result: PluginBrowserResult?
        private(set) var loads = 0
        private(set) var probes = 0
        private(set) var stops = 0

        let pageView = UIView()
        var currentURL: URL? = URL(string: "https://gate.test/here")

        func load(_ request: PluginBrowserRequest) { loads += 1 }

        func probe(_ source: String, completion: @escaping (String?) -> Void) {
            probes += 1
            completion(stages.isEmpty ? nil : stages.removeFirst())
        }

        func capture(completion: @escaping (PluginBrowserResult?) -> Void) {
            completion(result)
        }

        func stopLoading() { stops += 1 }
    }

    private final class Legs: PluginBrowserViewControllerDelegate {
        var finishes: [PluginBrowserResult?] = []
        var opened: [URL] = []

        func pluginBrowser(
            _ controller: PluginBrowserViewController, didFinishWith result: PluginBrowserResult?
        ) {
            finishes.append(result)
        }

        func pluginBrowser(
            _ controller: PluginBrowserViewController, openInSystemBrowser url: URL
        ) {
            opened.append(url)
        }
    }

    private var page: FakePage!
    private var legs: Legs!
    private var now = Date(timeIntervalSince1970: 1_000)

    override func setUp() {
        super.setUp()
        page = FakePage()
        legs = Legs()
        now = Date(timeIntervalSince1970: 1_000)
    }

    /// A mounted controller whose poll timer never fires by itself, so the test
    /// states each tick.
    private func makeController(timeout: TimeInterval = 300) -> PluginBrowserViewController {
        let request = PluginBrowserRequest(
            url: URL(string: "https://gate.test/x")!, detect: "probe()", timeout: timeout)
        let controller = PluginBrowserViewController(
            request: request, title: "Finishing", page: page,
            poller: DOMProbePoller(interval: 3_600), clock: { self.now })
        controller.delegate = legs
        controller.loadViewIfNeeded()
        return controller
    }

    private func cover(of controller: PluginBrowserViewController) -> ChallengeCoverView? {
        controller.view.subviews.compactMap { $0 as? ChallengeCoverView }.first
    }

    private func tick(_ controller: PluginBrowserViewController) {
        controller.probePollerDidTick(DOMProbePoller())
    }

    // MARK: - The cover

    func testThePageIsCoveredBeforeAnyProbeAnswers() {
        let controller = makeController()
        XCTAssertEqual(cover(of: controller)?.isHidden, false)
        XCTAssertEqual(page.loads, 1, "the page loads as the modal appears")
    }

    func testOnlyAChallengeUncoversThePage() {
        let controller = makeController()
        page.stages = ["challenge", "wait"]

        tick(controller)
        XCTAssertEqual(cover(of: controller)?.isHidden, true, "the user has to see the challenge")

        tick(controller)
        XCTAssertEqual(cover(of: controller)?.isHidden, false, "and nothing else")
    }

    func testAPageThatAnswersNothingKeepsWaitingUnderTheCover() {
        let controller = makeController()
        page.stages = [nil]
        tick(controller)
        XCTAssertEqual(cover(of: controller)?.isHidden, false)
        XCTAssertTrue(legs.finishes.isEmpty)
    }

    // MARK: - done

    func testDoneCapturesThePageAndFinishesOnce() {
        let controller = makeController()
        page.result = PluginBrowserResult(
            url: "https://gate.test/done", html: "<html>ok</html>", title: "Done",
            cookieHeader: "a=b", cookies: [])
        page.stages = ["done", "challenge"]

        tick(controller)
        XCTAssertEqual(legs.finishes.count, 1)
        XCTAssertEqual(legs.finishes.first??.html, "<html>ok</html>")

        // A tick that lands after the capture must not reopen the page.
        tick(controller)
        XCTAssertEqual(legs.finishes.count, 1)
        XCTAssertEqual(cover(of: controller)?.isHidden, false)
    }

    // MARK: - Dead ends

    func testAnErrorStopsTheFlowAndOffersTheWayOut() {
        let controller = makeController()
        page.stages = ["error", "challenge"]

        tick(controller)
        XCTAssertTrue(legs.finishes.isEmpty, "a dead end is not an answer")
        XCTAssertEqual(cover(of: controller)?.isHidden, false)
        XCTAssertEqual(cover(of: controller)?.actionButton.isHidden, false)
        XCTAssertEqual(page.stops, 1)

        let probesAfterError = page.probes
        tick(controller)
        XCTAssertEqual(page.probes, probesAfterError, "nothing drives the page after a dead end")
    }

    func testAStepThatRunsOutOfTimeStopsWithoutProbingAgain() {
        let controller = makeController(timeout: 60)
        page.stages = ["challenge"]
        now = now.addingTimeInterval(61)

        tick(controller)
        XCTAssertEqual(page.probes, 0, "the deadline is read before the page is")
        XCTAssertTrue(legs.finishes.isEmpty)
        XCTAssertEqual(cover(of: controller)?.actionButton.isHidden, false)
    }

    func testASheetThePersonPulledDownIsACancelRatherThanASilentWait() {
        let controller = makeController()
        controller.viewDidDisappear(false)

        XCTAssertEqual(legs.finishes.count, 1)
        XCTAssertNil(legs.finishes.first ?? nil, "a pulled-down sheet answered nothing")
    }

    func testAnEndingLunaAlreadyAnsweredIsNotCancelledAgainOnTheWayOut() {
        let controller = makeController()
        page.result = PluginBrowserResult(
            url: "https://gate.test/done", html: "<html>ok</html>", title: "Done",
            cookieHeader: "", cookies: [])
        page.stages = ["done"]
        tick(controller)
        controller.viewDidDisappear(false)

        XCTAssertEqual(legs.finishes.count, 1)
        XCTAssertEqual(legs.finishes.first??.html, "<html>ok</html>")
    }

    func testTheSafariEscapeHandsOverThePageTheUserIsActuallyOn() {
        let controller = makeController()
        page.currentURL = URL(string: "https://gate.test/challenge-frame")
        controller.navigationItem.rightBarButtonItem?.primaryAction?.performWithSender(nil, target: nil)
        XCTAssertEqual(legs.opened.map(\.absoluteString), ["https://gate.test/challenge-frame"])
    }
}
