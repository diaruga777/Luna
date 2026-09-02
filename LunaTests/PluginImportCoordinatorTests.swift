//
//  PluginImportCoordinatorTests.swift
//  LunaTests
//
//  The import path (plugin-platform.md §11.2, §15): preview, then consent
//  only when the preview says to, then install — and never the reverse.
//

import LunaModels
import LunaPluginKit
import LunaPluginUI
import UIKit
import XCTest
@testable import Luna

@MainActor
final class PluginImportCoordinatorTests: XCTestCase {

    private enum TestError: Error { case parseFailed }

    private final class FakeImporter: PluginImporting {
        var previewResult: Result<PluginImportPreview, Error> = .failure(TestError.parseFailed)
        private(set) var previewCalls: [String] = []
        private(set) var installCalls: [(preview: PluginImportPreview, origin: PluginImportOrigin)] = []

        func preview(sourceText: String) throws -> PluginImportPreview {
            previewCalls.append(sourceText)
            return try previewResult.get()
        }

        func install(_ preview: PluginImportPreview, origin: PluginImportOrigin) throws {
            installCalls.append((preview, origin))
        }
    }

    private final class FakeObserver: PluginImportObserving {
        private(set) var finishedCount = 0
        func pluginImportDidFinish(_ coordinator: PluginImportCoordinator) { finishedCount += 1 }
    }

    private var window: UIWindow!
    private var presenter: UIViewController!

    override func setUp() {
        super.setUp()
        UIView.setAnimationsEnabled(false)
        presenter = UIViewController()
        window = UITestSupport.host(presenter)
    }

