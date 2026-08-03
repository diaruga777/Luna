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
            app: .reader, defaults: defaults, setupStatusStore: setup)
        let central = AppOnboardingStore(
            app: .luna, defaults: defaults, setupStatusStore: setup)
        setup.recordShortcutRun(for: .luna)
        XCTAssertFalse(facet.isCompleted)

        defaults.set(true, forKey: LunaSetupStatusStore.centralSafariKey)
        XCTAssertTrue(facet.isCompleted)
        XCTAssertFalse(central.isCompleted)
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
            OnboardingSafariExtensionCopy.stepsHeading,
        ] + LunaApp.allCases.flatMap {
            OnboardingSafariExtensionCopy.explainerChunks(for: $0)
        } + OnboardingSafariExtensionCopy.steps(
            appName: LunaApp.luna.displayName).map(\.text)
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
        XCTAssertEqual(reader.introCopy, OnboardingStrings.introCopy(for: .reader))
        XCTAssertEqual(
            reader.supportingText,
            OnboardingStrings.Intro.supportingText.value(for: .reader))
        XCTAssertEqual(
            reader.saveBenefit,
            OnboardingStrings.Intro.saveBenefit.value(for: .reader))
        XCTAssertEqual(reader.demoPages, [.lunaPage])
        XCTAssertEqual(
            reader.practiceURLString,
            OnboardingStrings.Demo.lunaURL.value())

        let downloader = OnboardingSurfaceConfiguration.configuration(for: .downloader)
        XCTAssertEqual(
            downloader.introCopy,
            OnboardingStrings.introCopy(for: .downloader))
        XCTAssertEqual(
            downloader.supportingText,
            OnboardingStrings.Intro.supportingText.value(for: .downloader))
        XCTAssertEqual(
            downloader.saveBenefit,
            OnboardingStrings.Intro.saveBenefit.value(for: .downloader))
        // Every app's Safari lesson opens on the native explainer page; the
        // app's OWN mock page follows it in the rotation.
        XCTAssertEqual(downloader.demoPages, [.lunaPage, .instaTok])
        XCTAssertEqual(
            downloader.practiceURLString,
            OnboardingStrings.Demo.instaTokURL.value())

        let price = OnboardingSurfaceConfiguration.configuration(for: .priceTracker)
        XCTAssertEqual(price.introCopy, OnboardingStrings.introCopy(for: .priceTracker))
        XCTAssertEqual(
            price.supportingText,
            OnboardingStrings.Intro.supportingText.value(for: .priceTracker))
        XCTAssertEqual(
            price.saveBenefit,
            OnboardingStrings.Intro.saveBenefit.value(for: .priceTracker))
        XCTAssertEqual(price.demoPages, [.lunaPage, .amayzon])
        XCTAssertEqual(
            price.practiceURLString,
            OnboardingStrings.Demo.amayzonURL.value())

        let luna = OnboardingSurfaceConfiguration.configuration(for: .luna)
        XCTAssertEqual(luna.introCopy, OnboardingStrings.introCopy(for: .luna))
        XCTAssertEqual(
            luna.supportingText,
            OnboardingStrings.Intro.supportingText.value(for: .luna))
        XCTAssertEqual(
            luna.saveBenefit,
            OnboardingStrings.Intro.saveBenefit.value(for: .luna))
        XCTAssertEqual(luna.demoPages, [.lunaPage, .instaTok, .amayzon])
        XCTAssertEqual(
            luna.practiceURLString,
            OnboardingStrings.Demo.lunaURL.value())

        // The practice link is declared per app, NOT read off the first demo
        // page: the browser now opens on the article explainer everywhere, and
        // the Downloader must still rehearse its save with a media link.
        XCTAssertNotEqual(
            downloader.practiceURLString,
            downloader.demoPages[0].sharedURLString)
    }

    func testTwoTapFallbackRequiresEitherMissingOnboardingRequirement() {
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

        XCTAssertEqual(mode(os: 26, model: "iPhone17,1"), .shareSheet)
        XCTAssertEqual(mode(os: 27, model: "iPhone15,4"), .shareSheet)
        XCTAssertEqual(mode(os: 27, model: "iPad16,3"), .shareSheet)
        XCTAssertEqual(
            mode(os: 27, model: "iPhone17,1", simulator: true),
            .shareSheet)
        XCTAssertEqual(mode(os: 27, model: "iPhone16,1"), .actionButtonShortcut)
        XCTAssertEqual(mode(os: 27, model: "iPhone16,2"), .actionButtonShortcut)
        XCTAssertEqual(mode(os: 27, model: "iPhone17,1"), .actionButtonShortcut)
    }

    func testSharePracticeRecognizesEveryMockLinkWithoutSavingVariants() throws {
        for value in ShareSetupPractice.urlStrings {
            XCTAssertTrue(ShareSetupPractice.matches(try XCTUnwrap(URL(string: value))))
            XCTAssertTrue(ShareSetupPractice.matches(try XCTUnwrap(URL(string: value + "/#demo"))))
        }
        XCTAssertFalse(ShareSetupPractice.matches(
            try XCTUnwrap(URL(string: "https://example.com/about"))))
    }

    @MainActor
    func testFallbackIntroUsesTwoTapCopyAndTheLunaIcon() throws {
        let intro = OnboardingIntroCardContentViewController(
            introCopy: .growingLine(stem: "Read", tail: " more."),
            supportingText: "",
            saveSetupMode: .shareSheet)
        intro.loadViewIfNeeded()

        let button = try XCTUnwrap(
            intro.view.descendants(of: UIButton.self).first {
                $0.accessibilityLabel == OnboardingStrings.Intro.shareAction.value()
            })
        XCTAssertNotNil(button.configuration?.image)
        XCTAssertFalse(intro.view.descendants(of: UIButton.self).contains {
            $0.accessibilityLabel == OnboardingStrings.Intro.shortcutAction.value()
        })
    }

    @MainActor
    func testFallbackConversationEndsWithPracticeLinkThenTheRequestedAside() throws {
        let messages = MessagesReplicaViewController(
            urlString: OnboardingDemoPage.lunaPage.sharedURLString,
            saveSetupMode: .shareSheet,
            appName: LunaApp.reader.displayName,
            actionExtensionIcon: nil)
        messages.loadViewIfNeeded()
        messages.updateURL(ShareSetupPractice.amayzonURLString)
        messages.view.frame = CGRect(
            origin: .zero,
            size: AppLaunchGeometry.referenceSize)
        messages.revealStagedConversationImmediately()
        messages.revealSetupMessagesImmediately()
        messages.view.layoutIfNeeded()

        let labels = messages.view.descendants(of: UILabel.self).compactMap(\.text)
        XCTAssertTrue(labels.contains(OnboardingStrings.Messages.shareAnswer.value()))
        XCTAssertTrue(labels.contains(OnboardingStrings.Messages.sharePitch.value()))
        XCTAssertTrue(labels.contains(OnboardingStrings.Messages.shareTryIt.value()))
        XCTAssertTrue(labels.contains(OnboardingStrings.Messages.shareAside.value()))
        XCTAssertEqual(
            labels.filter { $0 == ShareSetupPractice.amayzonURLString }.count,
            2,
            "The incoming link and practice pill must stay on the same current URL")

        let sharePill = try XCTUnwrap(
            messages.view.descendants(of: OnboardingMessagePillButton.self).first {
                $0.accessibilityIdentifier == "onboarding.messages.sharePill"
            })
        sharePill.beginAttentionPulse()
        let shareCorona = try XCTUnwrap(
            sharePill.descendants(of: EclipseCoronaView.self).first,
            "The share link uses the same eclipse corona as the setup pills")
        XCTAssertNotNil(
            shareCorona.layer.animation(
                forKey: OnboardingMessagePillButton.pulseAnimationKey))

        let practice = try XCTUnwrap(
            messages.view.descendants(of: UIView.self).first {
                $0.accessibilityIdentifier == "onboarding.messages.sharePractice"
            })
        let aside = try XCTUnwrap(
            messages.view.descendants(of: UIView.self).first {
                $0.accessibilityIdentifier == "onboarding.messages.shareAside"
            })
        XCTAssertLessThan(
            messages.view.convert(practice.bounds, from: practice).midY,
            messages.view.convert(aside.bounds, from: aside).midY)

        let skip = try XCTUnwrap(
            messages.view.descendants(of: UIView.self).first {
                $0.accessibilityIdentifier
                    == OnboardingStrings.Accessibility.messagesSkipSetup.value()
            })
        XCTAssertEqual(skip.superview?.alpha, 0)
        messages.revealShareSheetSkipMessage()
        XCTAssertEqual(skip.superview?.alpha, 1)
    }

    @MainActor
    func testMockShareSheetStartsWithoutLunaAndOffersTheExactEditRows() throws {
        let sheet = OnboardingMockShareSheetView(
            frame: CGRect(origin: .zero, size: AppLaunchGeometry.referenceSize),
            appName: LunaApp.luna.displayName,
            urlString: ShareSetupPractice.lunaURLString,
            appIcon: OnboardingActionExtensionIcon.image())
        sheet.layoutIfNeeded()

        let visibleFavorites = try XCTUnwrap(sheet.viewWithTag(40))
        XCTAssertEqual(
            visibleFavorites.subviews.compactMap {
                ($0.viewWithTag(3) as? UILabel)?.text
            },
            ["Copy"])

        let editFavorites = try XCTUnwrap(sheet.viewWithTag(201))
        XCTAssertEqual(
            editFavorites.descendants(of: UILabel.self).compactMap(\.text),
            ["Copy"])
        let editOthers = try XCTUnwrap(sheet.viewWithTag(203))
        XCTAssertEqual(
            editOthers.descendants(of: UILabel.self).compactMap(\.text),
            [LunaApp.luna.displayName, "Save to Files", "Add to Reading List"])

        let allLabels = sheet.descendants(of: UILabel.self).compactMap(\.text)
        XCTAssertEqual(allLabels.filter { $0 == "Johnny\nAppleseed" }.count, 1)
        XCTAssertEqual(allLabels.filter { $0 == "Laptop" }.count, 1)
        for title in ["AirDrop", "Messages", "Reminders", "More"] {
            XCTAssertTrue(allLabels.contains(title))
        }
        XCTAssertNotNil(
            UIImage(systemName: "dot.radiowaves.up.forward"),
            "The fallback must not regress to an empty AirDrop tile on iOS 26")
        XCTAssertNotNil(
            OnboardingActionExtensionIcon.image(),
            "The mock must load the host's handmade action-extension icon")
    }

    @MainActor
    func testIntroStagesTheSameRevealAcrossBothLines() throws {
        let intro = OnboardingIntroCardContentViewController(
            introCopy: .twoLines(
                first: "You want to read more.",
                second: "Let’s make that happen."),
            supportingText: OnboardingStrings.Intro.supportingText.value(for: .reader))
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
            $0.accessibilityIdentifier
                == OnboardingStrings.Accessibility.introIconCluster.value()
        })
        XCTAssertTrue(
            intro.view.subviews.compactMap { $0 as? UILabel }.allSatisfy {
                $0.accessibilityIdentifier
                    != OnboardingStrings.Accessibility.introSupportingText.value()
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

    @MainActor
    func testPasteRowShowsWhatWasPastedAndResolvesItsSpinnerInPlace() throws {
        let intro = OnboardingIntroCardContentViewController(
            introCopy: .growingLine(stem: "Read", tail: " more."),
            supportingText: "")
        intro.loadViewIfNeeded()
        intro.view.frame = CGRect(x: 0, y: 0, width: 354, height: 629)
        intro.view.layoutIfNeeded()

        let row = try XCTUnwrap(
            intro.view.descendants(of: OnboardingPasteRow.self).first)
        let field = try XCTUnwrap(
            row.descendants(of: UITextField.self).first)
        let status = row.status
        let control = try XCTUnwrap(
            row.descendants(of: UIPasteControl.self).first)

        // The “or” sits between the shortcut action and the paste row, and is
        // centred on the same column they share.
        let shortcut = try XCTUnwrap(
            intro.view.descendants(of: UIButton.self).first {
                $0.accessibilityLabel
                    == OnboardingStrings.Intro.shortcutAction.value()
            })
        let orLabel = try XCTUnwrap(
            intro.view.descendants(of: UILabel.self).first {
                $0.accessibilityIdentifier
                    == OnboardingStrings.Accessibility.introOr.value()
            })
        XCTAssertEqual(
            orLabel.text, OnboardingStrings.Intro.orSeparator.value())
        XCTAssertEqual(orLabel.textAlignment, .center)
        // The actions still wear the reveal's 0.92 entrance scale here, so read
        // laid-out geometry (unscaled `bounds` about a transform-independent
        // `center`) rather than the presented frame.
        func layoutFrame(_ target: UIView) -> CGRect {
            let size = target.bounds.size
            let center = target.superview
                .map { $0.convert(target.center, to: intro.view) }
                ?? target.center
            return CGRect(
                x: center.x - size.width / 2,
                y: center.y - size.height / 2,
                width: size.width,
                height: size.height)
        }
        let orFrame = layoutFrame(orLabel)
        let shortcutFrame = layoutFrame(shortcut)
        let rowFrame = layoutFrame(row)
        XCTAssertGreaterThan(orFrame.minY, shortcutFrame.maxY)
        XCTAssertLessThan(orFrame.maxY, rowFrame.minY)
        XCTAssertEqual(orFrame.midX, intro.view.bounds.midX, accuracy: 0.5)
        XCTAssertEqual(
            rowFrame.maxY,
            shortcutFrame.maxY
                + OnboardingIntroActionMetrics.orSpacing * 2
                + OnboardingIntroActionMetrics.orHeight
                + OnboardingIntroActionMetrics.pasteRowHeight,
            accuracy: 0.5)

        // The row is shorter than the setup buttons and reaches wider than the
        // content inset they keep, so the field gets the width.
        XCTAssertEqual(
            rowFrame.height,
            OnboardingIntroActionMetrics.pasteRowHeight,
            accuracy: 0.5)
        XCTAssertEqual(
            rowFrame.width,
            shortcutFrame.width
                + OnboardingIntroActionMetrics.pasteRowOutset * 2,
            accuracy: 0.5)
        XCTAssertEqual(rowFrame.midX, intro.view.bounds.midX, accuracy: 0.5)
        // Widened row, narrower control, tighter gap — all of it the field's,
        // which runs out to the row's own trailing edge.
        XCTAssertEqual(field.frame.maxX, row.bounds.width, accuracy: 0.5)

        // The field is beside the control, and starts on its placeholder.
        XCTAssertGreaterThanOrEqual(field.frame.minX, control.frame.maxX)
        XCTAssertEqual(
            field.placeholder, OnboardingStrings.Intro.paste.value())
        XCTAssertTrue(field.text?.isEmpty ?? true)
        XCTAssertEqual(field.leftViewMode, .never)
        XCTAssertEqual(status.symbol, .none)

        // A paste shows its text immediately; the spinner prefixes it while
        // Luna works.
        intro.didPaste(" https://example.com/story ")
        XCTAssertEqual(field.text, "https://example.com/story")
        intro.setPasteLoading()
        XCTAssertEqual(field.leftViewMode, .always)
        XCTAssertTrue(status.isSpinning)
        XCTAssertEqual(field.text, "https://example.com/story")
        XCTAssertEqual(
            field.textRect(forBounds: field.bounds).minX,
            field.leftViewRect(forBounds: field.bounds).maxX + 8,
            accuracy: 0.5,
            "The spinner is a prefix to the text, not an overlay on it")

        // A failure resolves the same slot into a cross and states why.
        let reason = OnboardingStrings.Intro.articleURLsOnly.value()
        intro.setPasteError(reason)
        XCTAssertEqual(field.text, reason)
        XCTAssertEqual(field.textColor, LunaColors.errorAccent)
        XCTAssertEqual(status.symbol, .failure)
        XCTAssertNotNil(status.markImage)
        // The spinner keeps turning under the mark springing in over it, and
        // leaves once that crossfade is done.
        let spinnerDeadline = Date(timeIntervalSinceNow: 3)
        while status.isSpinning, Date() < spinnerDeadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        XCTAssertFalse(status.isSpinning)

        // A success resolves it into a checkmark, and only then hands over.
        var handedOver = false
        intro.didPaste("https://example.com/story")
        intro.setPasteLoading()
        intro.setPasteSucceeded { handedOver = true }
        XCTAssertEqual(status.symbol, .success)
        XCTAssertFalse(handedOver, "The checkmark is shown before the deck")
        let deadline = Date(timeIntervalSinceNow: 5)
        while !handedOver, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        XCTAssertTrue(handedOver)
    }

    @MainActor
    func testGrowingIntroCentresTheFinishedSentenceAndNeverMovesItsStem() throws {
        let intro = OnboardingIntroCardContentViewController(
            introCopy: OnboardingStrings.introCopy(for: .reader),
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
        let stemText = OnboardingStrings.Intro.headlineStem.value(for: .reader)
        let periodText = OnboardingStrings.Intro.growingLinePeriod.value()
        let tailText = OnboardingStrings.Intro.headlineTail.value(for: .reader)
        XCTAssertEqual(
            origin + width(stemText + tailText) / 2, growing.bounds.midX, accuracy: 1,
            "The finished sentence is what is centred")
        XCTAssertLessThan(
            origin + width(stemText + periodText) / 2, growing.bounds.midX - 20,
            "The first beat therefore lands left of centre, which is the point")

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
        XCTAssertEqual(growing.accessibilityLabel, stemText + periodText)

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
        XCTAssertEqual(growing.accessibilityLabel, stemText + tailText)
        XCTAssertTrue(growing.isAccessibilityElement)
        XCTAssertFalse(stem.isAccessibilityElement)
    }

    @MainActor
    func testGrowingIntroStartsThePeriodsExitWithTheTailsArrival() {
        let font = UIFont.systemFont(ofSize: 25, weight: .semibold)
        let growing = MoonRevealGrowingLineView(
            stem: OnboardingStrings.Intro.headlineStem.value(for: .reader),
            tail: OnboardingStrings.Intro.headlineTail.value(for: .reader),
            font: font)

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
            OnboardingStrings.Intro.safariAction.value(),
            OnboardingStrings.Intro.shortcutAction.value(),
        ] {
            let button = try XCTUnwrap(
                intro.view.descendants(of: UIButton.self).first {
                    $0.accessibilityLabel == label
                })
            XCTAssertFalse(button.isEnabled)
            XCTAssertEqual(
                button.accessibilityValue,
                OnboardingStrings.Intro.completed.value())
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
                $0.accessibilityIdentifier
                    == OnboardingStrings.Accessibility.messagesSenderName.value()
            })
        let latestURL = try XCTUnwrap(
            messages.view.descendants(of: UILabel.self).first {
                $0.accessibilityIdentifier
                    == OnboardingStrings.Accessibility.messagesLatestURL.value()
            })
        let labels = messages.view.descendants(of: UILabel.self).compactMap {
            $0.text
        }
        let bubbles = messages.view.descendants(of: UIView.self).compactMap {
            $0.accessibilityIdentifier
        }

        XCTAssertEqual(sender.text, OnboardingStrings.Messages.senderName.value())
        XCTAssertEqual(latestURL.text, urlString)
        // The friend opens the thread, asks, hears the Action Button is dead,
        // and offers what theirs does — then the link.
        XCTAssertTrue(labels.contains(OnboardingStrings.Messages.greeting.value()))
        XCTAssertTrue(labels.contains(OnboardingStrings.Messages.question.value()))
        XCTAssertTrue(labels.contains(OnboardingStrings.Messages.answer.value()))
        XCTAssertTrue(labels.contains(OnboardingStrings.Messages.pitch.value()))
        XCTAssertTrue(
            bubbles.contains(OnboardingStrings.Accessibility.messagesGreeting.value()))
        XCTAssertTrue(
            bubbles.contains(OnboardingStrings.Accessibility.messagesQuestion.value()))
        XCTAssertTrue(
            bubbles.contains(OnboardingStrings.Accessibility.messagesAnswer.value()))
        XCTAssertTrue(
            bubbles.contains(OnboardingStrings.Accessibility.messagesPitch.value()))
        XCTAssertGreaterThan(
            messages.actionButtonReplayDelay,
            OnboardingDemoLoopTiming.sourceHoldDuration)
        // One gap per staged arrival. Their exact lengths are a tuning knob; only floor them,
        // so every bubble still lands as its own beat.
        XCTAssertEqual(
            OnboardingMessagesReplicaTiming.stagedMessageDelays.count, 5)
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
    func testPreviouslyConfiguredSiblingGetsTheFacetedShortcutConversation() throws {
        let messages = MessagesReplicaViewController(
            urlString: OnboardingDemoPage.instaTok.sharedURLString,
            app: .downloader,
            appName: LunaApp.downloader.displayName,
            previouslyConfiguredApp: .reader,
            actionExtensionIcon: nil)
        let window = UIWindow(
            frame: CGRect(origin: .zero, size: AppLaunchGeometry.referenceSize))
        window.rootViewController = messages
        window.makeKeyAndVisible()
        messages.view.layoutIfNeeded()
        defer { window.isHidden = true }

        let labels = messages.view.descendants(of: UILabel.self).compactMap(\.text)
        let sentences = messages.view.descendants(of: UITextView.self)
            .compactMap(\.text)
        XCTAssertTrue(messages.usesPreviousSetupConversation)
        XCTAssertTrue(labels.contains(OnboardingStrings.Messages.greeting.value()))
        XCTAssertTrue(labels.contains(
            OnboardingStrings.Messages.previousSetupQuestion(
                appName: LunaApp.reader.displayName)))
        XCTAssertTrue(labels.contains(OnboardingStrings.Messages.previousSetupAnswer.value()))
        XCTAssertTrue(labels.contains(OnboardingStrings.Messages.keepCurrentAppQuestion.value()))
        XCTAssertTrue(sentences.contains {
            $0.hasPrefix(OnboardingStrings.Messages.facetedCoreOfferPrefix.value())
        })
        XCTAssertTrue(sentences.contains {
            $0.hasPrefix(OnboardingStrings.Messages.chooseCurrentApp.value())
        })
        XCTAssertFalse(labels.contains(OnboardingStrings.Messages.question.value()))

        let corePill = try XCTUnwrap(
            messages.view.descendants(of: OnboardingMessagePillButton.self).first {
                $0.accessibilityIdentifier == "onboarding.messages.coreAppPill"
            })
        XCTAssertTrue(labels.contains(LunaApp.luna.displayName))
        var openedStore = false
        messages.onOpenLunaAppStore = { openedStore = true }
        corePill.sendActions(for: .touchUpInside)
        XCTAssertTrue(openedStore)

        messages.revealStagedConversationImmediately()
        XCTAssertTrue(messages.isShowingSetupMessages)
        let skipBubble = try XCTUnwrap(messages.view.viewWithAccessibilityIdentifier(
            OnboardingStrings.Accessibility.messagesSkipSetup.value()))
        let skipRow = try XCTUnwrap(skipBubble.superview)
        XCTAssertEqual(skipRow.alpha, 0)

        let shortcutPill = try XCTUnwrap(
            messages.view.descendants(of: OnboardingMessagePillButton.self).first {
                $0.accessibilityIdentifier
                    == OnboardingStrings.Accessibility.messagesShortcutPill.value()
            })
        var installed = false
        messages.onInstallShortcut = { installed = true }
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(true) }
        shortcutPill.sendActions(for: .touchUpInside)
        XCTAssertTrue(installed)
        XCTAssertEqual(skipRow.alpha, 1, "Skip arrives only once install is pressed")

        let settingsBubble = try XCTUnwrap(messages.view.viewWithAccessibilityIdentifier(
            OnboardingStrings.Accessibility.messagesSettingsSetup.value()))
        let settingsRow = try XCTUnwrap(settingsBubble.superview)
        XCTAssertTrue(settingsRow.isHidden)
        messages.revealSettingsSetupMessage()
        XCTAssertFalse(settingsRow.isHidden)
        XCTAssertEqual(settingsRow.alpha, 1)
        messages.view.layoutIfNeeded()
        XCTAssertGreaterThan(
            settingsRow.frame.minY,
            skipRow.frame.minY,
            "The returning-user Settings message arrives after the revealed Skip row")
    }

    @MainActor
    func testCentralAppPreviousSetupConversationDropsTheObjectionAndShortcutProse() {
        let messages = MessagesReplicaViewController(
            urlString: OnboardingDemoPage.lunaPage.sharedURLString,
            app: .luna,
            appName: LunaApp.luna.displayName,
            previouslyConfiguredApp: .priceTracker,
            actionExtensionIcon: nil)
        messages.loadViewIfNeeded()

        let labels = messages.view.descendants(of: UILabel.self).compactMap(\.text)
        let sentences = messages.view.descendants(of: UITextView.self)
            .compactMap(\.text)
        XCTAssertTrue(labels.contains(
            OnboardingStrings.Messages.previousSetupQuestion(
                appName: LunaApp.priceTracker.displayName)))
        XCTAssertTrue(labels.contains(OnboardingStrings.Messages.centralCoreOffer.value()))
        XCTAssertFalse(labels.contains(OnboardingStrings.Messages.keepCurrentAppQuestion.value()))
        XCTAssertFalse(sentences.contains {
            $0.hasPrefix(OnboardingStrings.Messages.chooseCurrentApp.value())
        })
        XCTAssertFalse(messages.view.descendants(of: OnboardingMessagePillButton.self).contains {
            $0.accessibilityIdentifier == "onboarding.messages.coreAppPill"
        })
        XCTAssertTrue(labels.contains(OnboardingStrings.Messages.shortcutPillTitle.value()))
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
        XCTAssertTrue(
            bubbles.contains(OnboardingStrings.Accessibility.messagesShortcutSetup.value()))
        XCTAssertTrue(
            bubbles.contains(OnboardingStrings.Accessibility.messagesSettingsSetup.value()))
        XCTAssertTrue(
            bubbles.contains(OnboardingStrings.Accessibility.messagesSkipSetup.value()))
        // Each pill flows INLINE with its sentence: the words live in a text
        // view whose attachment reserves the pill's spot in the line flow.
        let sentences = messages.view.descendants(of: UITextView.self)
            .compactMap(\.text)
        XCTAssertTrue(sentences.contains {
            $0.hasPrefix(OnboardingStrings.Messages.shortcutSetup.value())
        })
        XCTAssertTrue(sentences.contains {
            $0.hasPrefix(OnboardingStrings.Messages.settingsSetup.value())
        })
        XCTAssertTrue(
            sentences.contains { $0.hasPrefix(OnboardingStrings.Messages.skipSetup.value()) })
        let labels = messages.view.descendants(of: UILabel.self).compactMap(\.text)
        XCTAssertTrue(labels.contains(OnboardingStrings.Messages.shortcutPillTitle.value()))
        XCTAssertTrue(labels.contains(OnboardingStrings.Messages.settingsPillTitle.value()))
        XCTAssertTrue(labels.contains(OnboardingStrings.Messages.skipPillTitle.value()))

        let shortcutPill = try XCTUnwrap(
            messages.view.descendants(of: OnboardingMessagePillButton.self).first {
                $0.accessibilityIdentifier
                    == OnboardingStrings.Accessibility.messagesShortcutPill.value()
            })
        let settingsPill = try XCTUnwrap(
            messages.view.descendants(of: OnboardingMessagePillButton.self).first {
                $0.accessibilityIdentifier
                    == OnboardingStrings.Accessibility.messagesSettingsPill.value()
            })
        let skipPill = try XCTUnwrap(
            messages.view.descendants(of: OnboardingMessagePillButton.self).first {
                $0.accessibilityIdentifier
                    == OnboardingStrings.Accessibility.messagesSkipPill.value()
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
        let shortcut = try bubble(
            OnboardingStrings.Accessibility.messagesShortcutSetup.value())
        let settings = try bubble(
            OnboardingStrings.Accessibility.messagesSettingsSetup.value())
        let skip = try bubble(OnboardingStrings.Accessibility.messagesSkipSetup.value())

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
                $0.accessibilityLabel == OnboardingStrings.Intro.safariAction.value()
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

    /// A paste is answered from the intro card: no demonstration ever ran, so
    /// the handoff must leave the preloaded replicas where preloading put them
    /// — hidden — and hand the screen to its own card eclipse. Pausing demo
    /// playback used to re-stage the Safari replica full screen (`.fullScreen`
    /// is the resting default) and blank the carousel, flashing the mock
    /// browser over the eclipse it was hiding.
    @MainActor
    func testPasteHandoffNeverRevealsTheSourceReplicasOrBlanksTheDeck() throws {
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
        UIView.setAnimationsEnabled(false)
        defer {
            UIView.setAnimationsEnabled(true)
            window.isHidden = true
        }

        onboarding.firstIntroLineDidReveal()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        let safari = try XCTUnwrap(onboarding.children.compactMap {
            $0 as? SafariReplicaViewController
        }.first)
        let messages = try XCTUnwrap(onboarding.children.compactMap {
            $0 as? MessagesReplicaViewController
        }.first)
        let carousel = try XCTUnwrap(onboarding.children.compactMap {
            $0 as? CardCarouselViewController
        }.first)
        XCTAssertTrue(safari.view.isHidden, "Preloading mounts Safari hidden")

        onboarding.completeOnboardingWithRealSaveForTesting(animated: true)

        XCTAssertTrue(
            safari.view.isHidden,
            "The paste handoff must never show the mock browser")
        XCTAssertTrue(
            messages.view.isHidden,
            "The paste handoff must never show the mock conversation")
        XCTAssertEqual(
            carousel.view.alpha, 1, accuracy: 0.001,
            "The deck stays visible — the card eclipse plays on it")
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
        XCTAssertTrue(revealCopy.contains {
            Self.isValidExplainerPrefix($0, for: .reader)
        })
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
                    == OnboardingStrings.Accessibility.safariStep(index)
            })
        }
        for (index, step) in steps.enumerated() {
            XCTAssertEqual(stepRows[index].accessibilityLabel, step.text)
        }
        // Safari lists each app's extension under that app's own name (each
        // target gives its copy of the appex its own CFBundleDisplayName), so
        // the step names the RUNNING app — not the central app, and not a
        // generic "the extension".
        XCTAssertEqual(
            steps[2].text,
            OnboardingStrings.Safari.steps(appName: appName)[2].text)
        XCTAssertEqual(appName, LunaApp.reader.displayName)
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
            $0.accessibilityIdentifier
                == OnboardingStrings.Accessibility.safariExplainer.value()
        })
        let headline = try XCTUnwrap(revealLines.first {
            $0.accessibilityIdentifier
                == OnboardingStrings.Accessibility.safariHeadline.value()
        })
        XCTAssertGreaterThan(stepRows[0].frame.minY, explainer.frame.maxY)
        XCTAssertGreaterThan(actionsFrame.minY, stepRows[2].frame.maxY)
        // The page is pinned at BOTH ends now: the header sits exactly on the
        // top inset and the actions exactly on the chrome reserve, so a tall
        // screen's slack lands between the prose and the steps — where the
        // chunk granularity needs it. (It used to hang from the actions alone,
        // collecting every spare point above the header.)
        XCTAssertEqual(
            headline.frame.minY,
            OnboardingSafariPageView.minimumTopInset,
            accuracy: 0.5)
        XCTAssertTrue(
            page.descendants(of: CardSurfaceView.self).isEmpty,
            "The setup card is gone: the actions are the page's own content")
        let scroll = try XCTUnwrap(page.descendants(of: UIScrollView.self).first)
        XCTAssertFalse(scroll.isScrollEnabled, "The page never scrolls")
        XCTAssertEqual(scroll.contentOffset, .zero)

        // Every fake obstruction is mounted, fully visible from the first
        // frame, and inert.
        let clutter = try XCTUnwrap(page.descendants(of: UIView.self).first {
            $0.accessibilityIdentifier
                == OnboardingStrings.Accessibility.safariClutter.value()
        })
        XCTAssertFalse(clutter.isUserInteractionEnabled)
        XCTAssertTrue(clutter.subviews.allSatisfy { $0.alpha == 1 })
        XCTAssertEqual(
            clutter.subviews.filter { $0 is OnboardingAdBannerView }.count, 4)
        XCTAssertTrue(labels.contains(OnboardingStrings.Safari.newsletterTitle.value()))
        XCTAssertTrue(labels.contains(OnboardingStrings.Safari.newsletterSubtitle.value()))
        XCTAssertTrue(labels.contains(OnboardingStrings.Safari.newsletterEmail.value()))
        XCTAssertTrue(labels.contains(OnboardingStrings.Safari.newsletterSubmit.value()))
        XCTAssertTrue(labels.contains(OnboardingStrings.Safari.subscriptionTitle.value()))
        XCTAssertTrue(labels.contains(OnboardingStrings.Safari.subscriptionBody.value()))
        XCTAssertTrue(labels.contains(OnboardingStrings.Safari.subscriptionSignIn.value()))

        // The buried page registers before the Manage Extensions sheet — the
        // pass's first and only step — slides up, and the sheet is readable
        // before its switch moves.
        XCTAssertGreaterThanOrEqual(
            OnboardingExtensionEnableTiming.pageHoldDuration, 0.5)
        XCTAssertGreaterThanOrEqual(
            OnboardingExtensionEnableTiming.toggleDelay, 0.25)
    }

    /// Every prefix the page may print is a CUMULATIVE join of whole chunks —
    /// never a partial one, and never a later chunk without its predecessors.
    static func isValidExplainerPrefix(_ text: String, for app: LunaApp) -> Bool {
        let chunks = OnboardingSafariExtensionCopy.explainerChunks(for: app)
        return (1...chunks.count).contains {
            OnboardingSafariExtensionCopy.explainerPrefix($0, for: app) == text
        }
    }

    /// How many chunks a rendered prose string is.
    static func explainerPrefixLength(
        _ text: String, for app: LunaApp
    ) -> Int? {
        let chunks = OnboardingSafariExtensionCopy.explainerChunks(for: app)
        return (1...chunks.count).first {
            OnboardingSafariExtensionCopy.explainerPrefix($0, for: app) == text
        }
    }

    @MainActor
    private func safariExplainerLine(
        of page: OnboardingSafariPageView
    ) throws -> MoonRevealLineView {
        try XCTUnwrap(page.descendants(of: MoonRevealLineView.self).first {
            $0.accessibilityIdentifier
                == OnboardingStrings.Accessibility.safariExplainer.value()
        })
    }

    /// The one-screen budget is real: on the shortest phone Luna ships to, the
    /// whole explainer — header, the FIRST prose chunk, three steps and both
    /// actions — still fits above the browser chrome without the prose being
    /// cut. Chunk one is the copy that has to survive that screen; the later
    /// chunks are depth only a taller one buys.
    @MainActor
    func testSafariPageFitsTheShortestPhoneWithoutTruncatingItsProse() throws {
        for app in LunaApp.allCases {
            let page = OnboardingSafariPageView(
                configuration: .configuration(for: app))
            page.frame = CGRect(x: 0, y: 0, width: 375, height: 667)
            page.layoutIfNeeded()

            let explainer = try safariExplainerLine(of: page)
            let firstChunk = OnboardingSafariExtensionCopy
                .explainerPrefix(1, for: app)
            let naturalHeight = OnboardingSafariPageView.proseHeight(
                of: firstChunk, width: explainer.frame.width)
            XCTAssertGreaterThanOrEqual(
                explainer.frame.height,
                naturalHeight,
                "Shorten \(app)'s first explainer chunk: it no longer fits "
                    + "above the steps on a 375×667 screen")
            let header = try XCTUnwrap(
                page.descendants(of: MoonRevealLineView.self).first {
                    $0.accessibilityIdentifier
                        == OnboardingStrings.Accessibility.safariHeadline.value()
                })
            XCTAssertGreaterThan(explainer.frame.minY, header.frame.maxY)
            XCTAssertTrue(Self.isValidExplainerPrefix(
                try XCTUnwrap(explainer.accessibilityLabel), for: app))
        }
    }

    /// THE FURNITURE IS FIXED AND THE PROSE IS THE VARIABLE. At every size Luna
    /// ships to — the shortest phone, three current phones, both iPads — the
    /// header starts at the page's top inset, the actions end exactly on the
    /// browser chrome's reserve, every step row and both buttons are present,
    /// and the prose is a whole-chunk prefix that fits the room left between
    /// them. A bigger screen never shows LESS than a smaller one.
    @MainActor
    func testSafariPageGrowsItsProseByWholeChunksAcrossEveryScreen() throws {
        let sizes: [CGSize] = [
            CGSize(width: 375, height: 667),
            CGSize(width: 393, height: 852),
            CGSize(width: 430, height: 932),
            CGSize(width: 744, height: 1133),
            CGSize(width: 1024, height: 1366),
        ]
        for app in LunaApp.allCases {
            var previousLength = 0
            var lengths: [Int] = []
            for size in sizes {
                let page = OnboardingSafariPageView(
                    configuration: .configuration(for: app))
                page.frame = CGRect(origin: .zero, size: size)
                page.layoutIfNeeded()

                // (1) The header is pinned to the top inset.
                let icon = try XCTUnwrap(page.descendants(of: UIView.self).first {
                    $0.accessibilityIdentifier
                        == OnboardingStrings.Accessibility.safariAppIcon.value()
                })
                let headline = try XCTUnwrap(
                    page.descendants(of: MoonRevealLineView.self).first {
                        $0.accessibilityIdentifier
                            == OnboardingStrings.Accessibility.safariHeadline
                                .value()
                    })
                XCTAssertEqual(
                    headline.frame.minY,
                    OnboardingSafariPageView.minimumTopInset,
                    accuracy: 0.5,
                    "\(app) at \(size): the header must start at the top inset")
                XCTAssertGreaterThanOrEqual(
                    page.convert(icon.bounds, from: icon).minY,
                    OnboardingSafariPageView.minimumTopInset - 0.5)

                // (2) The actions end exactly on the chrome reserve.
                let actions = try XCTUnwrap(
                    page.descendants(of: OnboardingSafariActionsView.self).first)
                let actionsFrame = page.convert(actions.bounds, from: actions)
                XCTAssertEqual(
                    actionsFrame.maxY,
                    size.height - OnboardingSafariPageView.chromeReserve,
                    accuracy: 0.5,
                    "\(app) at \(size): the skip button must sit on the "
                        + "browser chrome")

                // (6) Iconography, step rows and both buttons are never part of
                // the prefix.
                let stepRows = try (0..<3).map { index in
                    try XCTUnwrap(page.descendants(of: UIView.self).first {
                        $0.accessibilityIdentifier
                            == OnboardingStrings.Accessibility.safariStep(index)
                    })
                }
                XCTAssertEqual(stepRows.count, 3)
                XCTAssertNotNil(actions.activateButton.superview)
                XCTAssertNotNil(actions.skipButton.superview)

                // (3) + (4) The prose is a whole-chunk prefix that fits.
                let explainer = try safariExplainerLine(of: page)
                let text = try XCTUnwrap(explainer.accessibilityLabel)
                let length = try XCTUnwrap(
                    Self.explainerPrefixLength(text, for: app),
                    "\(app) at \(size): “\(text)” is not a chunk-boundary "
                        + "prefix")
                let measured = OnboardingSafariPageView.proseHeight(
                    of: text, width: explainer.frame.width)
                let stepsHeading = try XCTUnwrap(
                    page.descendants(of: MoonRevealLineView.self).first {
                        $0.accessibilityIdentifier
                            == OnboardingStrings.Accessibility
                                .safariStepsHeading.value()
                    })
                XCTAssertGreaterThanOrEqual(
                    explainer.frame.height, measured,
                    "\(app) at \(size): the chosen prefix is being truncated")
                XCTAssertLessThanOrEqual(
                    explainer.frame.maxY, stepsHeading.frame.minY,
                    "\(app) at \(size): the prose overruns its region")
                XCTAssertGreaterThan(stepRows[0].frame.minY, explainer.frame.maxY)

                // (5) Monotonic: a larger screen never shows a shorter prefix.
                XCTAssertGreaterThanOrEqual(
                    length, previousLength,
                    "\(app) at \(size): a bigger screen showed less prose")
                previousLength = length
                lengths.append(length)
            }
            // The fitting has to actually DO something: the shortest phone
            // holds less than the whole list, and the largest iPad holds it all.
            let chunkCount = OnboardingSafariExtensionCopy
                .explainerChunks(for: app).count
            XCTAssertLessThan(
                try XCTUnwrap(lengths.first), chunkCount,
                "\(app): 375×667 must not already fit every chunk — there is "
                    + "no depth left for a taller screen to add")
            XCTAssertEqual(
                lengths.last, chunkCount,
                "\(app): a 13-inch iPad has room for the whole explainer")
        }
    }

    /// Each app's page carries its OWN copy, and every chunk list opens with a
    /// sentence that stands alone.
    @MainActor
    func testSafariExplainerCopyIsPerAppAndChunked() throws {
        var firstChunks: Set<String> = []
        for app in LunaApp.allCases {
            let chunks = OnboardingSafariExtensionCopy.explainerChunks(for: app)
            XCTAssertTrue(
                (3...6).contains(chunks.count),
                "\(app): 3–6 chunks is the shape that fits every screen")
            for chunk in chunks {
                XCTAssertFalse(chunk.isEmpty)
                XCTAssertTrue(
                    chunk.hasSuffix(".") || chunk.hasSuffix("?"),
                    "\(app): “\(chunk)” must close its own sub-topic")
                XCTAssertEqual(
                    chunk.trimmingCharacters(in: .whitespacesAndNewlines),
                    chunk,
                    "chunks are joined with a single space, so they carry no "
                        + "edge whitespace of their own")
            }
            firstChunks.insert(chunks[0])
            XCTAssertEqual(
                OnboardingSafariExtensionCopy.explainerPrefix(2, for: app),
                chunks[0] + OnboardingSafariExtensionCopy.chunkSeparator
                    + chunks[1])
        }
        // The Downloader and the Price Tracker lead with their own kind, not
        // with the Reader's sentence.
        XCTAssertEqual(firstChunks.count, LunaApp.allCases.count)
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
            $0.accessibilityIdentifier
                == OnboardingStrings.Accessibility.safariClutter.value()
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
            of: UIButton.self).first {
                $0.accessibilityLabel == OnboardingStrings.Safari.skip.value()
            })
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
                $0.accessibilityIdentifier
                    == OnboardingStrings.Accessibility.safariExplainer.value()
            })
        XCTAssertTrue(Self.isValidExplainerPrefix(
            try XCTUnwrap(explainer.accessibilityLabel), for: .reader))
        XCTAssertTrue(explainer.isFullyRevealed)
        let clutter = try XCTUnwrap(page.descendants(of: UIView.self).first {
            $0.accessibilityIdentifier
                == OnboardingStrings.Accessibility.safariClutter.value()
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

    /// The Safari button asks for its tap with the SAME breath the Messages
    /// pills use — one rate and one curve out of `OnboardingAttentionPulse`,
    /// which is the evidence that neither site rolled its own — and its corona
    /// breathes with it rather than beside it.
    @MainActor
    func testTheSafariButtonAndItsCoronaBreatheForTheTapTogether() throws {
        try XCTSkipIf(
            UIAccessibility.isReduceMotionEnabled,
            "The breath is motion; without it the corona simply sits lit")
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
        page.cleanUpClutter { finished.fulfill() }
        wait(for: [finished], timeout: 15)

        let actions = try XCTUnwrap(
            page.descendants(of: OnboardingSafariActionsView.self).first)
        let corona = try XCTUnwrap(
            page.descendants(of: EclipseCoronaView.self).first)
        let key = OnboardingStrings.AnimationKeys.attentionPulse.value()
        let scaleKey = OnboardingStrings.AnimationKeys.attentionPulseScale.value()

        // The breath is handed the button once the corona's bloom lands. Only
        // the state survives the wait: a test host spends most of a run loop
        // spin unfocused, and CoreAnimation drops animations off those layers.
        let deadline = Date(timeIntervalSinceNow: 4)
        while Date() < deadline, !page.isPulsingActionsForTesting {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        XCTAssertTrue(
            page.isPulsingActionsForTesting,
            "The clean page must start asking for the Safari tap")
        // Lit, not parked at the trough: the breath only ever rides under full.
        XCTAssertEqual(corona.alpha, 1, accuracy: 0.001)

        var didActivate = false
        page.onActivateSafari = { didActivate = true }
        actions.activateButton.sendActions(for: .touchUpInside)
        XCTAssertTrue(didActivate)
        XCTAssertFalse(page.isPulsingActionsForTesting)
        XCTAssertNil(
            actions.activateButton.layer.animation(forKey: key),
            "Answering the button must end its plea")
        XCTAssertNil(corona.layer.animation(forKey: key))
        XCTAssertEqual(corona.alpha, 1, accuracy: 0.001)

        // Coming back from Safari without the extension re-asks — and this is
        // the one moment both layers can be read: the animations are still on
        // them, in the same run loop turn that added them.
        page.reactivateActions()
        XCTAssertTrue(page.isPulsingActionsForTesting)
        let swell = try XCTUnwrap(
            actions.activateButton.layer.animation(forKey: key)
                as? CAKeyframeAnimation,
            "The button wears the pills' own pulse, not one of its own")
        XCTAssertEqual(swell.duration, OnboardingAttentionPulse.cycle)
        XCTAssertEqual(
            swell.values as? [CGFloat],
            OnboardingAttentionPulse.scale().values as? [CGFloat],
            "One breath, built in one place")
        XCTAssertNotNil(
            corona.layer.animation(forKey: scaleKey),
            "The corona must swell with the button, not sit still behind it")
        let light = try XCTUnwrap(
            corona.layer.animation(forKey: key) as? CAKeyframeAnimation)
        XCTAssertEqual(
            light.values?.first as? CGFloat,
            OnboardingAttentionPulse.litCoronaTroughAlpha,
            "An already-burning corona breathes below full, never up from dark")
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

        for label in [
            OnboardingStrings.Safari.activate.value(),
            OnboardingStrings.Safari.skip.value(),
        ] {
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

    /// A skipped lesson can be entered again from the intro, so the page has to
    /// go back to its first frame: buried under every obstruction, actions
    /// inert, corona dark — never the finished page it was left on, whose
    /// buttons the departing tap had already disabled.
    @MainActor
    func testRestoringTheBuriedPageRewindsAFinishedWipe() throws {
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
        let clutter = try XCTUnwrap(page.descendants(of: UIView.self).first {
            $0.accessibilityIdentifier
                == OnboardingStrings.Accessibility.safariClutter.value()
        })
        let actions = try XCTUnwrap(
            page.descendants(of: OnboardingSafariActionsView.self).first)
        let corona = try XCTUnwrap(
            page.descendants(of: EclipseCoronaView.self).first)

        let cleaned = expectation(description: "cleanup")
        page.cleanUpClutter { cleaned.fulfill() }
        wait(for: [cleaned], timeout: 15)
        XCTAssertTrue(clutter.subviews.allSatisfy(\.isHidden))
        XCTAssertTrue(actions.skipButton.isUserInteractionEnabled)

        page.restoreBuriedPage()
        page.layoutIfNeeded()
        XCTAssertTrue(
            clutter.subviews.allSatisfy { !$0.isHidden && $0.alpha == 1 },
            "Every obstruction is back over the page")
        XCTAssertTrue(
            page.subviews.allSatisfy {
                $0 is UIScrollView || $0 === clutter
            },
            "No shatter tile from the finished wipe is left on the page")
        XCTAssertFalse(actions.activateButton.isUserInteractionEnabled)
        XCTAssertFalse(actions.skipButton.isUserInteractionEnabled)
        XCTAssertEqual(corona.alpha, 0, accuracy: 0.001)

        // And the whole sweep plays again, ending on live actions.
        let replayed = expectation(description: "replayed cleanup")
        page.cleanUpClutter { replayed.fulfill() }
        wait(for: [replayed], timeout: 15)
        XCTAssertTrue(clutter.subviews.allSatisfy(\.isHidden))
        XCTAssertTrue(actions.activateButton.isUserInteractionEnabled)
        XCTAssertTrue(actions.skipButton.isUserInteractionEnabled)
        XCTAssertEqual(corona.alpha, 1, accuracy: 0.001)
    }

    /// Skip out of the Safari lesson, then walk back into it from the intro.
    /// It used to land on the finished page with both buttons dead — nothing
    /// left to run, and no way back.
    @MainActor
    func testTheSafariLessonReplaysWholeWhenEnteredAgainAfterASkip() throws {
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

        func button(_ label: String) -> UIButton? {
            onboarding.view.descendants(of: UIButton.self).first {
                $0.accessibilityLabel == label
            }
        }
        func isHittable(_ label: String) -> Bool {
            guard let action = button(label) else { return false }
            let point = window.convert(
                CGPoint(x: action.bounds.midX, y: action.bounds.midY),
                from: action)
            let hit = window.hitTest(point, with: nil)
            return hit === action || hit?.isDescendant(of: action) == true
        }
        /// Rides the real staged sequence — buried page, Manage Extensions
        /// sheet, toggle, wipe — until the page's own actions come alive.
        func waitForLiveActions() {
            let deadline = Date(timeIntervalSinceNow: 25)
            while Date() < deadline {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
                if isHittable(OnboardingStrings.Safari.activate.value()),
                   isHittable(OnboardingStrings.Safari.skip.value()) { return }
            }
        }
        func waitForIntro() {
            let deadline = Date(timeIntervalSinceNow: 15)
            while Date() < deadline {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
                if onboarding.view.descendants(of: UIPasteControl.self)
                    .first?.isHidden == false
                {
                    return
                }
            }
        }

        try XCTUnwrap(button(OnboardingStrings.Intro.safariAction.value()))
            .sendActions(for: .touchUpInside)
        waitForLiveActions()
        XCTAssertTrue(
            isHittable(OnboardingStrings.Safari.skip.value()),
            "First entry never reached its actions")
        try XCTUnwrap(button(OnboardingStrings.Safari.skip.value()))
            .sendActions(for: .touchUpInside)
        waitForIntro()

        // Back in. The page must be buried again from this entry's very first
        // frame — the app-switcher hop snapshots it immediately.
        let introSafari = try XCTUnwrap(
            button(OnboardingStrings.Intro.safariAction.value()))
        XCTAssertTrue(introSafari.isEnabled)
        introSafari.sendActions(for: .touchUpInside)
        let page = try XCTUnwrap(onboarding.view
            .descendants(of: OnboardingSafariPageView.self).first)
        let clutter = try XCTUnwrap(page.descendants(of: UIView.self).first {
            $0.accessibilityIdentifier
                == OnboardingStrings.Accessibility.safariClutter.value()
        })
        XCTAssertTrue(
            clutter.subviews.allSatisfy { !$0.isHidden },
            "The second entry starts on the buried page, not the finished one")
        XCTAssertFalse(
            isHittable(OnboardingStrings.Safari.skip.value()),
            "Buried actions stay inert")

        // …and the whole demonstration runs again, leaving both actions live.
        waitForLiveActions()
        XCTAssertTrue(clutter.subviews.allSatisfy(\.isHidden))
        XCTAssertTrue(isHittable(OnboardingStrings.Safari.activate.value()))
        XCTAssertTrue(isHittable(OnboardingStrings.Safari.skip.value()))

        // The second skip still works, and still lands on the intro.
        try XCTUnwrap(button(OnboardingStrings.Safari.skip.value()))
            .sendActions(for: .touchUpInside)
        waitForIntro()
        let returned = try XCTUnwrap(
            button(OnboardingStrings.Intro.safariAction.value()))
        XCTAssertTrue(returned.isEnabled)
        XCTAssertNil(returned.accessibilityValue)
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
                $0.accessibilityLabel == OnboardingStrings.Intro.safariAction.value()
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
        let introDeadline = Date(timeIntervalSinceNow: 15)
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

    func testFakeDemoPagesAndNASAClipAreFullyBundled() throws {
        let instaTokURL = try XCTUnwrap(
            Bundle.main.url(forResource: "InstaTok", withExtension: "html"))
        XCTAssertNotNil(instaTokURL)
        let instaTok = try XCTUnwrap(
            OnboardingStrings.Demo.renderedHTML(for: .instaTok))
        XCTAssertTrue(
            instaTok.contains(OnboardingStrings.Demo.instaTokBrand.value()))
        XCTAssertTrue(
            instaTok.contains(OnboardingStrings.Demo.instaTokSignupTitle.value()))
        XCTAssertTrue(instaTok.contains("LunaEclipse.mp4"))
        XCTAssertFalse(instaTok.contains("src=\"http"))

        let amayzonURL = try XCTUnwrap(
            Bundle.main.url(forResource: "Amayzon", withExtension: "html"))
        XCTAssertNotNil(amayzonURL)
        let amayzon = try XCTUnwrap(
            OnboardingStrings.Demo.renderedHTML(for: .amayzon))
        XCTAssertTrue(
            amayzon.contains(
                OnboardingStrings.Demo.amayzonBrandPrefix.value()
                    + "<em>"
                    + OnboardingStrings.Demo.amayzonBrandSuffix.value()
                    + "</em>"))
        XCTAssertTrue(
            amayzon.contains(OnboardingStrings.Demo.amayzonProductTitle.value()))
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
    func viewWithAccessibilityIdentifier(_ identifier: String) -> UIView? {
        if accessibilityIdentifier == identifier { return self }
        return subviews.lazy.compactMap {
            $0.viewWithAccessibilityIdentifier(identifier)
        }.first
    }

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
