//
//  ReaderOnboardingTests.swift
//  LunaTests
//
//  The onboarding BEHAVIORAL core: the completion state machine (per-app
//  ownership, one-way central inheritance, the save leg's capability gate, the
//  reset), what a lesson is allowed to write, the completion → production-root
//  surface swap, and two hit-test guards.
//
//  Deliberately NOT here any more (see the test-trim notes): animation-timing
//  assertions (wave/demo-loop durations, the pulse's rate and curve, the
//  period's exit beat), copy checksums (per-app explainer prose, chunking,
//  feature lists, per-surface configuration string-for-string), artwork
//  geometry (launch composite frames, corona placement, cue silhouette paths)
//  and the Messages-replica suite. Those restate constants the code already
//  states, and between them they accounted for most of this file's 37 window
//  hosts and all five of its 15-second waits.
//

import LunaModels
import LunaDesignSystem
import LunaReaderUI
import LunaShareSurface
import LunaStorage
import XCTest
@testable import Luna

final class ReaderOnboardingTests: XCTestCase {

    // MARK: - Completion state machine

    func testCompletionIsOwnedByInjectedPerAppDefaults() {
        let suite = "ReaderOnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let setup = LunaSetupStatusStore(defaults: defaults)
        let reader = AppOnboardingStore(
            app: .reader, defaults: defaults, setupStatusStore: setup)
        let downloader = AppOnboardingStore(
            app: .downloader, defaults: defaults, setupStatusStore: setup)
        XCTAssertFalse(reader.isCompleted)
        XCTAssertFalse(downloader.isCompleted)
        reader.markCompleted()
        XCTAssertTrue(reader.isCompleted)
        XCTAssertFalse(downloader.isCompleted)
        reader.resetCompletion()

        reader.markSaveSetupHandled()
        XCTAssertTrue(reader.hasHandledSaveSetup)
        XCTAssertFalse(downloader.hasHandledSaveSetup)
        XCTAssertFalse(reader.isCompleted)
        reader.markSafariSetupHandled()
        XCTAssertTrue(reader.hasHandledSafariSetup)
        XCTAssertTrue(reader.isCompleted)
        reader.resetCompletion()
        XCTAssertFalse(reader.isCompleted)
        XCTAssertFalse(reader.hasHandledSaveSetup)
        XCTAssertFalse(reader.hasHandledSafariSetup)
    }

    func testCentralSetupEvidenceSkipsOnlyANewFacetedAppsOnboarding() {
        let suite = "ReaderOnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let setup = LunaSetupStatusStore(defaults: defaults)
        let facet = AppOnboardingStore(
            app: .reader,
            defaults: defaults,
            setupStatusStore: setup,
            saveSetupMode: .actionButtonShortcut)
        setup.recordShortcutRun(for: .luna)
        XCTAssertFalse(facet.isCompleted)

        defaults.set(true, forKey: LunaSetupStatusStore.centralSafariKey)
        XCTAssertTrue(facet.isCompleted)
    }

    /// Inheritance is one-way: a fully configured facet leaves central Luna's
    /// own first run untouched.
    func testAFacetsSetupEvidenceNeverCompletesCentralLuna() {
        let suite = "ReaderOnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let setup = LunaSetupStatusStore(defaults: defaults)
        let central = AppOnboardingStore(
            app: .luna,
            defaults: defaults,
            setupStatusStore: setup,
            saveSetupMode: .actionButtonShortcut)
        setup.recordShortcutInstallPressed(for: .reader)
        setup.recordShortcutRun(for: .reader)
        defaults.set(true, forKey: LunaSetupStatusStore.sharedSafariKey)

        XCTAssertFalse(central.hasFinishedSafariSetup)
        XCTAssertFalse(central.hasFinishedSaveSetup)
        XCTAssertFalse(central.isCompleted)
    }

    /// There is no fallback lesson: a device that cannot run the Action Button
    /// shortcut has no save setup at all, and its util card omits the button.
    func testTheSaveLessonExistsOnlyWhereTheActionButtonShortcutCanRun() {
        func mode(
            os: Int,
            model: String,
            simulator: Bool = false
        ) -> OnboardingSaveSetupMode {
            OnboardingDeviceCapabilities(
                operatingSystemMajorVersion: os,
                modelIdentifier: model,
                isSimulator: simulator).saveSetupMode
        }

        XCTAssertEqual(mode(os: 26, model: "iPhone17,1"), .unavailable)
        XCTAssertEqual(mode(os: 27, model: "iPhone15,4"), .unavailable)
        XCTAssertEqual(mode(os: 27, model: "iPad16,3"), .unavailable)
        XCTAssertEqual(
            mode(os: 27, model: "iPhone17,1", simulator: true),
            .unavailable)
        XCTAssertEqual(mode(os: 27, model: "iPhone16,1"), .actionButtonShortcut)
        XCTAssertEqual(mode(os: 27, model: "iPhone16,2"), .actionButtonShortcut)
        XCTAssertEqual(mode(os: 27, model: "iPhone17,1"), .actionButtonShortcut)
    }

