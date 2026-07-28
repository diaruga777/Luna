//
//  ReaderOnboardingTests.swift
//  LunaTests
//

import LunaModels
import LunaDesignSystem
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
        XCTAssertEqual(reader.firstLine, "You wish you read more.")
        XCTAssertEqual(reader.secondLine, "Let’s make that happen.")
        XCTAssertEqual(reader.saveBenefit, "Read offline later")
        XCTAssertEqual(reader.demoPages, [.wikipedia])

        let downloader = OnboardingSurfaceConfiguration.configuration(for: .downloader)
        XCTAssertEqual(downloader.firstLine, "App signup required? So annoying.")
        XCTAssertEqual(downloader.secondLine, "Watch and share instantly instead.")
        XCTAssertEqual(downloader.saveBenefit, "Watch or share")
        XCTAssertEqual(downloader.demoPages, [.instaTok])

        let price = OnboardingSurfaceConfiguration.configuration(for: .priceTracker)
        XCTAssertEqual(price.firstLine, "Overpaid? Missed a sale?")
        XCTAssertEqual(price.secondLine, "Never miss out again.")
        XCTAssertEqual(price.saveBenefit, "Never miss a sale")
        XCTAssertEqual(price.demoPages, [.amayzon])

        let luna = OnboardingSurfaceConfiguration.configuration(for: .luna)
        XCTAssertEqual(luna.firstLine, "All your Luna saves.")
        XCTAssertEqual(luna.secondLine, "In a single app.")
        XCTAssertEqual(luna.saveBenefit, "Read, watch, track, anything")
        XCTAssertEqual(luna.demoPages, [.wikipedia, .instaTok, .amayzon])
    }

    @MainActor
    func testIntroShowsFirstLineImmediatelyAndStagesOnlyTheSecondReveal() throws {
        let intro = OnboardingIntroCardContentViewController(
            firstLine: "You wish you read more.",
            secondLine: "Let’s make that happen.")
        intro.loadViewIfNeeded()
        intro.view.frame = CGRect(x: 0, y: 0, width: 354, height: 629)
        intro.view.layoutIfNeeded()

        let lines = intro.view.subviews.compactMap { $0 as? MoonRevealLineView }
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].isFullyRevealed)
        XCTAssertFalse(lines[1].isFullyRevealed)
        XCTAssertFalse(lines[1].occluderHasVisibleChrome)
        XCTAssertTrue(lines[1].usesGlyphEdgeIllumination)

        let button = try XCTUnwrap(
            intro.view.subviews.compactMap { $0 as? UIButton }.first)
        let tintAlpha = try XCTUnwrap(
            button.configuration?.baseBackgroundColor?.cgColor.alpha)
        XCTAssertEqual(tintAlpha, 0.24, accuracy: 0.001)
    }

    func testIntroAndActionButtonTimingsUseTheFasterOverlappedSequence() {
        XCTAssertGreaterThan(OnboardingIntroTiming.secondLineDelay, 1.08)
        XCTAssertGreaterThan(OnboardingIntroTiming.secondLineRevealDuration, 0.82)
        XCTAssertLessThan(OnboardingActionButtonTiming.waveDuration, 1.18)
        XCTAssertEqual(
            OnboardingActionButtonTiming.instructionRevealProgress,
            0.5,
            accuracy: 0.001)
    }

    @MainActor
    func testActionButtonWaveStartsAtThePhysicalScreenEdgeCue() {
        let cue = ActionButtonPressCue()
        cue.frame = CGRect(x: 0, y: 92, width: 44, height: 56)

        XCTAssertEqual(cue.waveOrigin.x, 0, accuracy: 0.001)
        XCTAssertEqual(cue.waveOrigin.y, cue.frame.midY, accuracy: 0.001)
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

        XCTAssertEqual(card.frame, target)
        XCTAssertLessThanOrEqual(AppLaunchTransition.fadeDuration, 0.2)
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
