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
            introCopy: OnboardingIntroCopy(
                initialText: "You want to read more.",
                finalText: "Let’s make that happen."))
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

    // MARK: - The headline is a diff between two states

    // Ported wholesale from main's `feat(onboarding): every app's headline is
    // a diff between two states`. This file was cut from 52 tests to 15 on this
    // branch, but that trim removed coverage that RESTATED code; these are the
    // shipped feature's own proofs — the shared-run algorithm, its no-run
    // fallback, and the per-app invariant — plus the layout consequences that
    // only exist because the headline now animates around an anchor.

    func testIntroStagesTheSameRevealAcrossEveryFragment() throws {
        let intro = OnboardingIntroCardContentViewController(
            introCopy: OnboardingIntroCopy(
                initialText: "You want to read.",
                finalText: "You want to read more."))
        intro.loadViewIfNeeded()
        intro.view.frame = CGRect(x: 0, y: 0, width: 354, height: 629)
        intro.view.layoutIfNeeded()

        // Both sides of the difference plus the run they share, every one of
        // them waiting behind the same front.
        let lines = intro.view.descendants(of: MoonRevealLineView.self)
        XCTAssertEqual(lines.count, 3)
        for line in lines {
            XCTAssertFalse(line.isFullyRevealed)
            XCTAssertFalse(line.occluderHasVisibleChrome)
            XCTAssertTrue(line.usesGlyphEdgeIllumination)
        }

        let buttons = intro.view.descendants(of: UIButton.self)
        XCTAssertEqual(intro.view.backgroundColor, .black)
        XCTAssertFalse(intro.view.subviews.contains {
            $0.accessibilityIdentifier
                == OnboardingStrings.Accessibility.introIconCluster.value()
        })
        XCTAssertTrue(buttons.contains {
            $0.accessibilityLabel == OnboardingStrings.Intro.safariAction.value()
                && $0.configuration?.image != nil
        })
        XCTAssertTrue(buttons.contains {
            $0.accessibilityLabel
                == OnboardingStrings.Intro.shortcutAction.value()
                && $0.configuration?.image != nil
        })
        let pasteControl = try XCTUnwrap(
            intro.view.descendants(of: UIPasteControl.self).first)
        // The system draws it: nothing of ours is painted over the control.
        XCTAssertEqual(pasteControl.layer.opacity, 1)
        XCTAssertTrue(intro.view.descendants(of: UITextField.self).contains {
            $0.placeholder == OnboardingStrings.Intro.paste.value()
                && !$0.isUserInteractionEnabled
        })
        let button = try XCTUnwrap(buttons.first {
            $0.accessibilityLabel == OnboardingStrings.Intro.safariAction.value()
        })
        let tintAlpha = try XCTUnwrap(
            button.configuration?.baseBackgroundColor?.cgColor.alpha)
        XCTAssertEqual(tintAlpha, 0.24, accuracy: 0.001)

        let window = UIWindow(frame: CGRect(
            origin: .zero, size: AppLaunchGeometry.referenceSize))
        window.rootViewController = intro
        window.makeKeyAndVisible()
        intro.view.frame = window.bounds
        intro.view.layoutIfNeeded()
        for action in intro.view.descendants(of: UIControl.self) {
            action.alpha = 1
        }
        intro.setActionsEnabled(true)
        defer { window.isHidden = true }
        let point = window.convert(
            CGPoint(x: button.bounds.midX, y: button.bounds.midY),
            from: button)
        let hit = window.hitTest(point, with: nil)
        XCTAssertTrue(
            hit === button || hit?.isDescendant(of: button) == true,
            "Safari intro action is shadowed by \(String(describing: hit))")
    }

    func testHeadlineTransitionKeepsTheLongestRunTheTwoStatesShare() {
        // Growth on the right: the whole first state is the anchor.
        let reader = OnboardingHeadlineTransition(from: "Read.", to: "Read more.")
        XCTAssertEqual(reader.shared, "Read")
        XCTAssertEqual(reader.initialPrefix, "")
        XCTAssertEqual(reader.initialSuffix, ".")
        XCTAssertEqual(reader.finalPrefix, "")
        XCTAssertEqual(reader.finalSuffix, " more.")

        // Growth on the LEFT, with a letter changing case at the seam: the
        // capital leaves with the words in front of it.
        let price = OnboardingHeadlineTransition(
            from: "Miss a sale", to: "Never miss a sale")
        XCTAssertEqual(price.shared, "iss a sale")
        XCTAssertEqual(price.initialPrefix, "M")
        XCTAssertEqual(price.initialSuffix, "")
        XCTAssertEqual(price.finalPrefix, "Never m")
        XCTAssertEqual(price.finalSuffix, "")

        // Both sides at once, and the anchor carries its trailing space.
        let downloader = OnboardingHeadlineTransition(
            from: "Sign in to watch.", to: "No Sign in to download.")
        XCTAssertEqual(downloader.shared, "Sign in to ")
        XCTAssertEqual(downloader.initialPrefix, "")
        XCTAssertEqual(downloader.initialSuffix, "watch.")
        XCTAssertEqual(downloader.finalPrefix, "No ")
        XCTAssertEqual(downloader.finalSuffix, "download.")

        // The anchor is a run, not a word: it may start mid-word on both sides.
        let luna = OnboardingHeadlineTransition(
            from: "All your Luna apps.", to: "One Luna app.")
        XCTAssertEqual(luna.shared, " Luna app")
        XCTAssertEqual(luna.initialPrefix, "All your")
        XCTAssertEqual(luna.initialSuffix, "s.")
        XCTAssertEqual(luna.finalPrefix, "One")
        XCTAssertEqual(luna.finalSuffix, ".")

        for transition in [reader, price, downloader, luna] {
            XCTAssertFalse(transition.isFullReplacement)
            XCTAssertEqual(
                transition.initialText,
                transition.initialPrefix + transition.shared
                    + transition.initialSuffix)
            XCTAssertEqual(
                transition.finalText,
                transition.finalPrefix + transition.shared + transition.finalSuffix)
        }
    }

    func testHeadlineTransitionReplacesItselfWhenNoRunIsWorthStandingStillFor() {
        for (initial, final) in [
            ("Read.", "Watch."),          // nothing in common at all
            ("Miss a sale", "Never!"),    // one letter, and a coincidence
            ("Hi!", "Ho!"),               // two characters, neither a word
        ] {
            let transition = OnboardingHeadlineTransition(from: initial, to: final)
            XCTAssertTrue(
                transition.isFullReplacement,
                "\(initial) → \(final) should replace itself outright")
            XCTAssertEqual(transition.initialPrefix, initial)
            XCTAssertEqual(transition.finalPrefix, final)
            XCTAssertEqual(transition.initialSuffix, "")
            XCTAssertEqual(transition.finalSuffix, "")
            XCTAssertEqual(transition.departingFragments, [initial])
            XCTAssertEqual(transition.arrivingFragments, [final])
        }
    }

    func testEveryAppsHeadlineHoldsSomethingStillAcrossItsTwoBeats() {
        for app in LunaApp.allCases {
            let copy = OnboardingStrings.introCopy(for: app)
            let transition = OnboardingHeadlineTransition(
                from: copy.initialText, to: copy.finalText)
            XCTAssertFalse(
                transition.isFullReplacement,
                "\(app)'s headline animates a difference, not a replacement")
            XCTAssertFalse(
                transition.arrivingFragments.isEmpty
                    && transition.departingFragments.isEmpty,
                "\(app)'s second beat has to have something to say")
        }
    }

    func testIntroCentresTheFinishedSentenceAndNeverMovesWhatBothStatesShare() throws {
        let intro = OnboardingIntroCardContentViewController(
            introCopy: OnboardingStrings.introCopy(for: .reader))
        intro.loadViewIfNeeded()
        intro.view.frame = CGRect(x: 0, y: 0, width: 354, height: 629)
        intro.view.layoutIfNeeded()

        let headline = try XCTUnwrap(
            intro.view.subviews.compactMap {
                $0 as? OnboardingIntroHeadlineView
            }.first)
        let fragments = headline.fragments
        let shared = try XCTUnwrap(fragments.shared)
        let departing = try XCTUnwrap(fragments.initialSuffix)
        let arriving = try XCTUnwrap(fragments.finalSuffix)
        XCTAssertNil(fragments.initialPrefix, "Reader's copy grows on the right")
        XCTAssertNil(fragments.finalPrefix)

        XCTAssertEqual(
            headline.frame.minY,
            AppOnboardingLayout.contentTop(in: intro.view.bounds),
            accuracy: 0.01,
            "One line keeps the vertical position the first of two lines had")
        XCTAssertEqual(headline.frame.height, 44, accuracy: 0.01)

        // One typesetting per sentence, and here they start at the same place:
        // the anchor is at the head of both.
        XCTAssertEqual(departing.frame.minX, shared.frame.minX, accuracy: 0.01)
        XCTAssertEqual(arriving.frame.minX, shared.frame.minX, accuracy: 0.01)

        let font = try XCTUnwrap(headline.font)
        XCTAssertEqual(font.pointSize, 25, "This card has room for the full size")
        XCTAssertEqual(
            shared.frame.minX + width(headline.finalText, font: font) / 2,
            headline.bounds.midX,
            accuracy: 1,
            "The finished sentence is what is centred")
        XCTAssertLessThan(
            shared.frame.minX + width(headline.initialText, font: font) / 2,
            headline.bounds.midX - 20,
            "The first beat therefore lands left of centre, which is the point")

        for fragment in fragments.all {
            XCTAssertFalse(fragment.isFullyRevealed)
            XCTAssertTrue(fragment.usesGlyphEdgeIllumination)
            XCTAssertFalse(fragment.occluderHasVisibleChrome)
        }

        let firstBeat = expectation(description: "the initial sentence arrives")
        headline.revealFirstBeat(duration: 0.02) { firstBeat.fulfill() }
        wait(for: [firstBeat], timeout: 5)
        XCTAssertTrue(shared.isFullyRevealed)
        XCTAssertTrue(departing.isFullyRevealed)
        XCTAssertFalse(arriving.isFullyRevealed)
        XCTAssertEqual(headline.accessibilityLabel, headline.initialText)

        let anchorFrame = shared.frame
        let secondBeat = expectation(description: "the difference plays")
        headline.revealSecondBeat(duration: 0.02) { secondBeat.fulfill() }
        wait(for: [secondBeat], timeout: 5)
        XCTAssertTrue(arriving.isFullyRevealed)
        XCTAssertTrue(departing.isFullyConcealed)
        XCTAssertFalse(departing.isFullyRevealed)
        XCTAssertTrue(
            shared.isFullyRevealed, "The second beat does not touch the anchor")
        XCTAssertEqual(shared.frame, anchorFrame)
        XCTAssertEqual(headline.accessibilityLabel, headline.finalText)
        XCTAssertTrue(headline.isAccessibilityElement)
        XCTAssertFalse(shared.isAccessibilityElement)
    }

    func testIntroShiftsTheInitialSentenceRightWhenTheCopyGrowsOnTheLeft() throws {
        let headline = OnboardingIntroHeadlineView(
            copy: OnboardingStrings.introCopy(for: .priceTracker))
        headline.frame = CGRect(x: 0, y: 0, width: 306, height: 44)
        headline.setNeedsLayout()
        headline.layoutIfNeeded()

        let font = try XCTUnwrap(headline.font)
        let departing = try XCTUnwrap(headline.fragments.initialPrefix)
        let arriving = try XCTUnwrap(headline.fragments.finalPrefix)
        let shared = try XCTUnwrap(headline.fragments.shared)
        XCTAssertNil(headline.fragments.initialSuffix, "Nothing changes at the end")
        XCTAssertNil(headline.fragments.finalSuffix)

        // “Miss a sale” has to sit RIGHT of centre for “iss a sale” to land
        // where the finished “Never miss a sale” puts it.
        XCTAssertGreaterThan(departing.frame.minX, shared.frame.minX + 20)
        XCTAssertEqual(
            departing.frame.minX + width(headline.transition.initialPrefix, font: font),
            shared.frame.minX + width(headline.transition.finalPrefix, font: font),
            accuracy: 0.01,
            "The anchor occupies one position, whichever state is on screen")
        XCTAssertEqual(arriving.frame.minX, shared.frame.minX, accuracy: 0.01)
        XCTAssertEqual(
            shared.frame.minX + width(headline.finalText, font: font) / 2,
            headline.bounds.midX,
            accuracy: 1,
            "The finished sentence is still the centred one")
    }

    func testIntroAnimatesBothSidesOfTheAnchorInOneBeat() throws {
        let headline = OnboardingIntroHeadlineView(
            copy: OnboardingStrings.introCopy(for: .downloader))
        headline.frame = CGRect(x: 0, y: 0, width: 306, height: 44)
        headline.setNeedsLayout()
        headline.layoutIfNeeded()

        let shared = try XCTUnwrap(headline.fragments.shared)
        let departingSuffix = try XCTUnwrap(headline.fragments.initialSuffix)
        let arrivingPrefix = try XCTUnwrap(headline.fragments.finalPrefix)
        let arrivingSuffix = try XCTUnwrap(headline.fragments.finalSuffix)
        XCTAssertNil(
            headline.fragments.initialPrefix,
            "Downloader's first state says nothing before the anchor")

        let firstBeat = expectation(description: "the claim arrives")
        headline.revealFirstBeat(duration: 0.02) { firstBeat.fulfill() }
        wait(for: [firstBeat], timeout: 5)
        XCTAssertTrue(shared.isFullyRevealed)
        XCTAssertTrue(departingSuffix.isFullyRevealed)
        XCTAssertFalse(arrivingPrefix.isFullyRevealed)
        XCTAssertFalse(arrivingSuffix.isFullyRevealed)

        let secondBeat = expectation(description: "the correction plays")
        headline.revealSecondBeat(duration: 0.02) { secondBeat.fulfill() }
        wait(for: [secondBeat], timeout: 5)
        XCTAssertTrue(arrivingPrefix.isFullyRevealed)
        XCTAssertTrue(arrivingSuffix.isFullyRevealed)
        XCTAssertTrue(departingSuffix.isFullyConcealed)
        XCTAssertTrue(shared.isFullyRevealed)
        XCTAssertEqual(headline.accessibilityLabel, headline.finalText)
    }

    func testIntroStartsADepartureWithTheArrivalsItStandsBeside() {
        let headline = OnboardingIntroHeadlineView(
            copy: OnboardingStrings.introCopy(for: .reader))
        headline.frame = CGRect(x: 0, y: 0, width: 306, height: 44)
        headline.setNeedsLayout()
        headline.layoutIfNeeded()

        // A period's ink sits about an x-height below “more”'s, and one front
        // descending through the shared frame would reach it that much later —
        // uncovering the top of the “m” while the period still stood beside it.
        // The period's own front starts that far ahead so both tops go at once.
        let xHeight = (headline.font ?? .systemFont(ofSize: 25)).xHeight
        let lead = headline.frontLead(forDeparting: ".")
        XCTAssertGreaterThan(
            lead, xHeight * 0.4,
            "Without a real lead the period outlives the tail's first glyph")
        XCTAssertLessThan(
            lead, xHeight,
            "The lead is a drop between two inks, not a whole glyph height")
        // Type as tall as what arrives beside it needs no lead at all.
        XCTAssertEqual(headline.frontLead(forDeparting: "Read"), 0, accuracy: 0.01)
    }

    func testIntroShrinksItsCopyToFitANarrowCardWithoutLosingTheAnchor() throws {
        let copy = OnboardingStrings.introCopy(for: .downloader)
        let roomy = OnboardingIntroHeadlineView(copy: copy)
        roomy.frame = CGRect(x: 0, y: 0, width: 306, height: 44)
        roomy.setNeedsLayout()
        roomy.layoutIfNeeded()
        let narrow = OnboardingIntroHeadlineView(copy: copy)
        narrow.frame = CGRect(x: 0, y: 0, width: 190, height: 44)
        narrow.setNeedsLayout()
        narrow.layoutIfNeeded()

        let roomyFont = try XCTUnwrap(roomy.font)
        let narrowFont = try XCTUnwrap(narrow.font)
        XCTAssertEqual(roomyFont.pointSize, 25)
        XCTAssertLessThan(
            narrowFont.pointSize, roomyFont.pointSize,
            "A card this narrow cannot hold the copy at full size")

        // Both states still fit, and the anchor is still one position.
        let shared = try XCTUnwrap(narrow.fragments.shared)
        let departing = try XCTUnwrap(narrow.fragments.initialSuffix)
        XCTAssertEqual(
            departing.frame.minX
                + width(narrow.transition.initialPrefix, font: narrowFont),
            shared.frame.minX
                + width(narrow.transition.finalPrefix, font: narrowFont),
            accuracy: 0.01)
        for text in [narrow.initialText, narrow.finalText] {
            XCTAssertLessThanOrEqual(
                width(text, font: narrowFont), narrow.bounds.width + 0.5,
                "\(text) still overflows the card")
        }
    }

    /// The text width the headline transition measures against, with the same
    /// attributes the label renders with — kerning and ligatures off, so a
    /// shared run measures identically in both states.
    private func width(_ string: String, font: UIFont) -> CGFloat {
        NSAttributedString(
            string: string,
            attributes: [.font: font, .kern: 0, .ligature: 0]
        ).size().width
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
