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

    func testEveryOnboardingArticleSurfaceShowsTheSameFeatureList() {
        let plain = OnboardingLunaArticleCopy.plainText
        XCTAssertTrue(plain.hasPrefix(OnboardingLunaArticleCopy.intro))
        for feature in OnboardingLunaArticleCopy.features {
            XCTAssertTrue(
                plain.contains("• " + feature),
                "The rendered list must carry every feature line verbatim")
        }
        // One line per feature, so the mock surfaces read as a list and not a
        // paragraph that happens to contain bullets.
        XCTAssertEqual(
            plain.components(separatedBy: "\n").count,
            OnboardingLunaArticleCopy.features.count + 1)

        // Luna's own prose never says "paywall" — the pages ask you to
        // subscribe, so every surface calls them subscription walls.
        let everyLine = [
            plain,
            OnboardingSafariExtensionCopy.title,
            OnboardingSafariExtensionCopy.explainer,
            OnboardingSafariExtensionCopy.stepsHeading,
        ] + OnboardingSafariExtensionCopy.steps(appName: "Luna").map(\.text)
        for line in everyLine {
            XCTAssertFalse(
                line.lowercased().contains("paywall"),
                "“\(line)” must not say paywall")
        }
    }

    /// The demonstration is a picture, not a save. Every mock surface renders
    /// `OnboardingLunaArticleCopy` itself, so entering a lesson must leave the
    /// deck exactly as empty as the user left it.
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
                $0.accessibilityLabel == "Remove popups and walls for me"
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

    func testEverySurfaceHasItsExactCopyAndDemoPage() {
        let reader = OnboardingSurfaceConfiguration.configuration(for: .reader)
        XCTAssertEqual(
            reader.introCopy, .growingLine(stem: "Read", tail: " more."))
        XCTAssertEqual(
            reader.supportingText,
            "Save onscreen links with one click.\nUnlock or read offline later.")
        XCTAssertEqual(reader.saveBenefit, "Read offline later")
        XCTAssertEqual(reader.demoPages, [.lunaPage])
        XCTAssertEqual(
            reader.demoPages.first?.sharedURLString,
            "https://luna.app/about")

        let downloader = OnboardingSurfaceConfiguration.configuration(for: .downloader)
        XCTAssertEqual(
            downloader.introCopy,
            .twoLines(
                first: "App signup required? So annoying.",
                second: "Watch and share instantly instead."))
        XCTAssertEqual(
            downloader.supportingText,
            "Download any video link in one click,\nno signup required.")
        XCTAssertEqual(downloader.saveBenefit, "Watch or share")
        XCTAssertEqual(downloader.demoPages, [.instaTok])
        XCTAssertEqual(
            downloader.demoPages.first?.sharedURLString,
            "https://instatok.local/@moonwatch/lunar-eclipse")

        let price = OnboardingSurfaceConfiguration.configuration(for: .priceTracker)
        XCTAssertEqual(
            price.introCopy,
            .twoLines(
                first: "Overpaid? Missed a sale?",
                second: "Never miss out again."))
        XCTAssertEqual(
            price.supportingText,
            "Track sales for any link\nin one click.")
        XCTAssertEqual(price.saveBenefit, "Never miss a sale")
        XCTAssertEqual(price.demoPages, [.amayzon])
        XCTAssertEqual(
            price.demoPages.first?.sharedURLString,
            "https://amayzon.local/eyephone-air")

        let luna = OnboardingSurfaceConfiguration.configuration(for: .luna)
        XCTAssertEqual(
            luna.introCopy,
            .twoLines(
                first: "All your Luna saves.", second: "In a single app."))
        XCTAssertEqual(
            luna.supportingText,
            "Save any link on your screen\nwith one click.")
        XCTAssertEqual(luna.saveBenefit, "Read, watch, track, anything")
        XCTAssertEqual(luna.demoPages, [.lunaPage, .instaTok, .amayzon])
    }

    @MainActor
    func testIntroStagesTheSameRevealAcrossBothLines() throws {
        let intro = OnboardingIntroCardContentViewController(
            introCopy: .twoLines(
                first: "You want to read more.",
                second: "Let’s make that happen."),
            supportingText:
                "Save onscreen links with one click.\nUnlock or read offline later.")
        intro.loadViewIfNeeded()
        intro.view.frame = CGRect(x: 0, y: 0, width: 354, height: 629)
        intro.view.layoutIfNeeded()

        let lines = intro.view.descendants(of: MoonRevealLineView.self)
        XCTAssertEqual(lines.count, 2)
        XCTAssertFalse(lines[0].isFullyRevealed)
        XCTAssertFalse(lines[1].isFullyRevealed)
        XCTAssertFalse(lines[0].occluderHasVisibleChrome)
        XCTAssertTrue(lines[0].occluderIsFullyOpaque)
        XCTAssertTrue(lines[0].usesGlyphEdgeIllumination)
        XCTAssertFalse(lines[1].occluderHasVisibleChrome)
        XCTAssertTrue(lines[1].occluderIsFullyOpaque)
        XCTAssertTrue(lines[1].usesGlyphEdgeIllumination)

        let buttons = intro.view.descendants(of: UIButton.self)
        XCTAssertEqual(intro.view.backgroundColor, .black)
        XCTAssertFalse(intro.view.subviews.contains {
            $0.accessibilityIdentifier == "onboarding.intro.iconCluster"
        })
        XCTAssertTrue(
            intro.view.subviews.compactMap { $0 as? UILabel }.allSatisfy {
                $0.accessibilityIdentifier != "onboarding.intro.supportingText"
            })
        XCTAssertTrue(buttons.contains {
            $0.accessibilityLabel == "Remove popups and walls for me"
                && $0.configuration?.image != nil
        })
        XCTAssertTrue(buttons.contains {
            $0.accessibilityLabel
                == "Save on-screen links with the Action Button"
                && $0.configuration?.image != nil
        })
        XCTAssertNotNil(intro.view.descendants(of: UIPasteControl.self).first)
        XCTAssertTrue(intro.view.descendants(of: UILabel.self).contains {
            $0.text == "Paste a url"
        })
        let button = try XCTUnwrap(buttons.first {
            $0.accessibilityLabel == "Remove popups and walls for me"
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

    @MainActor
    func testGrowingIntroCentresTheFinishedSentenceAndNeverMovesItsStem() throws {
        let intro = OnboardingIntroCardContentViewController(
            introCopy: .growingLine(stem: "Read", tail: " more."),
            supportingText: "")
        intro.loadViewIfNeeded()
        intro.view.frame = CGRect(x: 0, y: 0, width: 354, height: 629)
        intro.view.layoutIfNeeded()

        let headline = try XCTUnwrap(
            intro.view.subviews.compactMap {
                $0 as? OnboardingIntroHeadlineView
            }.first)
        let growing = try XCTUnwrap(headline.growingLine)
        let (stem, period, tail) = growing.fragments

        XCTAssertEqual(
            headline.frame.minY,
            AppOnboardingLayout.contentTop(in: intro.view.bounds),
            accuracy: 0.01,
            "One line keeps the vertical position the first of two lines had")
        XCTAssertEqual(headline.frame.height, 44, accuracy: 0.01)

        // One frame and one typesetting for all three fragments: the second
        // beat has nothing to translate.
        XCTAssertEqual(stem.frame, period.frame)
        XCTAssertEqual(stem.frame, tail.frame)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 25, weight: .semibold),
            .kern: 0,
        ]
        func width(_ string: String) -> CGFloat {
            NSAttributedString(string: string, attributes: attributes).size().width
        }
        let origin = stem.frame.minX
        XCTAssertEqual(
            origin + width("Read more.") / 2, growing.bounds.midX, accuracy: 1,
            "The finished sentence is what is centred")
        XCTAssertLessThan(
            origin + width("Read.") / 2, growing.bounds.midX - 20,
            "“Read.” therefore lands left of centre, which is the point")

        for fragment in [stem, period, tail] {
            XCTAssertFalse(fragment.isFullyRevealed)
            XCTAssertTrue(fragment.usesGlyphEdgeIllumination)
            XCTAssertFalse(fragment.occluderHasVisibleChrome)
        }

        let firstBeat = expectation(description: "stem and its period arrive")
        growing.revealFirstBeat(duration: 0.02) { firstBeat.fulfill() }
        wait(for: [firstBeat], timeout: 5)
        XCTAssertTrue(stem.isFullyRevealed)
        XCTAssertTrue(period.isFullyRevealed)
        XCTAssertFalse(tail.isFullyRevealed)
        XCTAssertEqual(growing.accessibilityLabel, "Read.")

        let stemFrame = stem.frame
        let secondBeat = expectation(description: "the tail replaces the period")
        growing.revealSecondBeat(duration: 0.02) { secondBeat.fulfill() }
        wait(for: [secondBeat], timeout: 5)
        XCTAssertTrue(tail.isFullyRevealed)
        XCTAssertTrue(period.isFullyConcealed)
        XCTAssertFalse(period.isFullyRevealed)
        XCTAssertTrue(
            stem.isFullyRevealed, "The second beat does not touch the stem")
        XCTAssertEqual(stem.frame, stemFrame)
        XCTAssertEqual(growing.accessibilityLabel, "Read more.")
        XCTAssertTrue(growing.isAccessibilityElement)
        XCTAssertFalse(stem.isAccessibilityElement)
    }

    @MainActor
    func testGrowingIntroStartsThePeriodsExitWithTheTailsArrival() {
        let font = UIFont.systemFont(ofSize: 25, weight: .semibold)
        let growing = MoonRevealGrowingLineView(
            stem: "Read", tail: " more.", font: font)

        // A period's ink sits about an x-height below “more”'s, and one front
        // descending through the shared frame would reach it that much later —
        // uncovering the top of the “m” while the period still stood beside it.
        // The period's own front starts that far ahead so both tops go at once.
        let xHeight = font.xHeight
        XCTAssertGreaterThan(
            growing.periodFrontLead, xHeight * 0.4,
            "Without a real lead the period outlives the tail's first glyph")
        XCTAssertLessThan(
            growing.periodFrontLead, xHeight,
            "The lead is a drop between two inks, not a whole glyph height")
    }

    @MainActor
    func testIntroRestoresCompletedSetupArtworkBeforeItsViewLoads() throws {
        let intro = OnboardingIntroCardContentViewController(
            introCopy: .twoLines(
                first: "You want to read more.",
                second: "Let’s make that happen."),
            supportingText: "")
        intro.setState(safari: .completed, shortcut: .completed)
        intro.loadViewIfNeeded()

        for label in [
            "Remove popups and walls for me",
            "Save on-screen links with the Action Button",
        ] {
            let button = try XCTUnwrap(
                intro.view.descendants(of: UIButton.self).first {
                    $0.accessibilityLabel == label
                })
            XCTAssertFalse(button.isEnabled)
            XCTAssertEqual(button.accessibilityValue, "Completed")
            XCTAssertEqual(
                button.configuration?.image,
                UIImage(systemName: "checkmark.circle.fill"))
        }
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
        XCTAssertGreaterThanOrEqual(
            OnboardingShortcutRunTiming.skipMessageDelay, 2.0,
            "The install pill gets the screen to itself before the way out "
                + "is offered alongside it")
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

        stage = .messagesDemonstration
        XCTAssertEqual(stage.completedSave(from: .messages), .actionButton)
        XCTAssertEqual(stage, .actionButtonSetup)
    }

    @MainActor
    func testMessagesReplicaShowsTheStagedConversationAndSafariURL() throws {
        let urlString = OnboardingDemoPage.lunaPage.sharedURLString
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
        // The friend opens the thread, asks, hears the Action Button is dead,
        // and offers what theirs does — then the link.
        XCTAssertTrue(labels.contains("Yoooooo"))
        XCTAssertTrue(labels.contains(
            "You using your action button for anything?"))
        XCTAssertTrue(labels.contains("Nah. Its kinda dead tbh."))
        XCTAssertTrue(labels.contains(
            "I use it to instant save any link on screen. Check it:"))
        XCTAssertTrue(bubbles.contains("onboarding.messages.greeting"))
        XCTAssertTrue(bubbles.contains("onboarding.messages.question"))
        XCTAssertTrue(bubbles.contains("onboarding.messages.answer"))
        XCTAssertTrue(bubbles.contains("onboarding.messages.pitch"))
        XCTAssertGreaterThan(
            messages.actionButtonReplayDelay,
            OnboardingDemoLoopTiming.sourceHoldDuration)
        // One gap per hand-off between the staged arrivals — five messages,
        // four gaps. Their exact lengths are a tuning knob; only floor them,
        // so every bubble still lands as its own beat.
        XCTAssertEqual(
            OnboardingMessagesReplicaTiming.stagedMessageDelays.count, 4)
        for delay in OnboardingMessagesReplicaTiming.stagedMessageDelays {
            XCTAssertGreaterThanOrEqual(
                delay, 0.6,
                "Even the tightest hand-off is somebody typing, not a "
                    + "transcript unrolling")
        }
        XCTAssertFalse(messages.isURLHighlighted)
        messages.setURLHighlighted(true)
        XCTAssertTrue(messages.isURLHighlighted)
    }

    @MainActor
    func testMessagesSetupPillsGlowUntilTheyDriveTheirSetupHops() throws {
        let messages = MessagesReplicaViewController(
            urlString: OnboardingDemoPage.lunaPage.sharedURLString)
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
        XCTAssertTrue(bubbles.contains("onboarding.messages.skipSetup"))
        // Each pill flows INLINE with its sentence: the words live in a text
        // view whose attachment reserves the pill's spot in the line flow.
        let sentences = messages.view.descendants(of: UITextView.self)
            .compactMap(\.text)
        XCTAssertTrue(sentences.contains {
            $0.hasPrefix("Just install this shortcut")
        })
        XCTAssertTrue(sentences.contains {
            $0.hasPrefix("Then set your action button to it in")
        })
        XCTAssertTrue(sentences.contains { $0.hasPrefix("Or") })
        let labels = messages.view.descendants(of: UILabel.self).compactMap(\.text)
        XCTAssertTrue(labels.contains("Luna"))
        XCTAssertTrue(labels.contains("Settings"))
        XCTAssertTrue(labels.contains("skip setup"))

        let shortcutPill = try XCTUnwrap(
            messages.view.descendants(of: OnboardingMessagePillButton.self).first {
                $0.accessibilityIdentifier == "onboarding.messages.shortcutPill"
            })
        let settingsPill = try XCTUnwrap(
            messages.view.descendants(of: OnboardingMessagePillButton.self).first {
                $0.accessibilityIdentifier == "onboarding.messages.settingsPill"
            })
        let skipPill = try XCTUnwrap(
            messages.view.descendants(of: OnboardingMessagePillButton.self).first {
                $0.accessibilityIdentifier == "onboarding.messages.skipPill"
            })

        // The demonstration hasn't reached the setup messages yet.
        XCTAssertFalse(messages.isShowingSetupMessages)

        var installedShortcut = false
        var openedSettings = false
        var skipped = false
        messages.onInstallShortcut = { installedShortcut = true }
        messages.onSetActionButton = { openedSettings = true }
        messages.onSkipSetup = { skipped = true }

        // The way out never asks for the tap the two setup pills are asking
        // for: no corona, no pulse.
        let pulseKey = OnboardingMessagePillButton.pulseAnimationKey
        skipPill.beginAttentionPulse()
        XCTAssertNil(
            skipPill.layer.animation(forKey: pulseKey),
            "The skip-out must never pulse for attention")
        XCTAssertTrue(
            skipPill.descendants(of: EclipseCoronaView.self).isEmpty,
            "The skip-out must never wear a corona")

        shortcutPill.beginAttentionPulse()
        XCTAssertNotNil(
            shortcutPill.layer.animation(forKey: pulseKey),
            "The shortcut pill must pulse until tapped")
        let shortcutCorona = try XCTUnwrap(
            shortcutPill.descendants(of: EclipseCoronaView.self).first,
            "The shortcut pill's attention cue is its corona")
        XCTAssertNotNil(
            shortcutCorona.layer.animation(forKey: pulseKey),
            "The corona breathes with the pill it surrounds")

        shortcutPill.sendActions(for: .touchUpInside)
        XCTAssertTrue(installedShortcut)
        XCTAssertTrue(shortcutPill.wasActivated)
        XCTAssertNil(
            shortcutPill.layer.animation(forKey: pulseKey),
            "Tapping the pill must stop its corona pulse")
        XCTAssertEqual(shortcutCorona.alpha, 0)
        shortcutPill.beginAttentionPulse()
        XCTAssertNil(
            shortcutPill.layer.animation(forKey: pulseKey),
            "An activated pill never resumes pulsing")

        settingsPill.sendActions(for: .touchUpInside)
        XCTAssertTrue(openedSettings)

        skipPill.sendActions(for: .touchUpInside)
        XCTAssertTrue(skipped)
    }

    /// The Settings message is the one bubble that does NOT arrive at the
    /// bottom: by the time the user is back from the Shortcuts install the
    /// skip-out is already sitting below the shortcut message, so Settings
    /// has to open a space between the two.
    @MainActor
    func testTheSettingsMessageLandsAboveTheSkipOutThatBeatItThere() throws {
        let messages = MessagesReplicaViewController(
            urlString: OnboardingDemoPage.lunaPage.sharedURLString)
        let window = UIWindow(
            frame: CGRect(origin: .zero, size: AppLaunchGeometry.referenceSize))
        window.rootViewController = messages
        window.makeKeyAndVisible()
        messages.view.layoutIfNeeded()
        defer { window.isHidden = true }

        func bubble(_ identifier: String) throws -> OnboardingMessageBubble {
            try XCTUnwrap(
                messages.view.descendants(of: OnboardingMessageBubble.self).first {
                    $0.accessibilityIdentifier == identifier
                })
        }
        let shortcut = try bubble("onboarding.messages.shortcutSetup")
        let settings = try bubble("onboarding.messages.settingsSetup")
        let skip = try bubble("onboarding.messages.skipSetup")

        // Collapsed until it arrives, so the skip-out sits directly under the
        // shortcut message rather than over an empty gap.
        XCTAssertTrue(try XCTUnwrap(settings.superview).isHidden)

        // Land the whole thread rather than waiting out the mock shortcut run.
        messages.revealStagedConversationImmediately()
        messages.revealSetupMessagesImmediately()
        messages.view.layoutIfNeeded()

        XCTAssertTrue(messages.isShowingSetupMessages)
        XCTAssertFalse(try XCTUnwrap(settings.superview).isHidden)

        func midY(_ view: UIView) -> CGFloat {
            messages.view.convert(view.bounds, from: view).midY
        }
        XCTAssertLessThan(midY(shortcut), midY(settings))
        XCTAssertLessThan(midY(settings), midY(skip))
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
            urlString: OnboardingDemoPage.lunaPage.sharedURLString)
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
    func testOnboardingKeepsLaunchCoronaUntilSafariSetupThenExpandsWithoutIt() throws {
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
                $0.accessibilityLabel == "Remove popups and walls for me"
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
            "Starting Safari setup must remove the retained corona before expansion")
    }

    @MainActor
    func testFirstLineRevealPreloadsTheReplicasAndProductionRoot() throws {
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
                makeCompletedRootViewController: { productionRoot }))
        let window = UIWindow(frame: CGRect(
            origin: .zero,
            size: AppLaunchGeometry.referenceSize))
        window.rootViewController = onboarding
        window.makeKeyAndVisible()
        onboarding.view.layoutIfNeeded()
        defer { window.isHidden = true }

        onboarding.firstIntroLineDidReveal()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertNotNil(onboarding.children.first {
            $0 is SafariReplicaViewController
        })
        XCTAssertNotNil(onboarding.children.first {
            $0 is MessagesReplicaViewController
        })
        XCTAssertTrue(
            onboarding.savedRootViewControllerForTesting === productionRoot)
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
    func testSafariPageIsTheExtensionExplainerAnchoredToItsActions() throws {
        let appName = LunaApp.reader.displayName
        let page = OnboardingSafariPageView(
            configuration: .configuration(for: .reader))
        page.frame = CGRect(
            origin: .zero,
            size: CGSize(
                width: AppLaunchGeometry.referenceSize.width,
                height: AppLaunchGeometry.referenceSize.height - 59))
        page.layoutIfNeeded()

        let labels = page.descendants(of: UILabel.self).compactMap(\.text)
        let revealLines = page.descendants(of: MoonRevealLineView.self)

        // The page loads fully readable underneath — nothing waits on a
        // reveal — and it is the extension's own explanation, in the running
        // app's name, not a fictional article.
        XCTAssertTrue(revealLines.allSatisfy(\.isFullyRevealed))
        let revealCopy = revealLines.compactMap(\.accessibilityLabel)
        XCTAssertTrue(revealCopy.contains(OnboardingSafariExtensionCopy.title))
        XCTAssertTrue(revealCopy.contains(
            OnboardingSafariExtensionCopy.byline(appName: appName)))
        XCTAssertTrue(
            revealCopy.contains(OnboardingSafariExtensionCopy.explainer))
        XCTAssertTrue(
            revealCopy.contains(OnboardingSafariExtensionCopy.stepsHeading))

        // Three enable steps, each beside a picture of the exact chrome it
        // names: the browser bar's own page-menu symbol, the puzzle row it
        // opens, and the app's real icon beside a switch already flipped on.
        let steps = OnboardingSafariExtensionCopy.steps(appName: appName)
        XCTAssertEqual(steps.count, 3)
        let stepRows = try (0..<steps.count).map { index in
            try XCTUnwrap(page.descendants(of: UIView.self).first {
                $0.accessibilityIdentifier
                    == "onboarding.safari.page.step.\(index)"
            })
        }
        for (index, step) in steps.enumerated() {
            XCTAssertEqual(stepRows[index].accessibilityLabel, step.text)
        }
        // Safari lists each app's extension under that app's own name (each
        // target gives its copy of the appex its own CFBundleDisplayName), so
        // the step names the RUNNING app — not the central app, and not a
        // generic "the extension".
        XCTAssertEqual(steps[2].text, "Switch on \(appName)")
        XCTAssertEqual(appName, "Luna Reader")
        XCTAssertTrue(steps[1].text.contains(
            OnboardingSafariExtensionCopy.manageExtensionsTitle))
        let visuals = try stepRows.map { row in
            try XCTUnwrap(row.descendants(
                of: OnboardingSafariChromeVisualView.self).first)
        }
        XCTAssertEqual(visuals[0].symbolName, SafariBottomBar.pageMenuSymbol)
        XCTAssertEqual(visuals[1].symbolName, "puzzlepiece.extension.fill")
        XCTAssertNotNil(
            visuals[2].descendants(of: UIImageView.self).first?.image,
            "The last step carries the app's real icon")
        XCTAssertTrue(
            visuals[2].subviews.contains {
                $0.backgroundColor == OnboardingMockSwitchView.onColor
            },
            "…beside the switch the Manage Extensions sheet flips")

        // The steps and the actions are ANCHORED to the bottom of the page,
        // clear of the browser chrome, and the Safari action is the last thing
        // on the page. There is no setup card anywhere.
        let actions = try XCTUnwrap(
            page.descendants(of: OnboardingSafariActionsView.self).first)
        let actionsFrame = page.convert(actions.bounds, from: actions)
        XCTAssertEqual(
            actionsFrame.maxY,
            page.bounds.height - OnboardingSafariPageView.chromeReserve,
            accuracy: 0.5)
        XCTAssertLessThanOrEqual(
            actionsFrame.maxY,
            page.bounds.height - SafariBottomBar.chromeHeight)
        let explainer = try XCTUnwrap(revealLines.first {
            $0.accessibilityIdentifier == "onboarding.safari.page.explainer"
        })
        let headline = try XCTUnwrap(revealLines.first {
            $0.accessibilityIdentifier == "onboarding.safari.page.headline"
        })
        XCTAssertGreaterThan(stepRows[0].frame.minY, explainer.frame.maxY)
        XCTAssertGreaterThan(actionsFrame.minY, stepRows[2].frame.maxY)
        // A tall screen's slack collects ABOVE the header rather than in a hole
        // between the prose and the steps: the page hangs from its actions.
        XCTAssertGreaterThan(
            headline.frame.minY,
            stepRows[0].frame.minY - explainer.frame.maxY,
            "The page must hang from the bottom, not split around a gap")
        XCTAssertGreaterThanOrEqual(
            headline.frame.minY, OnboardingSafariPageView.minimumTopInset)
        XCTAssertTrue(
            page.descendants(of: CardSurfaceView.self).isEmpty,
            "The setup card is gone: the actions are the page's own content")
        let scroll = try XCTUnwrap(page.descendants(of: UIScrollView.self).first)
        XCTAssertFalse(scroll.isScrollEnabled, "The page never scrolls")
        XCTAssertEqual(scroll.contentOffset, .zero)

        // Every fake obstruction is mounted, fully visible from the first
        // frame, and inert.
        let clutter = try XCTUnwrap(page.descendants(of: UIView.self).first {
            $0.accessibilityIdentifier == "onboarding.safari.page.clutter"
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

        // The buried page registers before the Manage Extensions sheet — the
        // pass's first and only step — slides up, and the sheet is readable
        // before its switch moves.
        XCTAssertGreaterThanOrEqual(
            OnboardingExtensionEnableTiming.pageHoldDuration, 0.5)
        XCTAssertGreaterThanOrEqual(
            OnboardingExtensionEnableTiming.toggleDelay, 0.25)
    }

    /// The one-screen budget is real: on the shortest phone Luna ships to, the
    /// whole explainer — header, prose, three steps and both actions — still
    /// fits above the browser chrome without the prose being cut.
    @MainActor
    func testSafariPageFitsTheShortestPhoneWithoutTruncatingItsProse() throws {
        let page = OnboardingSafariPageView(
            configuration: .configuration(for: .reader))
        page.frame = CGRect(x: 0, y: 0, width: 375, height: 667 - 20)
        page.layoutIfNeeded()

        let explainer = try XCTUnwrap(
            page.descendants(of: MoonRevealLineView.self).first {
                $0.accessibilityIdentifier == "onboarding.safari.page.explainer"
            })
        let naturalHeight = (OnboardingSafariExtensionCopy.explainer as NSString)
            .boundingRect(
                with: CGSize(
                    width: explainer.frame.width,
                    height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [
                    .font: UIFont.systemFont(ofSize: 17, weight: .regular),
                    .paragraphStyle: {
                        let style = NSMutableParagraphStyle()
                        style.lineSpacing = 5
                        return style
                    }(),
                ],
                context: nil).height
        XCTAssertGreaterThanOrEqual(
            explainer.frame.height,
            ceil(naturalHeight),
            "Shorten the explainer copy: it no longer fits above the steps")
        let header = try XCTUnwrap(
            page.descendants(of: MoonRevealLineView.self).first {
                $0.accessibilityIdentifier == "onboarding.safari.page.headline"
            })
        XCTAssertGreaterThan(explainer.frame.minY, header.frame.maxY)
    }

    /// The enable pass skips Safari's page menu entirely: the sheet is up, and
    /// the wipe starts on the flip rather than waiting out its dismissal.
    @MainActor
    func testExtensionEnablePassGoesStraightToTheSheetAndWipesOnTheFlip() throws {
        let safari = SafariReplicaViewController(
            configuration: .configuration(for: .reader))
        let window = UIWindow(frame: CGRect(
            origin: .zero,
            size: AppLaunchGeometry.referenceSize))
        window.rootViewController = safari
        window.makeKeyAndVisible()
        safari.view.layoutIfNeeded()
        defer { window.isHidden = true }

        safari.beginDemonstration()
        let deadline = Date(timeIntervalSinceNow: 4)
        var sheet: OnboardingManageExtensionsSheetView?
        while Date() < deadline, sheet == nil {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            sheet = safari.view.descendants(
                of: OnboardingManageExtensionsSheetView.self).first
        }
        XCTAssertNotNil(
            sheet,
            "The pass must reach the Manage Extensions sheet with no page-menu step")

        // The row the switch belongs to is the RUNNING app's, named the way
        // Safari names it — the same name the page's last step tells you to
        // look for.
        let sheetLabels = try XCTUnwrap(sheet)
            .descendants(of: UILabel.self).compactMap(\.text)
        XCTAssertTrue(sheetLabels.contains(LunaApp.reader.displayName))
        XCTAssertTrue(sheetLabels.contains(
            OnboardingSafariExtensionCopy.manageExtensionsTitle))

        // The wipe's cue is the switch, not the sheet leaving: the page's
        // obstructions give way to their shatter tiles while the sheet is
        // still on screen sliding back down.
        let page = try XCTUnwrap(safari.view.descendants(
            of: OnboardingSafariPageView.self).first)
        let clutter = try XCTUnwrap(page.descendants(of: UIView.self).first {
            $0.accessibilityIdentifier == "onboarding.safari.page.clutter"
        })
        let wipeDeadline = Date(timeIntervalSinceNow: 8)
        while Date() < wipeDeadline,
              !clutter.subviews.allSatisfy(\.isHidden) {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        XCTAssertTrue(clutter.subviews.allSatisfy(\.isHidden))
        XCTAssertNotNil(
            safari.view.descendants(
                of: OnboardingManageExtensionsSheetView.self).first,
            "The wipe must start with the flip, not wait out the sheet's exit")

        // And the sweep still finishes on the page's own live actions.
        let actionsDeadline = Date(timeIntervalSinceNow: 8)
        let skip = try XCTUnwrap(page.descendants(
            of: UIButton.self).first { $0.accessibilityLabel == "Skip" })
        while Date() < actionsDeadline, !skip.isUserInteractionEnabled {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        XCTAssertTrue(skip.isUserInteractionEnabled)
        XCTAssertNil(
            safari.view.descendants(
                of: OnboardingManageExtensionsSheetView.self).first)
    }

    @MainActor
    func testCleanupShatterRevealsThePageAndIgnitesTheActionCorona() throws {
        let page = OnboardingSafariPageView(
            configuration: .configuration(for: .reader))
        let window = UIWindow(frame: CGRect(
            origin: .zero,
            size: CGSize(
                width: AppLaunchGeometry.referenceSize.width,
                height: AppLaunchGeometry.referenceSize.height - 59)))
        let host = UIViewController()
        host.view = page
        window.rootViewController = host
        window.makeKeyAndVisible()
        page.layoutIfNeeded()
        defer { window.isHidden = true }

        let finished = expectation(description: "cleanup shatter")
        page.cleanUpClutter {
            finished.fulfill()
        }
        wait(for: [finished], timeout: 15)

        let explainer = try XCTUnwrap(
            page.descendants(of: MoonRevealLineView.self).first {
                $0.accessibilityIdentifier == "onboarding.safari.page.explainer"
            })
        XCTAssertEqual(
            explainer.accessibilityLabel,
            OnboardingSafariExtensionCopy.explainer)
        XCTAssertTrue(explainer.isFullyRevealed)
        let clutter = try XCTUnwrap(page.descendants(of: UIView.self).first {
            $0.accessibilityIdentifier == "onboarding.safari.page.clutter"
        })
        XCTAssertTrue(clutter.subviews.allSatisfy(\.isHidden))

        // The wave leaves the page clean, the actions live, and the corona lit
        // behind the Safari button — every reveal mask torn down, no scroll
        // anywhere.
        let actions = try XCTUnwrap(
            page.descendants(of: OnboardingSafariActionsView.self).first)
        XCTAssertTrue(actions.activateButton.isUserInteractionEnabled)
        XCTAssertTrue(actions.skipButton.isUserInteractionEnabled)
        XCTAssertNil(actions.layer.mask, "The actions' reveal mask must be gone")
        let corona = try XCTUnwrap(
            page.descendants(of: EclipseCoronaView.self).first)
        XCTAssertEqual(corona.alpha, 1, accuracy: 0.001)
        let scroll = try XCTUnwrap(
            page.descendants(of: UIScrollView.self).first)
        XCTAssertEqual(scroll.contentOffset, .zero)
        let actionsFrame = page.convert(actions.bounds, from: actions)
        XCTAssertLessThanOrEqual(
            actionsFrame.maxY,
            page.bounds.height - SafariBottomBar.chromeHeight)
    }

    @MainActor
    func testPageActionsWearTheCoronaOnTheSafariButtonAndBothWork() throws {
        let safari = SafariReplicaViewController(
            configuration: .configuration(for: .reader))
        safari.loadViewIfNeeded()
        safari.view.frame = CGRect(
            origin: .zero,
            size: AppLaunchGeometry.referenceSize)
        safari.view.layoutIfNeeded()

        let page = try XCTUnwrap(
            safari.view.descendants(of: OnboardingSafariPageView.self).first)
        let actions = try XCTUnwrap(
            page.descendants(of: OnboardingSafariActionsView.self).first)

        // The corona is the SAFARI BUTTON's, not the block's: exactly its
        // capsule, exactly behind it.
        let corona = try XCTUnwrap(
            page.descendants(of: EclipseCoronaView.self).first)
        let buttonFrame = page.convert(
            actions.activateButton.bounds, from: actions.activateButton)
        XCTAssertEqual(page.convert(corona.bounds, from: corona), buttonFrame)
        XCTAssertGreaterThan(
            actions.skipButton.frame.minY, actions.activateButton.frame.maxY,
            "The skip sits under the button the corona surrounds")
        // Dark until the wave has passed: a lit corona over the buried page
        // would show through the clutter it is meant to be under.
        XCTAssertEqual(corona.alpha, 0, accuracy: 0.001)

        var didActivate = false
        var didSkip = false
        safari.onSetUpSafari = { didActivate = true }
        safari.onSkipSafariSetup = { didSkip = true }
        actions.activateButton.sendActions(for: .touchUpInside)
        XCTAssertTrue(didActivate)
        XCTAssertFalse(didSkip)
        safari.restoreInPageSafariSetup()
        XCTAssertTrue(actions.activateButton.isUserInteractionEnabled)
        actions.skipButton.sendActions(for: .touchUpInside)
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
    func testPageActionsAreHittableAfterTheCleanup() throws {
        let safari = SafariReplicaViewController(
            configuration: .configuration(for: .reader))
        let window = UIWindow(frame: CGRect(
            origin: .zero,
            size: AppLaunchGeometry.referenceSize))
        window.rootViewController = safari
        window.makeKeyAndVisible()
        safari.view.layoutIfNeeded()
        defer { window.isHidden = true }

        let page = try XCTUnwrap(
            safari.view.descendants(of: OnboardingSafariPageView.self).first)
        let cleaned = expectation(description: "cleanup")
        page.cleanUpClutter { cleaned.fulfill() }
        wait(for: [cleaned], timeout: 15)

        for label in ["Activate Safari", "Skip"] {
            let button = try XCTUnwrap(
                page.descendants(of: UIButton.self).first {
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
    func testPageActionsAreHittableInsideTheFullOnboardingHierarchy() throws {
        let suite = "ReaderOnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let onboarding = AppOnboardingViewController(
            configuration: .configuration(for: .reader),
            onboardingStore: AppOnboardingStore(app: .reader, defaults: defaults),
            completion: AppOnboardingCompletion(
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
                $0.accessibilityLabel == "Remove popups and walls for me"
            })
        button.sendActions(for: .touchUpInside)

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
        let deadline = Date(timeIntervalSinceNow: 20)
        while Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            if isHittable("Activate Safari"), isHittable("Skip") { break }
        }

        for label in ["Activate Safari", "Skip"] {
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
                $0.accessibilityLabel == "Skip"
            })
        skip.sendActions(for: .touchUpInside)
        let introDeadline = Date(timeIntervalSinceNow: 15)
        var safariIntroButton: UIButton?
        while Date() < introDeadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            safariIntroButton = onboarding.view.descendants(of: UIButton.self)
                .first {
                    $0.accessibilityLabel == "Remove popups and walls for me"
                }
            if onboarding.view.descendants(of: UIPasteControl.self)
                .first?.isHidden == false
            {
                break
            }
        }
        XCTAssertTrue(try XCTUnwrap(safariIntroButton).isEnabled)
        XCTAssertEqual(safariIntroButton?.accessibilityValue, "Skipped")
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