    /// A device with no save lesson owes nothing on that leg, so Safari alone
    /// finishes its first run.
    func testWithNoSaveLessonTheSafariLegAloneCompletesOnboarding() {
        let suite = "ReaderOnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = AppOnboardingStore(
            app: .reader,
            defaults: defaults,
            setupStatusStore: LunaSetupStatusStore(defaults: defaults),
            saveSetupMode: .unavailable)
        XCTAssertTrue(store.hasFinishedSaveSetup)
        XCTAssertFalse(store.isCompleted)

        store.markSafariSetupHandled()

        XCTAssertTrue(store.isCompleted)
    }

    func testOnboardingResetClearsCompletionAndEveryRunEvidence() {
        let suite = "ReaderOnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let onboarding = AppOnboardingStore(app: .reader, defaults: defaults)
        onboarding.markCompleted()
        XCTAssertTrue(onboarding.isCompleted)
        onboarding.resetCompletion()
        XCTAssertFalse(onboarding.isCompleted)

        let status = LunaSetupStatusStore(defaults: defaults)
        defaults.set(true, forKey: LunaSetupStatusStore.sharedSafariKey)
        defaults.set(true, forKey: LunaSetupStatusStore.centralSafariKey)
        status.recordShortcutInstallPressed(for: .reader)
        status.recordShortcutInstallPressed(for: .luna)
        status.recordShortcutRun(for: .reader)
        status.recordShortcutRun(for: .luna)
        status.recordShareActionRun(isCentral: false)
        status.recordShareActionRun(isCentral: true)
        XCTAssertTrue(status.safariHasRun(isCentral: false))
        XCTAssertTrue(status.safariHasRun(isCentral: true))
        XCTAssertTrue(status.shortcutHasRun(for: .reader))
        XCTAssertTrue(status.shortcutHasRun(for: .luna))
        XCTAssertTrue(status.shareActionHasRun(isCentral: false))
        XCTAssertTrue(status.shareActionHasRun(isCentral: true))

        status.resetAllRunEvidence()
        XCTAssertFalse(status.safariHasRun(isCentral: false))
        XCTAssertFalse(status.safariHasRun(isCentral: true))
        XCTAssertFalse(status.shortcutInstallWasPressed(for: .reader))
        XCTAssertFalse(status.shortcutInstallWasPressed(for: .luna))
        XCTAssertFalse(status.shortcutHasRun(for: .reader))
        XCTAssertFalse(status.shortcutHasRun(for: .luna))
        XCTAssertFalse(status.shareActionHasRun(isCentral: false))
        XCTAssertFalse(status.shareActionHasRun(isCentral: true))
    }

    // MARK: - What a lesson may write

    /// An install updating from a build that DID store the demonstration item
    /// loses it at the next launch — and only it.
    func testLaunchSweepRemovesOnlyTheLegacyDemonstrationSave() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReaderOnboardingTests-\(UUID().uuidString)")
        let suite = "ReaderOnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defaults.removePersistentDomain(forName: suite)
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }

        let contentStore = ReadingListStore(containerURL: directory)
        let registry = AppOnboardingStore(app: .luna, defaults: defaults)
        let userSave = contentStore.add(urlString: "https://example.com/real")
        let legacy = contentStore.add(urlString: BundledLunaArticle.urlString)
        registry.recordLegacyTemporarySaveForTesting(identifier: legacy.id)

        BundledLunaArticle.cleanupLegacyTemporarySave(
            registry: registry, in: contentStore)

        XCTAssertNil(contentStore.item(withID: legacy.id))
        XCTAssertEqual(contentStore.item(withID: userSave.id)?.id, userSave.id)
        XCTAssertNil(registry.temporarySaveIdentifier)

        // A second launch has nothing to claim: an unmarked store is untouched.
        BundledLunaArticle.cleanupLegacyTemporarySave(
            registry: registry, in: contentStore)
        XCTAssertEqual(contentStore.items().count, 1)
    }

    func testSharePracticeRecognizesEveryMockLinkWithoutSavingVariants() throws {
        for value in ShareSetupPractice.urlStrings {
            XCTAssertTrue(ShareSetupPractice.matches(try XCTUnwrap(URL(string: value))))
            XCTAssertTrue(ShareSetupPractice.matches(try XCTUnwrap(URL(string: value + "/#demo"))))
        }
        XCTAssertFalse(ShareSetupPractice.matches(
            try XCTUnwrap(URL(string: "https://example.com/about"))))
    }

    /// The save demonstration is no longer a picture — it runs the REAL share
    /// surface over a real link — so "entering a lesson writes nothing" is now an
    /// invariant with teeth rather than a tautology. Entering leaves the deck
    /// exactly as empty as the user left it, and claims no temporary save.
    @MainActor
    func testEnteringALessonWritesNothingToTheStore() throws {
        let suite = "ReaderOnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let registry = AppOnboardingStore(app: .reader, defaults: defaults)
        let productionRoot = UINavigationController(
            rootViewController: UIViewController())
        let onboarding = AppOnboardingViewController(
            configuration: .configuration(for: .reader),
            onboardingStore: registry,
            completion: AppOnboardingCompletion(
                makeCompletedRootViewController: { productionRoot }))
        let window = UIWindow(frame: CGRect(
            origin: .zero, size: AppLaunchGeometry.referenceSize))
        window.rootViewController = onboarding
        window.makeKeyAndVisible()
        onboarding.view.layoutIfNeeded()

        let before = Set(ReadingListStore.shared.items().map(\.id))
        let button = try XCTUnwrap(
            onboarding.view.descendants(of: UIButton.self).first {
                $0.accessibilityLabel == OnboardingStrings.Intro.safariAction.value()
            })
        UIView.setAnimationsEnabled(false)
        defer {
            UIView.setAnimationsEnabled(true)
            window.isHidden = true
        }
        button.sendActions(for: .touchUpInside)
        // The preload — where the demonstration item used to be installed —
        // runs one stage per run-loop turn.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(Set(ReadingListStore.shared.items().map(\.id)), before)
        XCTAssertNil(registry.temporarySaveIdentifier)
    }

    // MARK: - Completion swaps in the production surface

    /// A save from ANY surface answers the first run: the deck's content watch
    /// sees a newer stored identifier while the intro is on screen, latches
    /// completion, and swaps the window's root over to the real app.
    @MainActor
    func testExternalSaveWhileIntroIsVisibleCompletesOnboarding() {
        let suite = "ReaderOnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let registry = AppOnboardingStore(app: .reader, defaults: defaults)
        let changed = Notification.Name("onboarding.externalSave.\(UUID())")
        var identifiers: Set<UUID> = [UUID()]
        let productionRoot = UIViewController()
        productionRoot.view.backgroundColor = .black
        let onboarding = AppOnboardingViewController(
            configuration: .configuration(for: .reader),
            onboardingStore: registry,
            completion: AppOnboardingCompletion(
                contentWatch: OnboardingContentWatch(
                    changeNotifications: [changed],
                    storedIdentifiers: { identifiers }),
                makeCompletedRootViewController: { productionRoot }))
        let window = UIWindow(frame: CGRect(
            origin: .zero, size: AppLaunchGeometry.referenceSize))
        window.rootViewController = onboarding
        window.makeKeyAndVisible()
        onboarding.view.layoutIfNeeded()
        defer { window.isHidden = true }

        identifiers.insert(UUID())
        NotificationCenter.default.post(name: changed, object: nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertTrue(registry.isCompleted)
        XCTAssertTrue(window.rootViewController === productionRoot)
    }

    // MARK: - Layout / hit-test guards

    func testOnboardingLayoutStartsAtOneThirdOfItsContainer() {
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 600)
        XCTAssertEqual(AppOnboardingLayout.contentTop(in: bounds), 220)
    }

    func testSettingsOpenerReportsExhaustedFallbacks() {
        var opened: Bool?
        SystemSettingsLink.openFirstAvailable([]) { opened = $0 }
        XCTAssertEqual(opened, false)
    }

    /// The intro's setup block mounts its two actions plus the paste row, and
    /// nothing of the reveal's staging shadows them once they go live.
    @MainActor
    func testIntroActionsAreMountedAndHittable() throws {
        let intro = OnboardingIntroCardContentViewController(
            introCopy: .twoLines(
                first: "You want to read more.",
                second: "Let’s make that happen."),
            supportingText: OnboardingStrings.Intro.supportingText.value(for: .reader))
        intro.loadViewIfNeeded()

        let window = UIWindow(frame: CGRect(
            origin: .zero, size: AppLaunchGeometry.referenceSize))
        window.rootViewController = intro
        window.makeKeyAndVisible()
        intro.view.frame = window.bounds
        intro.view.layoutIfNeeded()
        defer { window.isHidden = true }

        let buttons = intro.view.descendants(of: UIButton.self)
        let safari = try XCTUnwrap(buttons.first {
            $0.accessibilityLabel == OnboardingStrings.Intro.safariAction.value()
        })
        XCTAssertTrue(buttons.contains {
            $0.accessibilityLabel == OnboardingStrings.Intro.shortcutAction.value()
        })
        // Paste stays in both states, and the system draws its control:
        // nothing of ours is painted over it.
        let pasteControl = try XCTUnwrap(
            intro.view.descendants(of: UIPasteControl.self).first)
        XCTAssertEqual(pasteControl.layer.opacity, 1)

        for action in intro.view.descendants(of: UIControl.self) {
            action.alpha = 1
        }
        intro.setActionsEnabled(true)
        let point = window.convert(
            CGPoint(x: safari.bounds.midX, y: safari.bounds.midY), from: safari)
        let hit = window.hitTest(point, with: nil)
        XCTAssertTrue(
            hit === safari || hit?.isDescendant(of: safari) == true,
            "Safari intro action is shadowed by \(String(describing: hit))")
    }

    /// The Safari lesson end to end, in the REAL hierarchy — the one place the
    /// overlays can shadow each other. Pressing the intro's Safari action
    /// expands the replica full-bleed over the app's production root (mounted
    /// as a CHILD, not swapped in for it); the staged sequence (buried page,
    /// Manage Extensions sheet, wipe) leaves the page's own actions hittable
    /// rather than covered by anything it put up; and skipping returns to an
    /// intro whose Safari button is still ENABLED — a skipped lesson keeps its
    /// button, only a completed one is retired.
    ///
    /// The deadlines below are failure caps, not waits: every loop breaks the
    /// moment its condition holds.
    @MainActor
    func testSafariLessonMountsOverProductionRootAndLeavesItsActionsHittable() throws {
        let suite = "ReaderOnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let productionRoot = UINavigationController(
            rootViewController: UIViewController())
        let onboarding = AppOnboardingViewController(
            configuration: .configuration(for: .reader),
            onboardingStore: AppOnboardingStore(app: .reader, defaults: defaults),
            completion: AppOnboardingCompletion(
                makeCompletedRootViewController: { productionRoot }))
        let window = UIWindow(frame: CGRect(
            origin: .zero,
            size: AppLaunchGeometry.referenceSize))
        window.rootViewController = onboarding
        window.makeKeyAndVisible()
        onboarding.view.layoutIfNeeded()
        defer { window.isHidden = true }

        let button = try XCTUnwrap(
            onboarding.view.descendants(of: UIButton.self).first {
                $0.accessibilityLabel == OnboardingStrings.Intro.safariAction.value()
            })
        button.sendActions(for: .touchUpInside)

        let mountDeadline = Date(timeIntervalSinceNow: 8)
        while Date() < mountDeadline,
              onboarding.children.compactMap({
                  $0 as? SafariReplicaViewController
              }).isEmpty {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        let safari = try XCTUnwrap(
            onboarding.children.compactMap {
                $0 as? SafariReplicaViewController
            }.first)
        XCTAssertEqual(safari.view.frame, onboarding.view.bounds)
        XCTAssertTrue(
            onboarding.savedRootViewControllerForTesting === productionRoot,
            "The save destination must be the app's production root controller")
        XCTAssertTrue(
            productionRoot.parent === onboarding,
            "The production root must be mounted behind Safari during the save")

        // Ride the real staged sequence — the buried page, the Manage
        // Extensions sheet with its toggle, then the wipe — until the page's
        // own actions come out of the sweep hittable.
        func hitView(for label: String) -> (button: UIButton, hit: UIView?)? {
            guard let action = onboarding.view
                .descendants(of: UIButton.self).first(where: {
                    $0.accessibilityLabel == label
                })
            else { return nil }
            let point = window.convert(
                CGPoint(x: action.bounds.midX, y: action.bounds.midY),
                from: action)
            return (action, window.hitTest(point, with: nil))
        }
        func isHittable(_ label: String) -> Bool {
            guard let probe = hitView(for: label) else { return false }
            return probe.hit === probe.button
                || probe.hit?.isDescendant(of: probe.button) == true
        }
        let deadline = Date(timeIntervalSinceNow: 10)
        while Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            if isHittable(OnboardingStrings.Safari.activate.value()),
               isHittable(OnboardingStrings.Safari.skip.value()) { break }
        }

        for label in [
            OnboardingStrings.Safari.activate.value(),
            OnboardingStrings.Safari.skip.value(),
        ] {
            let probe = try XCTUnwrap(hitView(for: label))
            let lunaPage = onboarding.view
                .descendants(of: OnboardingSafariPageView.self).first
            let buttonFrame = window.convert(
                probe.button.bounds, from: probe.button)
            let pageFrame = lunaPage.map {
                window.convert($0.bounds, from: $0)
            }
            XCTAssertTrue(
                probe.hit === probe.button
                    || probe.hit?.isDescendant(of: probe.button) == true,
                """
                \(label) is shadowed by \(String(describing: probe.hit)); \
                button in window: \(buttonFrame), \
                page in window: \(String(describing: pageFrame)), \
                button superview chain: \(sequence(
                    first: probe.button as UIView, next: \.superview)
                    .map { "\(type(of: $0)) \($0.frame) hidden=\($0.isHidden) alpha=\($0.alpha)" }
                    .joined(separator: " <- "))
                """)
        }

        // Skipping finishes only the Safari lesson and app-switches back to
        // the three-action intro card — still enabled, marked skipped rather
        // than completed, since the shortcut lesson isn't done yet.
        let skip = try XCTUnwrap(
            onboarding.view.descendants(of: UIButton.self).first {
                $0.accessibilityLabel == OnboardingStrings.Safari.skip.value()
            })
        skip.sendActions(for: .touchUpInside)
        let introDeadline = Date(timeIntervalSinceNow: 8)
        var safariIntroButton: UIButton?
        while Date() < introDeadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            safariIntroButton = onboarding.view.descendants(of: UIButton.self)
                .first {
                    $0.accessibilityLabel
                        == OnboardingStrings.Intro.safariAction.value()
                }
            if onboarding.view.descendants(of: UIPasteControl.self)
                .first?.isHidden == false
            {
                break
            }
        }
        XCTAssertTrue(try XCTUnwrap(safariIntroButton).isEnabled)
        XCTAssertNil(safariIntroButton?.accessibilityValue)
    }

    /// Every recovery route stays reachable when the external open fails, and
    /// the overlay that says so is modal to assistive technology (hiding its
    /// siblings while it's up, restoring them when it goes).
    @MainActor
    func testExternalOpenFailureKeepsEverySetupRecoveryAvailable() throws {
        let safari = SafariReplicaViewController(
            configuration: .configuration(for: .reader))
        let window = UIWindow(frame: CGRect(
            origin: .zero,
            size: AppLaunchGeometry.referenceSize))
        window.rootViewController = safari
        window.makeKeyAndVisible()
        safari.view.layoutIfNeeded()
        safari.showExternalOpenFailure(destination: .shortcuts)
        defer { window.isHidden = true }

        let mountedLabels = window.descendants(of: UIButton.self)
            .compactMap(\.accessibilityLabel)
        let overlay = window.descendants(of: DemoInstructionOverlay.self).first
        let mountedOverlay = try XCTUnwrap(overlay)
        let obscuredSiblings = window.subviews.filter { $0 !== mountedOverlay }
        XCTAssertTrue(Set(mountedLabels).isSuperset(
            of: Set([
                OnboardingStrings.Instruction.setUpSafari.value(),
                OnboardingStrings.Instruction.installShortcut.value(),
                OnboardingStrings.Instruction.setActionButton.value(),
            ])))
        XCTAssertTrue(mountedOverlay.accessibilityViewIsModal)
        XCTAssertTrue(obscuredSiblings.allSatisfy(\.accessibilityElementsHidden))

        mountedOverlay.removeFromSuperview()
        XCTAssertTrue(obscuredSiblings.allSatisfy {
            !$0.accessibilityElementsHidden
        })
    }
}

private extension UIView {
    func descendants<View: UIView>(of type: View.Type) -> [View] {
        subviews.flatMap { view -> [View] in
            let matching = (view as? View).map { [$0] } ?? []
            return matching + view.descendants(of: type)
        }
    }
}
