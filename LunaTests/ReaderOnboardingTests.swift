//
//  ReaderOnboardingTests.swift
//  LunaTests
//

import LunaModels
import LunaDesignSystem
import LunaReaderUI
import LunaStorage
import XCTest
@testable import Luna

final class ReaderOnboardingTests: XCTestCase {
    func testCompletionIsOwnedByInjectedPerAppDefaults() {
        let suite = "ReaderOnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let reader = AppOnboardingStore(app: .reader, defaults: defaults)
        let downloader = AppOnboardingStore(app: .downloader, defaults: defaults)
        XCTAssertFalse(reader.isCompleted)
        XCTAssertFalse(downloader.isCompleted)
        reader.markCompleted()
        XCTAssertTrue(reader.isCompleted)
        XCTAssertFalse(downloader.isCompleted)
    }

    func testBundledLunaArticleInstallsAsARealIdempotentOfflineSave() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReaderOnboardingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ReadingListStore(containerURL: directory)
        let first = BundledLunaArticle.install(in: store)
        let second = BundledLunaArticle.install(in: store)
        let content = try XCTUnwrap(store.content(for: first.item))

        XCTAssertTrue(first.wasCreated)
        XCTAssertFalse(second.wasCreated)
        XCTAssertEqual(first.item.id, second.item.id)
        XCTAssertEqual(first.item.urlString, BundledLunaArticle.urlString)
        XCTAssertEqual(first.item.state, .ready)
        XCTAssertEqual(content.title, "Save anything in Safari")
        XCTAssertNil(content.author)
        XCTAssertEqual(
            content.blocks.map(\.text),
            [
                "Your article, and your browsing history, all stay offline.",
                "Speed read, open links inline, and more! The best smartphone reading "
                    + "experience you’ve ever had.",
            ])
    }

    func testTemporaryArticleCleanupDeletesOnlyTheSaveOnboardingCreated() throws {
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
        let temporaryURL = "https://luna.app?test=temporary"
        XCTAssertTrue(BundledLunaArticle.installTemporary(
            urlString: temporaryURL, registry: registry, in: contentStore))
        let temporaryID = try XCTUnwrap(registry.temporarySaveIdentifier)
        XCTAssertNotNil(contentStore.item(withID: temporaryID))

        BundledLunaArticle.cleanupTemporary(
            registry: registry, in: contentStore)
        XCTAssertNil(contentStore.item(withID: temporaryID))
        XCTAssertNil(registry.temporarySaveIdentifier)

        let existing = contentStore.add(urlString: temporaryURL)
        XCTAssertTrue(BundledLunaArticle.installTemporary(
            urlString: temporaryURL, registry: registry, in: contentStore))
        XCTAssertNil(registry.temporarySaveIdentifier)
        BundledLunaArticle.cleanupTemporary(
            registry: registry, in: contentStore)
        XCTAssertEqual(contentStore.item(withID: existing.id)?.id, existing.id)
    }

    func testEverySurfaceHasItsExactCopyAndDemoPage() {
        let reader = OnboardingSurfaceConfiguration.configuration(for: .reader)
        XCTAssertEqual(reader.firstLine, "You want to read more.")
        XCTAssertEqual(reader.secondLine, "Let’s make that happen.")
        XCTAssertEqual(
            reader.supportingText,
            "Save onscreen links with one click.\nUnlock or read offline later.")
        XCTAssertEqual(reader.saveBenefit, "Read offline later")
        XCTAssertEqual(reader.demoPages, [.lunaArticle])
        XCTAssertEqual(
            reader.demoPages.first?.sharedURLString,
            "https://luna.app/about")

        let downloader = OnboardingSurfaceConfiguration.configuration(for: .downloader)
        XCTAssertEqual(downloader.firstLine, "App signup required? So annoying.")
        XCTAssertEqual(downloader.secondLine, "Watch and share instantly instead.")
        XCTAssertEqual(
            downloader.supportingText,
            "Download any video link in one click,\nno signup required.")
        XCTAssertEqual(downloader.saveBenefit, "Watch or share")
        XCTAssertEqual(downloader.demoPages, [.instaTok])
        XCTAssertEqual(
            downloader.demoPages.first?.sharedURLString,
            "https://instatok.local/@moonwatch/lunar-eclipse")

        let price = OnboardingSurfaceConfiguration.configuration(for: .priceTracker)
        XCTAssertEqual(price.firstLine, "Overpaid? Missed a sale?")
        XCTAssertEqual(price.secondLine, "Never miss out again.")
        XCTAssertEqual(
            price.supportingText,
            "Track sales for any link\nin one click.")
        XCTAssertEqual(price.saveBenefit, "Never miss a sale")
        XCTAssertEqual(price.demoPages, [.amayzon])
        XCTAssertEqual(
            price.demoPages.first?.sharedURLString,
            "https://amayzon.local/eyephone-air")

        let luna = OnboardingSurfaceConfiguration.configuration(for: .luna)
        XCTAssertEqual(luna.firstLine, "All your Luna saves.")
        XCTAssertEqual(luna.secondLine, "In a single app.")
        XCTAssertEqual(
            luna.supportingText,
            "Save any link on your screen\nwith one click.")
        XCTAssertEqual(luna.saveBenefit, "Read, watch, track, anything")
        XCTAssertEqual(luna.demoPages, [.lunaArticle, .instaTok, .amayzon])
    }

    @MainActor
    func testIntroStagesTheSameRevealAcrossBothLines() throws {
        let intro = OnboardingIntroCardContentViewController(
            firstLine: "You want to read more.",
            secondLine: "Let’s make that happen.",
            supportingText:
                "Save onscreen links with one click.\nUnlock or read offline later.")
        intro.loadViewIfNeeded()
        intro.view.frame = CGRect(x: 0, y: 0, width: 354, height: 629)
        intro.view.layoutIfNeeded()

        let lines = intro.view.subviews.compactMap { $0 as? MoonRevealLineView }
        XCTAssertEqual(lines.count, 2)
        XCTAssertFalse(lines[0].isFullyRevealed)
        XCTAssertFalse(lines[1].isFullyRevealed)
        XCTAssertFalse(lines[0].occluderHasVisibleChrome)
        XCTAssertTrue(lines[0].occluderIsFullyOpaque)
        XCTAssertTrue(lines[0].usesGlyphEdgeIllumination)
        XCTAssertFalse(lines[1].occluderHasVisibleChrome)
        XCTAssertTrue(lines[1].occluderIsFullyOpaque)
        XCTAssertTrue(lines[1].usesGlyphEdgeIllumination)

        let button = try XCTUnwrap(
            intro.view.subviews.compactMap { $0 as? UIButton }.first)
        XCTAssertEqual(intro.view.backgroundColor, .black)
        XCTAssertFalse(intro.view.subviews.contains {
            $0.accessibilityIdentifier == "onboarding.intro.iconCluster"
        })
        XCTAssertTrue(
            intro.view.subviews.compactMap { $0 as? UILabel }.allSatisfy {
                $0.accessibilityIdentifier != "onboarding.intro.supportingText"
            })
        XCTAssertEqual(
            button.configuration?.title,
            "Let's go")
        XCTAssertEqual(button.accessibilityLabel, "Let's go")
        let tintAlpha = try XCTUnwrap(
            button.configuration?.baseBackgroundColor?.cgColor.alpha)
        XCTAssertEqual(tintAlpha, 0.24, accuracy: 0.001)
    }

    func testIntroWaveAndDemoLoopTimingsStayDeliberateButBrisk() {
        XCTAssertGreaterThan(OnboardingIntroTiming.firstLineDelay, 0.05)
        XCTAssertLessThan(
            OnboardingIntroTiming.firstLineDelay, 0.2,
            "The settling beat before the first reveal must stay brief")
        XCTAssertLessThan(OnboardingIntroTiming.interLineDelay, 0.5)
        XCTAssertGreaterThan(OnboardingIntroTiming.lineRevealDuration, 0.82)
        XCTAssertLessThan(
            OnboardingActionButtonTiming.firstWaveDuration,
            1.18)
        XCTAssertLessThan(
            OnboardingActionButtonTiming.blackoutWaveDuration,
            1.18)
        XCTAssertLessThan(
            OnboardingActionButtonTiming.saveCrossfadeDuration,
            OnboardingActionButtonTiming.blackoutWaveDuration,
            "The final crossfade is deliberately simpler and quicker than the waves")
        XCTAssertEqual(
            OnboardingActionButtonTiming.firstWaveDelay, 0.2, accuracy: 0.001,
            "The screen holds still for a beat of the press bump before the first wave")
        XCTAssertEqual(
            OnboardingActionButtonTiming.saveCrossfadeDelay, 0.5, accuracy: 0.001,
            "The isolated link rests on black before the crossfade begins")
        XCTAssertGreaterThan(OnboardingDemoLoopTiming.geometryDuration, 0.45)
        XCTAssertLessThan(OnboardingDemoLoopTiming.geometryDuration, 0.70)
        XCTAssertGreaterThan(
            OnboardingDemoLoopTiming.savedCardHoldDuration,
            OnboardingDemoLoopTiming.sourceHoldDuration)
        XCTAssertGreaterThan(
            OnboardingDemoLoopTiming.setupPromptSavedCardHoldDuration,
            OnboardingDemoLoopTiming.savedCardHoldDuration)
        XCTAssertGreaterThanOrEqual(
            OnboardingActionButtonTiming.blackoutWavefrontHalfWidth,
            28)
        XCTAssertGreaterThan(
            OnboardingActionButtonTiming.firstWavefrontHalfWidth,
            OnboardingActionButtonTiming.blackoutWavefrontHalfWidth)
        XCTAssertGreaterThan(
            OnboardingActionButtonTiming.firstMaximumDisplacement,
            OnboardingActionButtonTiming.blackoutMaximumDisplacement)
        XCTAssertGreaterThanOrEqual(
            OnboardingActionButtonTiming.firstWaveLightingStrength,
            0.18)
        XCTAssertGreaterThanOrEqual(
            OnboardingActionButtonTiming.blackoutMaximumDisplacement,
            22)
        XCTAssertLessThan(
            OnboardingActionButtonTiming.blackoutRevealHalfWidth,
            OnboardingActionButtonTiming.blackoutWavefrontHalfWidth)
        XCTAssertLessThanOrEqual(
            OnboardingActionButtonTiming.waveRasterScale,
            2)
        XCTAssertLessThanOrEqual(
            AppOnboardingCompletionTransition.handoffDuration,
            0.25)
        XCTAssertGreaterThanOrEqual(
            OnboardingShortcutRunTiming.extensionSheetHoldDuration, 1.0,
            "The mock extension sheet holds a full beat before dismissing")
        XCTAssertLessThan(OnboardingShortcutRunTiming.appSwitchDuration, 1.0)
        XCTAssertGreaterThan(
            OnboardingShortcutRunTiming.islandProgressDuration, 1.0,
            "The shortcut-run progress ring must read as real work")
        XCTAssertEqual(
            OnboardingShortcutRunTiming.skipButtonDelay, 0.5, accuracy: 0.001,
            "The skip-out follows the shortcut-install message by half a second")
    }

    func testJourneySeparatesSafariAndMessagesWithTheirSetupPrompts() {
        XCTAssertEqual(
            OnboardingDemoSource.allCases,
            [.safari, .messages])
        XCTAssertEqual(OnboardingDemoSource.safari.next, .messages)
        XCTAssertEqual(OnboardingDemoSource.messages.next, .safari)

        var stage = OnboardingJourneyStage.safariDemonstration
        XCTAssertEqual(stage.completedSave(from: .safari), .safari)
        XCTAssertEqual(stage, .safariSetup)
        XCTAssertNil(stage.completedSave(from: .messages))
        XCTAssertTrue(stage.completedSafariSetup())
        XCTAssertEqual(stage, .messagesDemonstration)
        XCTAssertEqual(stage.completedSave(from: .messages), .actionButton)
        XCTAssertEqual(stage, .actionButtonSetup)
    }

    @MainActor
    func testMessagesReplicaShowsTheStagedConversationAndSafariURL() throws {
        let urlString = OnboardingDemoPage.lunaArticle.sharedURLString
        let messages = MessagesReplicaViewController(urlString: urlString)
        messages.loadViewIfNeeded()
        messages.view.frame = CGRect(
            origin: .zero,
            size: AppLaunchGeometry.referenceSize)
        messages.view.layoutIfNeeded()

        let sender = try XCTUnwrap(
            messages.view.descendants(of: UILabel.self).first {
                $0.accessibilityIdentifier == "onboarding.messages.senderName"
            })
        let latestURL = try XCTUnwrap(
            messages.view.descendants(of: UILabel.self).first {
                $0.accessibilityIdentifier == "onboarding.messages.latestURL"
            })
        let labels = messages.view.descendants(of: UILabel.self).compactMap {
            $0.text
        }
        let bubbles = messages.view.descendants(of: UIView.self).compactMap {
            $0.accessibilityIdentifier
        }

        XCTAssertEqual(sender.text, "Johnny Appleseed")
        XCTAssertEqual(latestURL.text, urlString)
        XCTAssertTrue(labels.contains(
            "You can press the Action Button and Luna saves any link on screen"))
        XCTAssertTrue(labels.contains("Woah! Like this?"))
        XCTAssertTrue(bubbles.contains("onboarding.messages.firstOutgoing"))
        XCTAssertTrue(bubbles.contains("onboarding.messages.secondIncoming"))
        XCTAssertGreaterThan(
            messages.actionButtonReplayDelay,
            OnboardingDemoLoopTiming.sourceHoldDuration)
        XCTAssertGreaterThanOrEqual(
            OnboardingMessagesReplicaTiming.interMessageDelay,
            1.5)
        XCTAssertFalse(messages.isURLHighlighted)
        messages.setURLHighlighted(true)
        XCTAssertTrue(messages.isURLHighlighted)
    }

    @MainActor
    func testMessagesSetupPillsGlowUntilTheyDriveTheirSetupHops() throws {
        let messages = MessagesReplicaViewController(
            urlString: OnboardingDemoPage.lunaArticle.sharedURLString)
        messages.loadViewIfNeeded()
        messages.view.frame = CGRect(
            origin: .zero,
            size: AppLaunchGeometry.referenceSize)
        messages.view.layoutIfNeeded()

        let bubbles = messages.view.descendants(of: UIView.self).compactMap {
            $0.accessibilityIdentifier
        }
        XCTAssertTrue(bubbles.contains("onboarding.messages.shortcutSetup"))
        XCTAssertTrue(bubbles.contains("onboarding.messages.settingsSetup"))
        // Each pill flows INLINE with its sentence: the words live in a text
        // view whose attachment reserves the pill's spot in the line flow.
        let sentences = messages.view.descendants(of: UITextView.self)
            .compactMap(\.text)
        XCTAssertTrue(sentences.contains {
            $0.hasPrefix("Yeah just install this shortcut")
        })
        XCTAssertTrue(sentences.contains {
            $0.hasPrefix("And change your action button to that shortcut in")
        })
        let labels = messages.view.descendants(of: UILabel.self).compactMap(\.text)
        XCTAssertTrue(labels.contains("Luna"))
        XCTAssertTrue(labels.contains("Settings"))

        // The skip-out waits below the raised composer, invisible until the
        // shortcut-install message has landed.
        let skip = try XCTUnwrap(
            messages.view.descendants(of: UIButton.self).first {
                $0.accessibilityIdentifier == "onboarding.messages.skip"
            })
        XCTAssertEqual(skip.alpha, 0)
        XCTAssertFalse(skip.isUserInteractionEnabled)
        XCTAssertEqual(skip.configuration?.title, "or skip")

        let shortcutPill = try XCTUnwrap(
            messages.view.descendants(of: OnboardingMessagePillButton.self).first {
                $0.accessibilityIdentifier == "onboarding.messages.shortcutPill"
            })
        let settingsPill = try XCTUnwrap(
            messages.view.descendants(of: OnboardingMessagePillButton.self).first {
                $0.accessibilityIdentifier == "onboarding.messages.settingsPill"
            })

        // The demonstration hasn't reached the setup messages yet.
        XCTAssertFalse(messages.isShowingSetupMessages)

        var installedShortcut = false
        var openedSettings = false
        messages.onInstallShortcut = { installedShortcut = true }
        messages.onSetActionButton = { openedSettings = true }

        shortcutPill.beginGlowPulse()
        XCTAssertNotNil(
            shortcutPill.layer.animation(forKey: "onboarding.pill.pulse"),
            "The shortcut pill must pulse until tapped")
        shortcutPill.sendActions(for: .touchUpInside)
        XCTAssertTrue(installedShortcut)
        XCTAssertTrue(shortcutPill.wasActivated)
        XCTAssertNil(
            shortcutPill.layer.animation(forKey: "onboarding.pill.pulse"),
            "Tapping the pill must stop its glow pulse")
        shortcutPill.beginGlowPulse()
        XCTAssertNil(
            shortcutPill.layer.animation(forKey: "onboarding.pill.pulse"),
            "An activated pill never resumes pulsing")

        settingsPill.sendActions(for: .touchUpInside)
        XCTAssertTrue(openedSettings)
    }

    @MainActor
    func testSafariAndMessagesShareTheSamePersistentURLHighlightState() throws {
        let configuration = OnboardingSurfaceConfiguration.configuration(for: .reader)
        let safari = SafariReplicaViewController(configuration: configuration)
        safari.loadViewIfNeeded()
        let messages = MessagesReplicaViewController(
            urlString: safari.sharedURLString)
        messages.loadViewIfNeeded()
        let frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        safari.view.frame = frame
        messages.view.frame = frame
        safari.view.layoutIfNeeded()
        messages.view.layoutIfNeeded()
        // The URL bubble only reaches its on-screen resting spot once the
        // staged conversation has arrived.
        messages.revealStagedConversationImmediately()

        XCTAssertEqual(messages.sharedURLString, safari.sharedURLString)
        XCTAssertFalse(safari.isURLHighlighted)
        XCTAssertFalse(messages.isURLHighlighted)

        safari.setURLHighlighted(true)
        messages.setURLHighlighted(true)
        XCTAssertTrue(safari.isURLHighlighted)
        XCTAssertTrue(messages.isURLHighlighted)

        let safariRegion = try XCTUnwrap(safari.highlightedLinkRegion)
        XCTAssertEqual(safariRegion.frame.height, 46, accuracy: 0.001)
        XCTAssertEqual(safariRegion.cornerRadius, 23, accuracy: 0.001)
        XCTAssertTrue(frame.contains(safariRegion.frame))

        let messagesRegion = try XCTUnwrap(messages.highlightedLinkRegion)
        XCTAssertLessThan(messagesRegion.frame.width, 260)
        XCTAssertGreaterThan(messagesRegion.frame.width, 120)
        XCTAssertEqual(messagesRegion.cornerRadius, 18, accuracy: 0.001)
        XCTAssertTrue(frame.contains(messagesRegion.frame))

        safari.prepareForPresentation()
        messages.prepareForPresentation()
        XCTAssertFalse(safari.isURLHighlighted)
        XCTAssertFalse(messages.isURLHighlighted)
    }

    @MainActor
    func testCancellingAnActiveSaveReplayClearsItsTransientState() throws {
        let frame = CGRect(origin: .zero, size: AppLaunchGeometry.referenceSize)
        let messages = MessagesReplicaViewController(
            urlString: OnboardingDemoPage.lunaArticle.sharedURLString)
        let window = UIWindow(frame: frame)
        window.rootViewController = messages
        window.makeKeyAndVisible()
        messages.view.layoutIfNeeded()
        defer { window.isHidden = true }

        let format = UIGraphicsImageRendererFormat()
        format.scale = OnboardingActionButtonTiming.waveRasterScale
        format.opaque = true
        let destination = UIGraphicsImageRenderer(
            bounds: frame,
            format: format
        ).image { context in
            UIColor.black.setFill()
            context.fill(frame)
        }
        messages.makeActionButtonDestinationSnapshot = { destination }

        messages.replayActionButtonSaveEffect()
        XCTAssertFalse(
            messages.isURLHighlighted,
            "The Messages save never lights the link — the bubble itself flies")
        XCTAssertTrue(messages.hasActiveActionButtonSaveEffectForTesting)

        messages.cancelActionButtonSaveEffect()
        XCTAssertFalse(messages.isURLHighlighted)
        XCTAssertFalse(messages.hasActiveActionButtonSaveEffectForTesting)
    }

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
            of: Set(["Set up Safari", "Install Shortcut", "Set action button"])))
        XCTAssertTrue(mountedOverlay.accessibilityViewIsModal)
        XCTAssertTrue(obscuredSiblings.allSatisfy(\.accessibilityElementsHidden))

        mountedOverlay.removeFromSuperview()
        XCTAssertTrue(obscuredSiblings.allSatisfy {
            !$0.accessibilityElementsHidden
        })
    }

    func testSettingsOpenerReportsExhaustedFallbacks() {
        var opened: Bool?
        SystemSettingsLink.openFirstAvailable([]) { opened = $0 }
        XCTAssertEqual(opened, false)
    }

    @MainActor
    func testActionButtonWaveStartsAtThePhysicalScreenEdgeCue() {
        let cue = ActionButtonPressCue()
        cue.frame = CGRect(x: 0, y: 92, width: 44, height: 56)

        XCTAssertEqual(cue.waveOrigin.x, 0, accuracy: 0.001)
        XCTAssertEqual(cue.waveOrigin.y, cue.frame.midY, accuracy: 0.001)
    }

    @MainActor
    func testActionButtonCueMatchesTheSystemBlackEdgeDeformation() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let cue = ActionButtonPressCue()
        cue.layout(in: window)

        XCTAssertEqual(cue.bounds.width, 7, accuracy: 0.001)
        XCTAssertEqual(cue.bounds.height, 120, accuracy: 0.001)
        XCTAssertEqual(cue.layer.position.x, 0, accuracy: 0.001)
        XCTAssertEqual(
            cue.layer.position.y,
            window.safeAreaInsets.top
                + OnboardingActionButtonTiming.actionButtonCenterBelowSafeArea,
            accuracy: 0.001)
        XCTAssertEqual(cue.layer.anchorPoint.x, 0, accuracy: 0.001)
        XCTAssertTrue(cue.subviews.isEmpty, "The edge silhouette is rendered entirely with layers")
        XCTAssertEqual(cue.layer.sublayers?.count, 1)
        let silhouette = try XCTUnwrap(cue.layer.sublayers?.first as? CAShapeLayer)
        let path = try XCTUnwrap(silhouette.path)
        XCTAssertEqual(
            path.boundingBox.width,
            cue.bounds.width,
            accuracy: 0.001)
        XCTAssertEqual(
            path.boundingBox.height,
            cue.bounds.height,
            accuracy: 0.001)
    }

    @MainActor
    func testOnboardingKeepsLaunchCoronaUntilShowMeHowThenExpandsWithoutIt() throws {
        let suite = "ReaderOnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let productionRoot = UINavigationController(
            rootViewController: UIViewController())
        let onboarding = AppOnboardingViewController(
            configuration: .configuration(for: .reader),
            onboardingStore: AppOnboardingStore(
                app: .reader, defaults: defaults),
            completion: AppOnboardingCompletion(
                temporarySave: OnboardingTemporarySave(
                    install: { true },
                    cleanup: {}),
                makeCompletedRootViewController: { productionRoot }))
        let window = UIWindow(frame: CGRect(
            origin: .zero,
            size: AppLaunchGeometry.referenceSize))
        window.rootViewController = onboarding
        window.makeKeyAndVisible()
        onboarding.view.layoutIfNeeded()

        let corona = try XCTUnwrap(
            onboarding.view.subviews.compactMap {
                $0 as? EclipseCoronaView
            }.first,
            "The initial onboarding card should retain the launch corona")
        let launchTarget = try XCTUnwrap(
            onboarding.appLaunchTargetFrame(in: window))
        XCTAssertEqual(
            corona.frame,
            onboarding.view.convert(launchTarget, from: window),
            "The retained corona must stay stationary at the splash card frame")

        let button = try XCTUnwrap(
            onboarding.view.descendants(of: UIButton.self).first {
                $0.accessibilityLabel == "Let's go"
            })
        UIView.setAnimationsEnabled(false)
        defer {
            UIView.setAnimationsEnabled(true)
            window.isHidden = true
        }
        button.sendActions(for: .touchUpInside)
        // The press finishes its (animations-disabled) button dip on a later
        // run-loop turn; keep spinning until the expansion mounts the replica
        // rather than betting on one fixed-length spin.
        let deadline = Date(timeIntervalSinceNow: 2)
        while Date() < deadline,
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
        // The Safari replica's setup card carries its own corona, so only the
        // intro's direct-subview corona must be gone.
        XCTAssertTrue(
            onboarding.view.subviews.compactMap { $0 as? EclipseCoronaView }.isEmpty,
            "Pressing Show me how must remove the retained corona before expansion")
    }

    @MainActor
    func testFirstLineRevealRunsTheStagedDemonstrationPreload() throws {
        let suite = "ReaderOnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let productionRoot = UINavigationController(
            rootViewController: UIViewController())
        let onboarding = AppOnboardingViewController(
            configuration: .configuration(for: .reader),
            onboardingStore: AppOnboardingStore(
                app: .reader, defaults: defaults),
            completion: AppOnboardingCompletion(
                temporarySave: OnboardingTemporarySave(
                    install: { true },
                    cleanup: {}),
                makeCompletedRootViewController: { productionRoot }))
        let window = UIWindow(frame: CGRect(
            origin: .zero,
            size: AppLaunchGeometry.referenceSize))
        window.rootViewController = onboarding
        window.makeKeyAndVisible()
        onboarding.view.layoutIfNeeded()
        defer { window.isHidden = true }

        onboarding.firstIntroLineDidReveal()
        // The preload runs one stage per run-loop turn; keep spinning until
        // the final stage mounts the replicas (or the deadline trips).
        let deadline = Date(timeIntervalSinceNow: 2)
        while Date() < deadline,
              onboarding.children.compactMap({
                  $0 as? SafariReplicaViewController
              }).isEmpty {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }

        let safari = try XCTUnwrap(
            onboarding.children.compactMap {
                $0 as? SafariReplicaViewController
            }.first,
            "Show me how must not pay for replica creation; it is preloaded behind the intro")
        XCTAssertTrue(
            safari.view.isHidden,
            "The preloaded Safari replica must stay invisible behind the intro card")
        XCTAssertNotNil(
            onboarding.children.compactMap {
                $0 as? MessagesReplicaViewController
            }.first)
        XCTAssertTrue(
            onboarding.savedRootViewControllerForTesting === productionRoot,
            "The production root is prepared before Show me how is pressed")
        XCTAssertFalse(
            onboarding.view.descendants(of: EclipseCoronaView.self).isEmpty,
            "Preloading must not retire the intro corona early")
    }

    func testLaunchArtworkUsesTheReferenceRootCardsExactSize() {
        let card = AppLaunchGeometry.referenceRootCardFrame

        XCTAssertEqual(card.minX, 24, accuracy: 0.001)
        XCTAssertEqual(card.width, 354, accuracy: 0.001)
        XCTAssertEqual(
            card.height,
            card.width / CardCarouselMetrics.cardAspectRatio,
            accuracy: 0.001)
        XCTAssertEqual(card.maxY, 724, accuracy: 0.001)
    }

    func testLiveLaunchViewPlacesItsCardAtTheDestinationFrame() {
        let bounds = CGRect(origin: .zero, size: AppLaunchGeometry.referenceSize)
        let target = AppLaunchGeometry.referenceRootCardFrame
        let launch = AppLaunchTransition.makeLaunchView(
            frame: bounds,
            cardFrame: target)
        guard let card = launch.subviews.compactMap({ $0 as? CardSurfaceView }).first
        else {
            XCTFail("Launch view should contain its production card surface")
            return
        }

        XCTAssertNotNil(
            launch.subviews.compactMap({ $0 as? EclipseCoronaView }).first,
            "Launch view should visibly contain the production eclipse corona")
        XCTAssertEqual(card.frame, target)
        XCTAssertGreaterThanOrEqual(
            AppLaunchTransition.minimumVisibleDuration,
            0.08,
            "The live eclipse must survive at least one committed frame")
        XCTAssertLessThanOrEqual(AppLaunchTransition.fadeDuration, 0.2)
        XCTAssertLessThanOrEqual(
            AppLaunchTransition.minimumVisibleDuration
                + AppLaunchTransition.fadeDuration,
            0.35)
        XCTAssertLessThanOrEqual(
            AppLaunchTransition.instantMinimumVisibleDuration
                + AppLaunchTransition.instantFadeDuration,
            0.10,
            "The pixel-identical onboarding splash must reveal near-instantly")
    }

    func testStaticLaunchBundlesTheCompositeUnderTheCurrentStoryboardIdentity() {
        XCTAssertEqual(
            Bundle.main.object(
                forInfoDictionaryKey: "UILaunchStoryboardName") as? String,
            "LunaLaunchScreen")
        XCTAssertNotNil(
            Bundle.main.url(
                forResource: "LunaLaunchComposite",
                withExtension: "png"),
            "The launch storyboard's standalone composite must be copied into the app")
    }

    func testOnboardingLayoutStartsAtOneThirdOfItsContainer() {
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 600)
        XCTAssertEqual(AppOnboardingLayout.contentTop(in: bounds), 220)
    }

    func testAnimationClockParsesAndClampsDebugScales() {
        XCTAssertEqual(OnboardingAnimationClock.resolvedScale(arguments: []), 1)
        XCTAssertEqual(
            OnboardingAnimationClock.resolvedScale(
                arguments: ["Luna", "-slowOnboardingAnimations"]),
            6)
        XCTAssertEqual(
            OnboardingAnimationClock.resolvedScale(
                arguments: ["Luna", "-onboardingAnimationScale", "3.5"]),
            3.5)
        XCTAssertEqual(
            OnboardingAnimationClock.resolvedScale(
                arguments: ["Luna", "-onboardingAnimationScale", "99"]),
            12)
        XCTAssertEqual(
            OnboardingAnimationClock.resolvedScale(
                arguments: ["Luna", "-onboardingAnimationScale", "0.2"]),
            1)
    }

    @MainActor
    func testLunaArticleLoadsBuriedWithTheCardSharingTheScreen() throws {
        let article = OnboardingArticleReplicaView()
        article.frame = CGRect(
            origin: .zero,
            size: CGSize(
                width: AppLaunchGeometry.referenceSize.width,
                height: AppLaunchGeometry.referenceSize.height - 59))
        article.layoutIfNeeded()

        let labels = article.descendants(of: UILabel.self).compactMap(\.text)
        let revealLines = article.descendants(of: MoonRevealLineView.self)

        // The page loads fully readable underneath — nothing waits on a
        // reveal — and the whole short article is there from the start.
        XCTAssertTrue(revealLines.allSatisfy(\.isFullyRevealed))
        let revealCopy = revealLines.compactMap(\.accessibilityLabel)
        XCTAssertTrue(revealCopy.contains("An article you want to read"))
        XCTAssertTrue(revealCopy.contains("A safari extension • by Luna"))
        XCTAssertTrue(revealCopy.contains(
            OnboardingArticleReplicaView.fullArticleText))

        // The NASA composite banner sits between the byline and the body at
        // its native wide aspect, with real bundled pixels.
        let eclipse = try XCTUnwrap(article.descendants(of: UIView.self).first {
            $0.accessibilityIdentifier == "onboarding.safari.article.eclipseImage"
        })
        let byline = try XCTUnwrap(revealLines.first {
            $0.accessibilityIdentifier == "onboarding.safari.article.byline"
        })
        let body = try XCTUnwrap(revealLines.first {
            $0.accessibilityIdentifier == "onboarding.safari.article.body"
        })
        XCTAssertGreaterThan(eclipse.frame.minY, byline.frame.maxY)
        XCTAssertLessThan(eclipse.frame.maxY, body.frame.minY)
        XCTAssertEqual(
            eclipse.frame.width / eclipse.frame.height,
            1920 / 708,
            accuracy: 0.05)
        XCTAssertNotNil(
            eclipse.descendants(of: UIImageView.self).first?.image)

        // The copy is short enough that the setup card shares the screen: the
        // wipe alone brings it into view, with no scroll at all.
        let card = try XCTUnwrap(
            article.descendants(of: OnboardingSafariSetupCardView.self).first)
        XCTAssertEqual(card.frame.minY, body.frame.maxY + 20, accuracy: 0.5)
        XCTAssertLessThanOrEqual(
            card.frame.maxY,
            article.bounds.height - SafariBottomBar.chromeHeight - 34,
            "The card must clear the browser chrome without scrolling — trim the article copy if this fails")

        // Every fake obstruction is mounted, fully visible from the first
        // frame, and inert.
        let clutter = try XCTUnwrap(article.descendants(of: UIView.self).first {
            $0.accessibilityIdentifier == "onboarding.safari.article.clutter"
        })
        XCTAssertFalse(clutter.isUserInteractionEnabled)
        XCTAssertTrue(clutter.subviews.allSatisfy { $0.alpha == 1 })
        XCTAssertEqual(
            clutter.subviews.filter { $0 is OnboardingAdBannerView }.count, 4)
        XCTAssertTrue(labels.contains("Subscribe to our newsletter"))
        XCTAssertTrue(labels.contains("We promise to spam you"))
        XCTAssertTrue(labels.contains("you@example.com"))
        XCTAssertTrue(labels.contains("Subscribe"))
        XCTAssertTrue(labels.contains("Subscribe to keep reading"))
        XCTAssertTrue(labels.contains("Already a subscriber? Sign in"))
        XCTAssertTrue(labels.contains {
            $0.contains("free article limit")
        })

        // The buried page registers before the mock enable pass starts.
        XCTAssertGreaterThanOrEqual(
            OnboardingExtensionEnableTiming.pageHoldDuration, 0.5)
        XCTAssertGreaterThan(
            OnboardingExtensionEnableTiming.menuHoldBeforeScroll, 0.3)
        XCTAssertGreaterThan(
            OnboardingExtensionEnableTiming.rowHighlightHold, 0.3)
    }

    @MainActor
    func testCleanupShatterRevealsTheArticleAndCardUnderTheEclipseSweep() throws {
        let article = OnboardingArticleReplicaView()
        let window = UIWindow(frame: CGRect(
            origin: .zero,
            size: CGSize(
                width: AppLaunchGeometry.referenceSize.width,
                height: AppLaunchGeometry.referenceSize.height - 59)))
        let host = UIViewController()
        host.view = article
        window.rootViewController = host
        window.makeKeyAndVisible()
        article.layoutIfNeeded()
        defer { window.isHidden = true }

        let finished = expectation(description: "cleanup shatter")
        article.cleanUpClutter {
            finished.fulfill()
        }
        wait(for: [finished], timeout: 6)

        let body = try XCTUnwrap(
            article.descendants(of: MoonRevealLineView.self).first {
                $0.accessibilityIdentifier == "onboarding.safari.article.body"
            })
        XCTAssertEqual(
            body.accessibilityLabel,
            OnboardingArticleReplicaView.fullArticleText)
        XCTAssertTrue(body.isFullyRevealed)
        let clutter = try XCTUnwrap(article.descendants(of: UIView.self).first {
            $0.accessibilityIdentifier == "onboarding.safari.article.clutter"
        })
        XCTAssertTrue(clutter.subviews.allSatisfy(\.isHidden))

        // The one sweep leaves the setup card on screen — no scroll follows.
        let card = try XCTUnwrap(
            article.descendants(of: OnboardingSafariSetupCardView.self).first)
        let scroll = try XCTUnwrap(
            article.descendants(of: UIScrollView.self).first {
                card.isDescendant(of: $0)
            })
        XCTAssertEqual(scroll.contentOffset, .zero)
        XCTAssertLessThanOrEqual(
            card.frame.maxY,
            article.bounds.height - SafariBottomBar.chromeHeight - 34)
        XCTAssertEqual(card.frame.minY, body.frame.maxY + 20, accuracy: 0.5)
    }

    @MainActor
    func testSetupCardSharesTheScreenWithGlassCoronaAndBothActions() throws {
        let safari = SafariReplicaViewController(
            configuration: .configuration(for: .reader))
        safari.loadViewIfNeeded()
        safari.view.frame = CGRect(
            origin: .zero,
            size: AppLaunchGeometry.referenceSize)
        safari.view.layoutIfNeeded()

        let article = try XCTUnwrap(
            safari.view.descendants(of: OnboardingArticleReplicaView.self).first)
        let card = try XCTUnwrap(
            article.descendants(of: OnboardingSafariSetupCardView.self).first)
        let scroll = try XCTUnwrap(
            article.descendants(of: UIScrollView.self).first {
                card.isDescendant(of: $0)
            })

        // On screen from the start (hidden under the clutter until the wipe),
        // with no scrolling anywhere in the demonstration.
        XCTAssertEqual(scroll.contentOffset, .zero)
        XCTAssertLessThanOrEqual(card.frame.maxY, article.bounds.height)
        XCTAssertFalse(scroll.isScrollEnabled, "The page never scrolls")

        // The mini-card wears the usual black deck-card surface and rides the
        // launch corona.
        let cardSurface = try XCTUnwrap(
            card.descendants(of: CardSurfaceView.self).first)
        XCTAssertEqual(cardSurface.backgroundColor, .black)
        let corona = try XCTUnwrap(
            article.descendants(of: EclipseCoronaView.self).first)
        XCTAssertEqual(corona.frame, card.frame)

        let labels = card.descendants(of: UILabel.self).compactMap(\.text)
        XCTAssertTrue(labels.contains(
            "Luna in Safari automatically gives you the web experience you want"))
        let activate = try XCTUnwrap(
            card.descendants(of: UIButton.self).first {
                $0.accessibilityLabel == "Activate Safari"
            })
        let skip = try XCTUnwrap(
            card.descendants(of: UIButton.self).first {
                $0.accessibilityLabel == "Skip"
            })

        var didActivate = false
        var didSkip = false
        safari.onSetUpSafari = { didActivate = true }
        safari.onSkipSafariSetup = { didSkip = true }
        activate.sendActions(for: .touchUpInside)
        XCTAssertTrue(didActivate)
        XCTAssertFalse(didSkip)
        safari.restoreInPageSafariSetup()
        skip.sendActions(for: .touchUpInside)
        XCTAssertTrue(didSkip)
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
        status.recordShortcutRun(isCentral: false)
        status.recordShortcutRun(isCentral: true)
        XCTAssertTrue(status.safariHasRun(isCentral: false))
        XCTAssertTrue(status.safariHasRun(isCentral: true))
        XCTAssertTrue(status.shortcutHasRun(isCentral: false))
        XCTAssertTrue(status.shortcutHasRun(isCentral: true))

        status.resetAllRunEvidence()
        XCTAssertFalse(status.safariHasRun(isCentral: false))
        XCTAssertFalse(status.safariHasRun(isCentral: true))
        XCTAssertFalse(status.shortcutHasRun(isCentral: false))
        XCTAssertFalse(status.shortcutHasRun(isCentral: true))
    }

    @MainActor
    func testSetupCardButtonsAreHittableAfterTheCleanup() throws {
        let safari = SafariReplicaViewController(
            configuration: .configuration(for: .reader))
        let window = UIWindow(frame: CGRect(
            origin: .zero,
            size: AppLaunchGeometry.referenceSize))
        window.rootViewController = safari
        window.makeKeyAndVisible()
        safari.view.layoutIfNeeded()
        defer { window.isHidden = true }

        let article = try XCTUnwrap(
            safari.view.descendants(of: OnboardingArticleReplicaView.self).first)
        let cleaned = expectation(description: "cleanup")
        article.cleanUpClutter { cleaned.fulfill() }
        wait(for: [cleaned], timeout: 6)

        for label in ["Activate Safari", "Skip"] {
            let button = try XCTUnwrap(
                article.descendants(of: UIButton.self).first {
                    $0.accessibilityLabel == label
                })
            let point = window.convert(
                CGPoint(x: button.bounds.midX, y: button.bounds.midY),
                from: button)
            let hit = window.hitTest(point, with: nil)
            XCTAssertNotNil(hit)
            XCTAssertTrue(
                hit === button || hit?.isDescendant(of: button) == true,
                "\(label) at \(point) is shadowed by \(String(describing: hit))")
        }
    }

    @MainActor
    func testSetupCardButtonsAreHittableInsideTheFullOnboardingHierarchy() throws {
        let suite = "ReaderOnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let onboarding = AppOnboardingViewController(
            configuration: .configuration(for: .reader),
            onboardingStore: AppOnboardingStore(app: .reader, defaults: defaults),
            completion: AppOnboardingCompletion(
                temporarySave: OnboardingTemporarySave(
                    install: { true },
                    cleanup: {}),
                makeCompletedRootViewController: {
                    UINavigationController(rootViewController: UIViewController())
                }))
        let window = UIWindow(frame: CGRect(
            origin: .zero,
            size: AppLaunchGeometry.referenceSize))
        window.rootViewController = onboarding
        window.makeKeyAndVisible()
        onboarding.view.layoutIfNeeded()
        defer { window.isHidden = true }

        let button = try XCTUnwrap(
            onboarding.view.descendants(of: UIButton.self).first {
                $0.accessibilityLabel == "Let's go"
            })
        button.sendActions(for: .touchUpInside)

        // Ride the real staged sequence — the buried page, the mock page
        // menu, the Manage Extensions sheet with its toggle, then the wipe —
        // until the setup card's buttons come out of the sweep hittable.
        func hitView(for label: String) -> (button: UIButton, hit: UIView?)? {
            guard let cardButton = onboarding.view
                .descendants(of: UIButton.self).first(where: {
                    $0.accessibilityLabel == label
                })
            else { return nil }
            let point = window.convert(
                CGPoint(x: cardButton.bounds.midX, y: cardButton.bounds.midY),
                from: cardButton)
            return (cardButton, window.hitTest(point, with: nil))
        }
        func isHittable(_ label: String) -> Bool {
            guard let probe = hitView(for: label) else { return false }
            return probe.hit === probe.button
                || probe.hit?.isDescendant(of: probe.button) == true
        }
        let deadline = Date(timeIntervalSinceNow: 20)
        while Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            if isHittable("Activate Safari"), isHittable("Skip") { break }
        }

        for label in ["Activate Safari", "Skip"] {
            let probe = try XCTUnwrap(hitView(for: label))
            let article = onboarding.view
                .descendants(of: OnboardingArticleReplicaView.self).first
            let buttonFrame = window.convert(
                probe.button.bounds, from: probe.button)
            let articleFrame = article.map {
                window.convert($0.bounds, from: $0)
            }
            XCTAssertTrue(
                probe.hit === probe.button
                    || probe.hit?.isDescendant(of: probe.button) == true,
                """
                \(label) is shadowed by \(String(describing: probe.hit)); \
                button in window: \(buttonFrame), \
                article in window: \(String(describing: articleFrame)), \
                button superview chain: \(sequence(
                    first: probe.button as UIView, next: \.superview)
                    .map { "\(type(of: $0)) \($0.frame) hidden=\($0.isHidden) alpha=\($0.alpha)" }
                    .joined(separator: " <- "))
                """)
        }

        // Skipping must ride the same rails as a completed Safari setup: the
        // staged save plays and hands off to the Messages demonstration.
        let skip = try XCTUnwrap(
            onboarding.view.descendants(of: UIButton.self).first {
                $0.accessibilityLabel == "Skip"
            })
        skip.sendActions(for: .touchUpInside)
        let messagesDeadline = Date(timeIntervalSinceNow: 15)
        var messages: MessagesReplicaViewController?
        while Date() < messagesDeadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            messages = onboarding.children.compactMap {
                $0 as? MessagesReplicaViewController
            }.first
            if let messages, !messages.view.isHidden { break }
        }
        XCTAssertEqual(
            try XCTUnwrap(messages).view.isHidden, false,
            "Skip must continue into the Messages demonstration")
    }

    func testFakeDemoPagesAndNASAClipAreFullyBundled() throws {
        let instaTokURL = try XCTUnwrap(
            Bundle.main.url(forResource: "InstaTok", withExtension: "html"))
        let instaTok = try String(contentsOf: instaTokURL, encoding: .utf8)
        XCTAssertTrue(instaTok.contains("InstaTok"))
        XCTAssertTrue(instaTok.contains("Sign up to keep watching"))
        XCTAssertTrue(instaTok.contains("LunaEclipse.mp4"))
        XCTAssertFalse(instaTok.contains("src=\"http"))

        let amayzonURL = try XCTUnwrap(
            Bundle.main.url(forResource: "Amayzon", withExtension: "html"))
        let amayzon = try String(contentsOf: amayzonURL, encoding: .utf8)
        XCTAssertTrue(amayzon.contains("amay<em>zon</em>"))
        XCTAssertTrue(amayzon.contains("eyePhone Air"))
        XCTAssertFalse(amayzon.contains("Apple"))
        XCTAssertFalse(amayzon.contains("src=\"http"))

        let videoURL = try XCTUnwrap(
            Bundle.main.url(forResource: "LunaEclipse", withExtension: "mp4"))
        let attributes = try FileManager.default.attributesOfItem(atPath: videoURL.path)
        let byteCount = try XCTUnwrap(attributes[.size] as? NSNumber).intValue
        XCTAssertEqual(byteCount, 509_683)

        let attributionURL = try XCTUnwrap(
            Bundle.main.url(
                forResource: "LunaEclipseAttribution", withExtension: "txt"))
        let attribution = try String(contentsOf: attributionURL, encoding: .utf8)
        XCTAssertTrue(attribution.contains("NASA Scientific Visualization Studio"))
        XCTAssertTrue(attribution.contains("https://svs.gsfc.nasa.gov/5604/"))

        let compositeURL = try XCTUnwrap(
            Bundle.main.url(
                forResource: "LunaEclipseComposite", withExtension: "jpg"))
        let compositeBytes = try XCTUnwrap(
            try FileManager.default.attributesOfItem(
                atPath: compositeURL.path)[.size] as? NSNumber).intValue
        XCTAssertLessThan(
            compositeBytes, 120_000,
            "The banner image must stay too small to bloat the app")
        let composite = try XCTUnwrap(UIImage(contentsOfFile: compositeURL.path))
        XCTAssertGreaterThan(
            composite.size.width / composite.size.height, 2.2,
            "The article banner needs a wide aspect")

        let compositeAttributionURL = try XCTUnwrap(
            Bundle.main.url(
                forResource: "LunaEclipseCompositeAttribution",
                withExtension: "txt"))
        let compositeAttribution = try String(
            contentsOf: compositeAttributionURL, encoding: .utf8)
        XCTAssertTrue(compositeAttribution.contains("NASA/Eric Bordelon"))
        XCTAssertTrue(compositeAttribution.contains(
            "https://images.nasa.gov/details/MAF_20250314_LunarEclipse_composite"))
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

private extension UIViewController {
    func descendantControllers<Controller: UIViewController>(
        of type: Controller.Type
    ) -> [Controller] {
        children.flatMap { child -> [Controller] in
            let matching = (child as? Controller).map { [$0] } ?? []
            return matching + child.descendantControllers(of: type)
        }
    }
}
