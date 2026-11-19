//
//  PluginImportCoordinatorTests.swift
//  LunaTests
//
//  The import path (plugin-platform.md §11.2, §15): preview, then consent
//  only when the preview says to, then install — and never the reverse.
//

import LunaDesignSystem
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
        var installError: Error?
        private(set) var previewCalls: [String] = []
        private(set) var installCalls: [(preview: PluginImportPreview, origin: PluginImportOrigin)] = []

        func preview(sourceText: String) throws -> PluginImportPreview {
            previewCalls.append(sourceText)
            return try previewResult.get()
        }

        func install(_ preview: PluginImportPreview, origin: PluginImportOrigin) throws {
            installCalls.append((preview, origin))
            if let installError { throw installError }
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

    private func preview(requiresConsent: Bool, media: Bool = false) -> PluginImportPreview {
        PluginImportPreview(
            summary: PluginSummary(
                id: "test.plugin", name: "Test Plugin", version: "1.0.0", priority: 0,
                matchesAnyHost: true, hostPatterns: [], produces: media ? [.media] : [.article],
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

    private func bundleURL() throws -> URL {
        let sources = ["one", "two"].map { id in
            """
            /* luna-plugin
            {"id":"test.\(id)","name":"\(id)","version":"1.0.0","api":1,"produces":["article"],"match":{"any":true}}
            */
            luna.register({});
            """
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".lunabundle")
        try PluginBundleArchive.data(sources: sources).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testBundleWaitsForEachMembersConsentAndCancellationStopsTheQueue() throws {
        let importer = FakeImporter()
        importer.previewResult = .success(preview(requiresConsent: true))
        let coordinator = PluginImportCoordinator(importer: importer)
        coordinator.begin(fileURL: try bundleURL(), from: presenter)
        let navigation = try XCTUnwrap(presenter.presentedViewController as? UINavigationController)
        let first = try XCTUnwrap(navigation.topViewController as? PluginConsentViewController)
        XCTAssertEqual(first.title, "1 of 2")
        XCTAssertTrue(importer.installCalls.isEmpty)
        coordinator.pluginConsent(first, didDecide: true, for: preview(requiresConsent: true))
        // Repeated taps must not install twice or skip a member.
        coordinator.pluginConsent(first, didDecide: true, for: preview(requiresConsent: true))
        pollUntil { navigation.topViewController !== first }
        XCTAssertTrue(presenter.presentedViewController === navigation)
        XCTAssertEqual(importer.installCalls.count, 1)
        let second = try XCTUnwrap(navigation.topViewController as? PluginConsentViewController)
        XCTAssertEqual(second.title, "2 of 2")
        pollUntil { navigation.viewControllers.count == 1 }
        coordinator.pluginConsent(second, didDecide: false, for: preview(requiresConsent: true))
        pump()
        XCTAssertEqual(importer.installCalls.count, 1)
        XCTAssertNil(presenter.presentedViewController)
    }

    func testAcceptingEveryBundleMemberClosesTheSharedNavigationController() throws {
        let importer = FakeImporter()
        let preview = preview(requiresConsent: true)
        importer.previewResult = .success(preview)
        let observer = FakeObserver()
        let coordinator = PluginImportCoordinator(importer: importer)
        coordinator.observer = observer
        coordinator.begin(fileURL: try bundleURL(), from: presenter)
        let navigation = try XCTUnwrap(presenter.presentedViewController as? UINavigationController)
        let first = try XCTUnwrap(navigation.topViewController as? PluginConsentViewController)
        coordinator.pluginConsent(first, didDecide: true, for: preview)
        pollUntil { navigation.topViewController !== first }
        let second = try XCTUnwrap(navigation.topViewController as? PluginConsentViewController)
        coordinator.pluginConsent(second, didDecide: true, for: preview)
        pollUntil { self.presenter.presentedViewController == nil }
        XCTAssertEqual(observer.finishedCount, 2)
        XCTAssertEqual(importer.installCalls.count, 2)
        XCTAssertTrue(importer.installCalls.allSatisfy { $0.origin == .files })
    }

    func testBundleUpdatesWithoutNewPermissionsUseTheSharedNavigationController() throws {
        let importer = FakeImporter()
        let preview = sameCapabilityUpdatePreview()
        importer.previewResult = .success(preview)
        let coordinator = PluginImportCoordinator(importer: importer)
        coordinator.begin(fileURL: try bundleURL(), from: presenter)
        let navigation = try XCTUnwrap(presenter.presentedViewController as? UINavigationController)
        let first = try XCTUnwrap(navigation.topViewController as? PluginConsentViewController)
        XCTAssertEqual(first.title, "1 of 2")
        XCTAssertTrue(importer.installCalls.isEmpty)
        coordinator.pluginConsent(first, didDecide: true, for: preview)
        pollUntil { navigation.topViewController !== first }
        XCTAssertTrue(presenter.presentedViewController === navigation)
        XCTAssertEqual(navigation.topViewController?.title, "2 of 2")
        let second = try XCTUnwrap(navigation.topViewController as? PluginConsentViewController)
        coordinator.pluginConsent(second, didDecide: false, for: preview)
        pollUntil { self.presenter.presentedViewController == nil }
        XCTAssertEqual(importer.installCalls.count, 1)
    }

    func testBundleInstallFailureClosesReviewAndReportsTheError() throws {
        let importer = FakeImporter()
        let preview = preview(requiresConsent: true)
        importer.previewResult = .success(preview)
        importer.installError = TestError.parseFailed
        let coordinator = PluginImportCoordinator(importer: importer)
        coordinator.begin(fileURL: try bundleURL(), from: presenter)
        let navigation = try XCTUnwrap(presenter.presentedViewController as? UINavigationController)
        let first = try XCTUnwrap(navigation.topViewController as? PluginConsentViewController)
        coordinator.pluginConsent(first, didDecide: true, for: preview)
        pollUntil { self.presenter.presentedViewController is UIAlertController }
        XCTAssertEqual(importer.installCalls.count, 1)
        XCTAssertFalse(coordinator.isInstalling)
    }

    func testDismissingBundleReviewStopsTheQueue() throws {
        let importer = FakeImporter()
        let preview = preview(requiresConsent: true)
        importer.previewResult = .success(preview)
        let coordinator = PluginImportCoordinator(importer: importer)
        coordinator.begin(fileURL: try bundleURL(), from: presenter)
        let navigation = try XCTUnwrap(presenter.presentedViewController as? UINavigationController)
        let first = try XCTUnwrap(navigation.topViewController as? PluginConsentViewController)
        coordinator.pluginConsent(first, didDecide: true, for: preview)
        pollUntil { navigation.topViewController !== first }
        let presentation = try XCTUnwrap(navigation.presentationController)
        navigation.dismiss(animated: false)
        presentation.delegate?.presentationControllerDidDismiss?(presentation)
        pump()
        XCTAssertEqual(importer.installCalls.count, 1)
        XCTAssertNil(presenter.presentedViewController)
        // The coordinator can start a fresh import after interactive dismissal.
        coordinator.begin(fileURL: try bundleURL(), from: presenter)
        let restarted = try XCTUnwrap(presenter.presentedViewController as? UINavigationController)
        XCTAssertEqual(restarted.topViewController?.title, "1 of 2")
    }

    func testBundleWithoutRequiredConsentsInstallsAllMembersAndNotifies() throws {
        let importer = FakeImporter()
        importer.previewResult = .success(preview(requiresConsent: false))
        let observer = FakeObserver()
        let coordinator = PluginImportCoordinator(importer: importer)
        coordinator.observer = observer
        coordinator.begin(fileURL: try bundleURL(), from: presenter)
        pollUntil { observer.finishedCount == 2 }
        XCTAssertEqual(importer.installCalls.count, 2)
        XCTAssertTrue(importer.installCalls.allSatisfy { $0.origin == .files })
    }

    func testMediaInstallToggleStartsOffAndPassesChoiceOnlyOnAcceptance() throws {
        let importer = FakeImporter()
        importer.previewResult = .success(preview(requiresConsent: true, media: true))
        let coordinator = PluginImportCoordinator(importer: importer)
        coordinator.begin(sourceText: "media", from: presenter)
        let consent = try XCTUnwrap(presenter.presentedViewController as? PluginConsentViewController)
        consent.loadViewIfNeeded()
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let toggle = try XCTUnwrap(descendants(consent.view).compactMap { $0 as? UISwitch }.first)
        XCTAssertFalse(toggle.isOn)
        toggle.isOn = true
        toggle.sendActions(for: .valueChanged)
        XCTAssertTrue(importer.installCalls.isEmpty)
        let accept = try XCTUnwrap(descendants(consent.view).compactMap { $0 as? UIButton }
            .first { $0.configuration?.title == L10n.string("Plugins_consentAllowButton") })
        accept.sendActions(for: .touchUpInside)
        pollUntil { importer.installCalls.count == 1 }
        XCTAssertTrue(try XCTUnwrap(importer.installCalls.first).preview.autoShowSafariPlayer)
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

    func testInvalidPasteCanBeCorrectedAndRetriedInPlace() throws {
        let importer = FakeImporter()
        let coordinator = PluginImportCoordinator(importer: importer)
        let paste = wireAndPresentPaste(coordinator)
        paste.delegate = coordinator
        paste.view.layoutIfNeeded()
        let editor = try XCTUnwrap(paste.view.subviews.compactMap { $0 as? UITextView }.first)
        let button = try XCTUnwrap(paste.view.subviews.compactMap { $0 as? UIButton }.first)
        XCTAssertEqual(editor.bounds.width, min(paste.view.safeAreaLayoutGuide.layoutFrame.width - 32,
                                                LunaLayout.readableWidth), accuracy: 1)
        for source in ["", "   ", "bad header"] {
            editor.text = source
            editor.delegate?.textViewDidChange?(editor)
            XCTAssertEqual(button.isEnabled, source == "bad header")
        }
        button.sendActions(for: .touchUpInside)
        pollUntil { paste.presentedViewController is UIAlertController }
        XCTAssertTrue(presenter.presentedViewController === paste)
        XCTAssertEqual(editor.text, "bad header")
        XCTAssertTrue(importer.installCalls.isEmpty)

        paste.dismiss(animated: false)
        pump()
        importer.previewResult = .success(preview(requiresConsent: false))
        editor.text = "corrected source"
        editor.delegate?.textViewDidChange?(editor)
        button.sendActions(for: .touchUpInside)
        pollUntil { importer.installCalls.count == 1 }
        XCTAssertEqual(importer.previewCalls, ["bad header", "corrected source"])
    }
}