    override func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
        window = nil
        super.tearDown()
    }

    private func preview(requiresConsent: Bool) -> PluginImportPreview {
        PluginImportPreview(
            summary: PluginSummary(
                id: "test.plugin", name: "Test Plugin", version: "1.0.0", priority: 0,
                matchesAnyHost: true, hostPatterns: [], produces: [.article],
                hooks: [.classify], export: nil, isBundled: false),
            description: nil, capabilities: [.fetch], runsInBackground: false,
            addedCapabilities: requiresConsent ? [.fetch] : [], requiresConsent: requiresConsent,
            replacesVersion: nil, sourceText: "luna.register({});")
    }

    /// An update that declares no capability beyond what was already
    /// consented to — `requiresConsent` is false, so the full consent screen
    /// never appears, but a replacement is still a replacement.
    private func sameCapabilityUpdatePreview() -> PluginImportPreview {
        PluginImportPreview(
            summary: PluginSummary(
                id: "test.plugin", name: "Test Plugin", version: "1.1.0", priority: 0,
                matchesAnyHost: true, hostPatterns: [], produces: [.article],
                hooks: [.classify], export: nil, isBundled: false),
            description: nil, capabilities: [.fetch], runsInBackground: false,
            addedCapabilities: [], requiresConsent: false,
            replacesVersion: "1.0.0", sourceText: "luna.register({});")
    }

    /// `begin(from:sourceView:)` is what wires the coordinator's own presenter —
    /// every other entry point is a delegate callback the coordinator never
    /// presents anything without it having run first. The action sheet it puts
    /// up is dismissed immediately; these tests drive the delegate callbacks
    /// directly rather than tapping its rows.
    private func wireAndPresentPaste(_ coordinator: PluginImportCoordinator) -> PluginPasteImportViewController {
        coordinator.begin(from: presenter, sourceView: nil)
        pump()
        if let sheet = presenter.presentedViewController {
            let dismissed = expectation(description: "action sheet dismissed")
            sheet.dismiss(animated: false) { dismissed.fulfill() }
            wait(for: [dismissed], timeout: 2)
        }
        let paste = PluginPasteImportViewController()
        let presented = expectation(description: "paste sheet presented")
        presenter.present(paste, animated: false) { presented.fulfill() }
        wait(for: [presented], timeout: 2)
        return paste
    }

    private func pump() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    /// Polls `condition` instead of pumping a fixed duration: dismissing the
    /// paste sheet and presenting what comes next both hop through UIKit's own
    /// completion handlers, so how long that takes depends on what else is on
    /// the run loop, not a number this test can predict.
    private func pollUntil(
        timeout: TimeInterval = 2, file: StaticString = #filePath, line: UInt = #line,
        _ condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        XCTFail("condition did not become true within \(timeout)s", file: file, line: line)
    }

    // MARK: - No consent required

    func testAnImportThatNeedsNoConsentInstallsDirectlyAndNotifiesTheObserver() {
        let importer = FakeImporter()
        importer.previewResult = .success(preview(requiresConsent: false))
        let observer = FakeObserver()
        let coordinator = PluginImportCoordinator(importer: importer)
        coordinator.observer = observer
        let paste = wireAndPresentPaste(coordinator)

        coordinator.pluginPasteImport(paste, didSubmit: "luna.register({});")
        // `pluginPasteImport` dismisses the paste sheet before installing, so
        // wait for the install itself rather than pumping a fixed duration.
        pollUntil { observer.finishedCount == 1 }

        XCTAssertEqual(importer.previewCalls, ["luna.register({});"])
        XCTAssertEqual(importer.installCalls.count, 1, "no consent required, so install runs straight away")
        XCTAssertEqual(importer.installCalls.first?.origin, .paste)
        XCTAssertEqual(observer.finishedCount, 1)
        XCTAssertNil(
            presenter.presentedViewController,
            "nothing needs to stay on screen once an unconsented import installs")
    }

    // MARK: - Consent required

    func testAnImportThatNeedsConsentWaitsForAnAnswerBeforeInstalling() {
        let importer = FakeImporter()
        importer.previewResult = .success(preview(requiresConsent: true))
        let observer = FakeObserver()
        let coordinator = PluginImportCoordinator(importer: importer)
        coordinator.observer = observer
        let paste = wireAndPresentPaste(coordinator)

        coordinator.pluginPasteImport(paste, didSubmit: "luna.register({});")
        pollUntil { self.presenter.presentedViewController is PluginConsentViewController }

        XCTAssertEqual(
            importer.installCalls.count, 0, "install must wait for the consent screen's answer")
        guard let consent = presenter.presentedViewController as? PluginConsentViewController else {
            return XCTFail("expected the consent screen to be on screen")
        }

        coordinator.pluginConsent(consent, didDecide: true, for: preview(requiresConsent: true))
        pump()

        XCTAssertEqual(importer.installCalls.count, 1)
        XCTAssertEqual(observer.finishedCount, 1)
    }

    func testDecliningConsentInstallsNothing() {
        let importer = FakeImporter()
        importer.previewResult = .success(preview(requiresConsent: true))
        let observer = FakeObserver()
        let coordinator = PluginImportCoordinator(importer: importer)
        coordinator.observer = observer
        let paste = wireAndPresentPaste(coordinator)

        coordinator.pluginPasteImport(paste, didSubmit: "luna.register({});")
        pollUntil { self.presenter.presentedViewController is PluginConsentViewController }

        guard let consent = presenter.presentedViewController as? PluginConsentViewController else {
            return XCTFail("expected the consent screen to be on screen")
        }
        coordinator.pluginConsent(consent, didDecide: false, for: preview(requiresConsent: true))
        pump()

        XCTAssertTrue(importer.installCalls.isEmpty, "declining must not install")
        XCTAssertEqual(observer.finishedCount, 0)
    }

    // MARK: - A same-capability update

    /// `requiresConsent` is false when an update adds no capability, so the
    /// full consent screen is skipped on purpose — but that must not mean no
    /// signal at all that an installed plugin's whole script was replaced.
    func testASameCapabilityUpdateAsksForConfirmationBeforeInstalling() {
        let importer = FakeImporter()
        importer.previewResult = .success(sameCapabilityUpdatePreview())
        let observer = FakeObserver()
        let coordinator = PluginImportCoordinator(importer: importer)
        coordinator.observer = observer
        let paste = wireAndPresentPaste(coordinator)

        coordinator.pluginPasteImport(paste, didSubmit: "luna.register({});")
        pollUntil { self.presenter.presentedViewController is UIAlertController }

        guard let alert = presenter.presentedViewController as? UIAlertController else {
            return XCTFail("expected a confirmation alert for a same-capability update")
        }
        XCTAssertEqual(alert.actions.map(\.style), [.cancel, .default])
        XCTAssertTrue(
            importer.installCalls.isEmpty, "install must wait for the confirmation")
        XCTAssertEqual(observer.finishedCount, 0)
    }

    // MARK: - A parser error

    func testAParserErrorSurfacesAndInstallsNothing() {
        let importer = FakeImporter()
        importer.previewResult = .failure(TestError.parseFailed)
        let observer = FakeObserver()
        let coordinator = PluginImportCoordinator(importer: importer)
        coordinator.observer = observer
        let paste = wireAndPresentPaste(coordinator)

        coordinator.pluginPasteImport(paste, didSubmit: "not valid js")
        pollUntil { self.presenter.presentedViewController is UIAlertController }

        XCTAssertTrue(importer.installCalls.isEmpty)
        XCTAssertEqual(observer.finishedCount, 0)
        XCTAssertTrue(
            presenter.presentedViewController is UIAlertController,
            "a parse failure must surface as an alert rather than fail silently")
    }
}
