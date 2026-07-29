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
        XCTAssertEqual(content.title, "Luna")
        XCTAssertEqual(content.author, "Wikipedia contributors")
        XCTAssertGreaterThan(content.blocks.count, 10)
        XCTAssertTrue(content.blocks.contains {
            $0.text.contains("Creative Commons Attribution-ShareAlike 4.0")
        })
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
        let temporaryURL = "https://en.wikipedia.org/wiki/Luna?test=temporary"
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
        XCTAssertEqual(reader.demoPages, [.wikipedia])
        XCTAssertEqual(
            reader.demoPages.first?.sharedURLString,
            "https://en.wikipedia.org/wiki/Luna")

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
        XCTAssertEqual(luna.demoPages, [.wikipedia, .instaTok, .amayzon])
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

        let supportingLabel = try XCTUnwrap(
            intro.view.subviews.compactMap { $0 as? UILabel }.first {
                $0.accessibilityIdentifier == "onboarding.intro.supportingText"
            })
        let button = try XCTUnwrap(
            intro.view.subviews.compactMap { $0 as? UIButton }.first)
        XCTAssertEqual(supportingLabel.numberOfLines, 2)
        XCTAssertEqual(supportingLabel.alpha, 0)
        XCTAssertEqual(
            supportingLabel.frame.minY - lines[1].frame.maxY,
            button.frame.minY - supportingLabel.frame.maxY,
            accuracy: 0.001)
        XCTAssertEqual(
            button.configuration?.title,
            "Show me how")
        XCTAssertEqual(button.accessibilityLabel, "Show me how")
        let tintAlpha = try XCTUnwrap(
            button.configuration?.baseBackgroundColor?.cgColor.alpha)
        XCTAssertEqual(tintAlpha, 0.24, accuracy: 0.001)
    }

    func testIntroWaveAndDemoLoopTimingsStayDeliberateButBrisk() {
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
            OnboardingDemoLoopTiming.firstLoopSavedCardHoldDuration,
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
    }

    func testDemoLoopAlternatesSafariSaveThenMessagesSave() {
        XCTAssertEqual(
            OnboardingDemoSource.allCases,
            [.safari, .messages])
        XCTAssertEqual(OnboardingDemoSource.safari.next, .messages)
        XCTAssertEqual(OnboardingDemoSource.messages.next, .safari)
    }

    @MainActor
    func testMessagesReplicaHasJohnnyPrivacyPlaceholdersAndSafariURL() throws {
        let urlString = OnboardingDemoPage.wikipedia.sharedURLString
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
        let placeholders = messages.view.descendants(of: UIView.self).compactMap {
            $0.accessibilityIdentifier
        }

        XCTAssertEqual(sender.text, "Johnny Appleseed")
        XCTAssertEqual(latestURL.text, urlString)
        XCTAssertEqual(
            placeholders.filter {
                $0 == "onboarding.messages.placeholder.incoming"
            }.count,
            2)
        XCTAssertEqual(
            placeholders.filter {
                $0 == "onboarding.messages.placeholder.outgoing"
            }.count,
            2)
        XCTAssertFalse(messages.isURLHighlighted)
        messages.setURLHighlighted(true)
        XCTAssertTrue(messages.isURLHighlighted)
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
        XCTAssertEqual(messagesRegion.frame.width, 280, accuracy: 0.001)
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
            urlString: OnboardingDemoPage.wikipedia.sharedURLString)
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
        XCTAssertTrue(messages.isURLHighlighted)
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
        XCTAssertEqual(
            Set(mountedLabels),
            Set(["Set up Safari", "Install Shortcut", "Set action button"]))
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
                $0.accessibilityLabel == "Show me how"
            })
        UIView.setAnimationsEnabled(false)
        defer {
            UIView.setAnimationsEnabled(true)
            window.isHidden = true
        }
        button.sendActions(for: .touchUpInside)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

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
        XCTAssertTrue(
            onboarding.view.descendants(of: EclipseCoronaView.self).isEmpty,
            "Pressing Show me how must remove the retained corona before expansion")
    }

    @MainActor
    func testLaunchRevealPreloadsTheDemonstrationBehindTheIntro() throws {
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

        onboarding.appLaunchTransitionWillReveal()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

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

    func testOfflineWikipediaPageIsBundledWithoutRemoteSubresources() throws {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "LunaWikipedia", withExtension: "html"))
        let html = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(html.contains("<h1>Luna</h1>"))
        XCTAssertTrue(html.contains("Creative Commons"))
        XCTAssertFalse(html.contains("<script"))
        XCTAssertFalse(html.contains("src=\"http"))
        XCTAssertFalse(html.contains("href=\"http"))
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
