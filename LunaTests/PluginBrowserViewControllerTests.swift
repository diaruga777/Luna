//
//  PluginBrowserViewControllerTests.swift
//  LunaTests
//

import LunaArchiveReader
@testable import LunaPluginUI
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
        var holdCapture = false
        var captureCompletion: ((PluginBrowserResult?) -> Void)?

        let pageView = UIView()
        var currentURL: URL? = URL(string: "https://gate.test/here")

        func load(_ request: PluginBrowserRequest) { loads += 1 }

        func probe(_ source: String, completion: @escaping (String?) -> Void) {
            probes += 1
            completion(stages.isEmpty ? nil : stages.removeFirst())
        }

        func capture(completion: @escaping (PluginBrowserResult?) -> Void) {
            if holdCapture { captureCompletion = completion }
            else { completion(result) }
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

    func testPreparingModalAddsPageUnderSameCoverAndNavigationItems() {
        let controller = PluginBrowserViewController(title: "Unlocking")
        controller.delegate = legs
        controller.loadViewIfNeeded()
        let originalCover = cover(of: controller)
        let cancel = controller.navigationItem.leftBarButtonItem
        let safari = controller.navigationItem.rightBarButtonItem
        XCTAssertNotNil(originalCover)
        XCTAssertEqual(controller.view.subviews.count, 1, "no web view before it is needed")
        XCTAssertEqual(safari?.isEnabled, false)
        XCTAssertEqual(cancel?.isEnabled, true, "cancellation is available during silent work")
        controller.start(PluginBrowserRequest(url: URL(string: "https://gate.test/x")!, detect: "probe()"), page: page)
        XCTAssertTrue(cover(of: controller) === originalCover)
        XCTAssertTrue(controller.navigationItem.rightBarButtonItem === safari)
        XCTAssertTrue(controller.navigationItem.leftBarButtonItem === cancel)
        XCTAssertEqual(safari?.isEnabled, true)
        XCTAssertEqual(page.loads, 1)
        XCTAssertTrue(page.pageView.superview === controller.view)
        XCTAssertEqual(originalCover?.spinner.isAnimating, true)
    }

    func testPreparingModalCanBeCancelledBeforeBrowserExists() {
        let controller = PluginBrowserViewController(title: "Unlocking")
        controller.delegate = legs
        controller.loadViewIfNeeded()
        controller.navigationItem.leftBarButtonItem?.primaryAction?.performWithSender(nil, target: nil)
        controller.viewDidDisappear(false)
        XCTAssertEqual(legs.finishes.count, 1)
        XCTAssertNil(legs.finishes.first ?? nil)
    }

    func testRetryKeepsModalAcrossBrowserAnswersAndRejectsStepsAfterCancel() async throws {
        final class Maker: PluginBrowserPageMaking {
            var pages: [FakePage] = []
            func makePage(for request: PluginBrowserRequest) -> any PluginBrowserPageDriving {
                let page = FakePage()
                pages.append(page)
                return page
            }
        }
        let maker = Maker()
        let modal = PluginBrowserModalPresentation(pageMaker: maker)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let presenter = UIViewController()
        window.rootViewController = presenter
        window.isHidden = false
        var cancels = 0
        modal.prepare(from: presenter) { cancels += 1 }
        let navigation = try XCTUnwrap(presenter.presentedViewController as? UINavigationController)
        let controller = try XCTUnwrap(navigation.topViewController as? PluginBrowserViewController)
        controller.loadViewIfNeeded()
        let originalCover = cover(of: controller)
        let request = PluginBrowserRequest(url: URL(string: "https://gate.test/x")!, detect: "'wait'")
        let first = Task { await modal.presentStep(request) }
        while maker.pages.isEmpty { await Task.yield() }
        let result = PluginBrowserResult(url: "https://gate.test/done", html: "<p>done</p>", title: "Done", cookieHeader: "", cookies: [])
        modal.pluginBrowser(controller, didFinishWith: result)
        let answer = await first.value
        XCTAssertEqual(answer?.html, result.html)
        XCTAssertTrue(presenter.presentedViewController === navigation)
        XCTAssertTrue(cover(of: controller) === originalCover)
        XCTAssertTrue(originalCover?.spinner.isAnimating == true)
        XCTAssertEqual(controller.navigationItem.rightBarButtonItem?.isEnabled, false)
        XCTAssertEqual(cancels, 0)
        let second = Task { await modal.presentStep(request) }
        while maker.pages.count < 2 { await Task.yield() }
        modal.pluginBrowser(controller, didFinishWith: nil)
        let cancelled = await second.value
        XCTAssertNil(cancelled)
        XCTAssertEqual(cancels, 1)
        let late = await modal.presentStep(request)
        XCTAssertNil(late)
        XCTAssertEqual(maker.pages.count, 2, "late requests cannot reopen the browser")
        modal.endRetry()
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

    func testStalledCaptureEndsLoadingAndIgnoresALateAnswer() {
        let controller = makeController()
        page.holdCapture = true
        page.stages = ["done", "challenge"]
        tick(controller)
        tick(controller)
        XCTAssertEqual(page.probes, 1, "capturing must not start another probe")
        XCTAssertTrue(cover(of: controller)?.spinner.isAnimating == true)

        now = now.addingTimeInterval(11)
        tick(controller)
        XCTAssertEqual(page.stops, 1)
        XCTAssertEqual(cover(of: controller)?.spinner.isAnimating, false)
        XCTAssertEqual(cover(of: controller)?.actionButton.isHidden, false)

        page.captureCompletion?(PluginBrowserResult(
            url: "https://gate.test/done", html: "<html>late</html>", title: "Late",
            cookieHeader: "", cookies: []))
        XCTAssertTrue(legs.finishes.isEmpty, "a late capture must not dismiss the timeout")
        controller.viewDidDisappear(false)
        XCTAssertEqual(legs.finishes.count, 1)
    }

    func testCaptureDoesNotExtendTheRequestDeadline() {
        let controller = makeController(timeout: 60)
        page.holdCapture = true
        page.stages = ["done"]
        now = now.addingTimeInterval(59)
        tick(controller)
        now = now.addingTimeInterval(2)
        tick(controller)
        XCTAssertEqual(cover(of: controller)?.spinner.isAnimating, false)
        XCTAssertEqual(page.stops, 1)
    }

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
