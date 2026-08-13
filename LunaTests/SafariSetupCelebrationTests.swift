//
//  SafariSetupCelebrationTests.swift
//  LunaTests
//

import LunaModels
import LunaStorage
import LunaURLClassification
import XCTest

/// The one-shot in-page confirmation the Safari extension shows the first time it
/// ever runs after the app sent the user off to set it up.
///
/// Three things are guarded here, because the feature is split across three
/// processes that share only `UserDefaults` keys:
///  1. the RULE (all three conditions, the 24h window, the one-shot latch) as the
///     app-side `LunaSetupStatusStore` states it;
///  2. PARITY between that statement and the extension's copy — `LunaSafari`
///     links no package, so `SharedSafariURL` hand-rolls the same key formats and
///     window, and a rename on one side would silently stop the two from meeting;
///  3. the OVERLAY `content.js` renders, which replaces the pill for five seconds.
final class SafariSetupCelebrationTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: LunaSetupStatusStore!

    /// A fixed "now" so the window arithmetic can't depend on the wall clock.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        suiteName = "SafariSetupCelebrationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = LunaSetupStatusStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - The rule

    /// The extension writes this one; the app only ever reads it.
    private func stampFirstRun(_ app: LunaApp, ago: TimeInterval) {
        defaults.set(
            now.addingTimeInterval(-ago).timeIntervalSince1970,
            forKey: LunaSetupStatusStore.safariFirstRunKey(for: app))
    }

    func testNoEvidenceDoesNotCelebrate() {
        XCTAssertFalse(store.shouldCelebrateSafariSetup(for: .reader, now: now))
    }

    /// A tap alone proves only that the user left for Safari — not that the
    /// extension they went to enable ever ran.
    func testSetupTapAloneDoesNotCelebrate() {
        store.recordSafariSetupTap(for: .reader, at: now.addingTimeInterval(-60))
        XCTAssertFalse(store.shouldCelebrateSafariSetup(for: .reader, now: now))
    }

    /// And a first run alone is somebody enabling the extension on their own,
    /// with no onboarding to return to.
    func testFirstRunAloneDoesNotCelebrate() {
        stampFirstRun(.reader, ago: 60)
        XCTAssertFalse(store.shouldCelebrateSafariSetup(for: .reader, now: now))
    }

    func testRecentTapAndRecentFirstRunCelebrate() {
        store.recordSafariSetupTap(for: .reader, at: now.addingTimeInterval(-90))
        stampFirstRun(.reader, ago: 30)
        XCTAssertTrue(store.shouldCelebrateSafariSetup(for: .reader, now: now))
    }

    func testEvidenceJustInsideTheWindowStillCelebrates() {
        let almost = LunaSetupStatusStore.safariCelebrationWindow - 1
        store.recordSafariSetupTap(for: .reader, at: now.addingTimeInterval(-almost))
        stampFirstRun(.reader, ago: almost)
        XCTAssertTrue(store.shouldCelebrateSafariSetup(for: .reader, now: now))
    }

    /// The user who set Safari up yesterday and is browsing today gets their pill,
    /// not a stale congratulation.
    func testStaleSetupTapDoesNotCelebrate() {
        let stale = LunaSetupStatusStore.safariCelebrationWindow + 1
        store.recordSafariSetupTap(for: .reader, at: now.addingTimeInterval(-stale))
        stampFirstRun(.reader, ago: 30)
        XCTAssertFalse(store.shouldCelebrateSafariSetup(for: .reader, now: now))
    }

    /// Replaying the lesson from Settings on a long-installed extension stamps a
    /// fresh tap, but the extension's first run is still last year.
    func testStaleFirstRunDoesNotCelebrate() {
        store.recordSafariSetupTap(for: .reader, at: now.addingTimeInterval(-30))
        stampFirstRun(.reader, ago: LunaSetupStatusStore.safariCelebrationWindow + 1)
        XCTAssertFalse(store.shouldCelebrateSafariSetup(for: .reader, now: now))
    }

    /// A backwards clock must suppress the confirmation, never replay it.
    func testStampsInTheFutureDoNotCelebrate() {
        store.recordSafariSetupTap(for: .reader, at: now.addingTimeInterval(600))
        stampFirstRun(.reader, ago: -600)
        XCTAssertFalse(store.shouldCelebrateSafariSetup(for: .reader, now: now))
    }

    func testOnceShownItNeverCelebratesAgain() {
        store.recordSafariSetupTap(for: .reader, at: now.addingTimeInterval(-90))
        stampFirstRun(.reader, ago: 30)
        XCTAssertTrue(store.shouldCelebrateSafariSetup(for: .reader, now: now))

        // What the extension's `recordCelebrationShown` writes.
        defaults.set(true, forKey: LunaSetupStatusStore.safariCelebrationShownKey(for: .reader))
        XCTAssertTrue(store.safariCelebrationWasShown(for: .reader))
        XCTAssertFalse(store.shouldCelebrateSafariSetup(for: .reader, now: now))
    }

    /// An extension may only ever hand off to its OWN containing app, so central
    /// Luna's tap must not make the Reader's extension offer to return the user to
    /// an app they never left.
    func testEvidenceDoesNotCrossBetweenApps() {
        store.recordSafariSetupTap(for: .luna, at: now.addingTimeInterval(-90))
        stampFirstRun(.reader, ago: 30)
        for app in LunaApp.allCases {
            XCTAssertFalse(
                store.shouldCelebrateSafariSetup(for: app, now: now),
                "\(app) celebrated on another app's half of the evidence")
        }
    }

    // MARK: - The extension's half

    /// The extension's own first run, which is half the evidence. Its stamp is
    /// written once and never moved: an extension first-runs exactly once, and a
    /// later run that re-stamped it would make "first ran recently" true forever.
    func testTheExtensionRunStampsTheFirstMomentOnlyAndCompletesSetup() {
        store.recordSafariExtensionRun(for: .reader, at: now.addingTimeInterval(-90))
        XCTAssertEqual(
            store.safariExtensionFirstRunDate(for: .reader), now.addingTimeInterval(-90))
        XCTAssertTrue(store.safariRunApplies(to: .reader))

        store.recordSafariExtensionRun(for: .reader, at: now)
        XCTAssertEqual(
            store.safariExtensionFirstRunDate(for: .reader), now.addingTimeInterval(-90))
    }

    /// Reader/Downloader/Price Tracker share completion evidence; bare central
    /// Luna is deliberately independent, and its own run covers the siblings.
    func testTheExtensionRunFilesCompletionUnderTheRightFacet() {
        store.recordSafariExtensionRun(for: .reader, at: now)
        XCTAssertTrue(store.safariRunApplies(to: .downloader))
        XCTAssertFalse(store.safariRunApplies(to: .luna))

        store.recordSafariExtensionRun(for: .luna, at: now)
        XCTAssertTrue(store.safariRunApplies(to: .luna))
    }

    /// Both halves recorded through the store, and the one-shot latch the
    /// extension writes when the overlay actually renders.
    func testTheExtensionsOwnWritesEarnAndThenSpendTheConfirmation() {
        store.recordSafariSetupTap(for: .reader, at: now.addingTimeInterval(-90))
        store.recordSafariExtensionRun(for: .reader, at: now.addingTimeInterval(-30))
        XCTAssertTrue(store.shouldCelebrateSafariSetup(for: .reader, now: now))

        store.recordSafariCelebrationShown(for: .reader)

        XCTAssertTrue(store.safariCelebrationWasShown(for: .reader))
        XCTAssertFalse(store.shouldCelebrateSafariSetup(for: .reader, now: now))
    }

    /// The extension names the app from the tap the app itself stamped, and has
    /// nothing to offer before one exists.
    func testTheTapAppNameIsReadBackPerAppAndAbsentUntilStamped() {
        XCTAssertNil(store.safariSetupTapAppName(for: .reader))
        store.recordSafariSetupTap(for: .reader, at: now)
        XCTAssertEqual(store.safariSetupTapAppName(for: .reader), LunaApp.reader.displayName)
        XCTAssertNil(store.safariSetupTapAppName(for: .downloader))
    }

    /// An extension resolves BOTH halves of its identity from its own bundle id
    /// — `<host app>.safari` — the surface its App-Group keys are built from and
    /// the scheme its page buttons deep-link into. The keys only ever meet the
    /// app's if that resolution agrees with the app's own.
    func testAnExtensionBundleIdResolvesToItsHostAppsSurfaceAndScheme() {
        let cases: [(identifier: String, app: LunaApp, scheme: String)] = [
            ("com.hsanabria.luna.safari", .luna, LunaDeepLink.lunaScheme),
            ("com.hsanabria.luna.reader.safari", .reader, LunaDeepLink.readerScheme),
            ("com.hsanabria.luna.downloader.safari", .downloader, LunaDeepLink.downloaderScheme),
            ("com.hsanabria.luna.pricetracker.safari", .priceTracker,
             LunaDeepLink.priceTrackerScheme),
        ]
        for testCase in cases {
            XCTAssertEqual(
                LunaApp.detect(bundleIdentifier: testCase.identifier), testCase.app,
                "\(testCase.identifier) resolved to the wrong surface")
            XCTAssertEqual(
                LunaDeepLink.appScheme(forBundleIdentifier: testCase.identifier),
                testCase.scheme,
                "\(testCase.identifier) would deep-link into another app")
        }
    }

    func testTheTapRecordsTheAppsOwnNameToInviteThemBackWith() {
        store.recordSafariSetupTap(for: .priceTracker, at: now)
        XCTAssertEqual(
            defaults.string(
                forKey: LunaSetupStatusStore.safariSetupTapAppNameKey(for: .priceTracker)),
            LunaApp.priceTracker.displayName)
    }

    /// `-resetOnboarding` has to clear the EXTENSION's stamps too: an extension
    /// first-runs exactly once, so a reset that left `firstRunAt` behind could
    /// never show the confirmation again.
    func testResettingRunEvidenceMakesTheConfirmationEligibleAgain() {
        store.recordSafariSetupTap(for: .reader, at: now.addingTimeInterval(-90))
        stampFirstRun(.reader, ago: 30)
        defaults.set(true, forKey: LunaSetupStatusStore.safariCelebrationShownKey(for: .reader))

        store.resetAllRunEvidence()

        XCTAssertNil(store.safariSetupTapDate(for: .reader))
        XCTAssertNil(store.safariExtensionFirstRunDate(for: .reader))
        XCTAssertFalse(store.safariCelebrationWasShown(for: .reader))
        XCTAssertNil(
            defaults.string(forKey: LunaSetupStatusStore.safariSetupTapAppNameKey(for: .reader)))

        // Re-earned from scratch.
        store.recordSafariSetupTap(for: .reader, at: now.addingTimeInterval(-5))
        stampFirstRun(.reader, ago: 1)
        XCTAssertTrue(store.shouldCelebrateSafariSetup(for: .reader, now: now))
    }

    // MARK: - Parity with the extension's copy

    private static func source(_ relativePath: String) -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return (try? String(
            contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)) ?? ""
    }

    /// Every key format, as the literal prefix both sides interpolate the app's
    /// storage identifier onto.
    private func keyPrefixes() -> [String] {
        [
            LunaSetupStatusStore.safariSetupTapKey(for: .reader),
            LunaSetupStatusStore.safariSetupTapAppNameKey(for: .reader),
            LunaSetupStatusStore.safariFirstRunKey(for: .reader),
            LunaSetupStatusStore.safariCelebrationShownKey(for: .reader),
        ].map { String($0.dropLast(LunaApp.reader.storageIdentifier.count)) }
    }

    func testTheExtensionUsesTheSameAppGroupKeys() {
        let extensionSource = Self.source("LunaSafari/SharedSafariURL.swift")
        XCTAssertFalse(extensionSource.isEmpty, "LunaSafari/SharedSafariURL.swift not found")
        for prefix in keyPrefixes() {
            XCTAssertTrue(
                extensionSource.contains("\"\(prefix)\\("),
                "SharedSafariURL has no key built from \"\(prefix)\" -- the app writes a key "
                    + "the extension never reads")
        }
    }

    func testTheExtensionUsesTheSameWindow() {
        XCTAssertEqual(LunaSetupStatusStore.safariCelebrationWindow, 24 * 60 * 60)
        XCTAssertTrue(
            Self.source("LunaSafari/SharedSafariURL.swift").contains("24 * 60 * 60"),
            "SharedSafariURL.celebrationWindow has drifted from "
                + "LunaSetupStatusStore.safariCelebrationWindow")
    }

    /// The extension keys on `SharedSurfaceScheme`'s surface string while the app
    /// keys on `LunaApp.storageIdentifier`. They are the same four words, and the
    /// whole hand-off silently stops working if they ever aren't.
    func testTheExtensionsSurfaceNamesAreTheAppsStorageIdentifiers() {
        let surfaceSource = Self.source("LunaSafari/SharedSurfaceScheme.swift")
        XCTAssertFalse(surfaceSource.isEmpty, "LunaSafari/SharedSurfaceScheme.swift not found")
        for app in LunaApp.allCases {
            XCTAssertTrue(
                surfaceSource.contains("\"\(app.storageIdentifier)\""),
                "SharedSurfaceScheme names no surface \"\(app.storageIdentifier)\" -- its keys "
                    + "cannot meet \(app)'s")
        }
    }

    /// The handler answers the decision on the context request the content script
    /// already makes, and takes the "it was shown" write back on a named type.
    func testTheHandlerAndBackgroundRelayCarryTheDecision() {
        let handler = Self.source("LunaSafari/SafariWebExtensionHandler.swift")
        let background = Self.source("LunaSafari/Resources/background.js")
        XCTAssertFalse(handler.isEmpty)
        XCTAssertFalse(background.isEmpty)
        for field in ["celebrateSetup", "appName", "setupCelebrationShown"] {
            XCTAssertTrue(handler.contains(field), "the native handler never mentions \(field)")
            XCTAssertTrue(
                background.contains(field),
                "background.js drops \(field) — content scripts can't reach the native handler "
                    + "except through this relay")
        }
    }

}

/// The overlay itself, rendered by the production `content.js` in a bare
/// `WKWebView` (no extension host, so `presentSetupCelebration` is reached through
/// the `window.__luna*` handle it exports for exactly this).
@MainActor
final class SafariSetupCelebrationOverlayTests: XCTestCase {

    private static let windowHeight: CGFloat = 844

    private lazy var js = SafariJSTestHarness(self)

    override func setUp() {
        super.setUp()
        // A fresh document per test (so one test's overlay can't leak into the
        // next) on the ONE shared web view. The harness's blank page carries the
        // viewport meta this class needs: without one WebKit lays the fixture out
        // in its default 980pt-wide viewport, so every CSS pixel — and therefore
        // every `vh` — is scaled, and the measurements below stop resembling a phone.
        js.load(urlString: "https://example.com/")
    }

    private func present(scheme: String = "lunareader", appName: String = "Luna Reader") {
        _ = evaluate("""
            window.__lunaTestDismissed = false;
            window.__lunaPresentSetupCelebration(
                { scheme: \(json(scheme)), appName: \(json(appName)) },
                function () { window.__lunaTestDismissed = true; });
            "presented"
            """)
    }

    private var overlayQuery: String {
        "document.getElementById(window.__lunaSetupCelebrationID)"
    }

    /// The height `vh`/`dvh` resolve against — the window as the page sees it.
    private var windowHeight: Double { number("window.innerHeight") }

    func testTheOverlayCoversTheWindowAndNamesTheApp() {
        present()
        XCTAssertEqual(evaluate("\(overlayQuery) ? 'present' : 'absent'"), "present")
        // Measured against the live viewport rather than the frame: the whole point
        // is that the confirmation takes the window, whatever size Safari makes it.
        XCTAssertEqual(windowHeight, Double(Self.windowHeight), accuracy: 1.0)
        XCTAssertEqual(
            number("\(overlayQuery).getBoundingClientRect().height"),
            windowHeight, accuracy: 1.0)
        XCTAssertEqual(
            evaluate("\(overlayQuery).firstChild.textContent"), "Nice!\nYou're all set up")
        XCTAssertEqual(
            evaluate("\(overlayQuery).lastChild.textContent"), "Return to Luna Reader")
        // The page stays visible through it — an opaque takeover would hide the
        // very page the extension just proved it can reach.
        let background = evaluate("getComputedStyle(\(overlayQuery)).backgroundColor")
        XCTAssertTrue(
            background.contains("rgba"),
            "the overlay's background is \(background) -- it must be semi-transparent")
    }

    /// "Centred text, a third of the window high."
    func testTheHeadlineIsAThirdOfTheWindowHigh() {
        present()
        XCTAssertEqual(
            number("\(overlayQuery).firstChild.getBoundingClientRect().height"),
            windowHeight / 3, accuracy: 1.0)
        XCTAssertEqual(evaluate("getComputedStyle(\(overlayQuery).firstChild).textAlign"), "center")
        // The line break in the string is deliberate and must render as one.
        XCTAssertEqual(
            evaluate("getComputedStyle(\(overlayQuery).firstChild).whiteSpace"), "pre-line")
    }

    /// The button reopens the app on whatever it was showing — it must not hand it
    /// the page the user happened to be practising on.
    func testTheButtonOpensTheAppWithNoURL() {
        present(scheme: "lunapricetracker", appName: "Luna Price Tracker")
        XCTAssertEqual(
            evaluate("\(overlayQuery).lastChild.textContent"), "Return to Luna Price Tracker")

        // The tap goes through the real navigation path; the harness captures the
        // app-scheme URL and cancels it rather than letting it leave the fixture.
        let attempted = js.awaitAppSchemeNavigation {
            _ = evaluate("\(overlayQuery).lastChild.click(); 'clicked'")
        }
        XCTAssertEqual(attempted, "lunapricetracker://")
        // Feedback while the app comes up, the same beat the pill gives.
        XCTAssertEqual(evaluate("\(overlayQuery).lastChild.textContent"), "Opening Luna…")
    }

    func testAMissingSchemeLeavesNoDeadButton() {
        present(scheme: "")
        XCTAssertEqual(evaluate("\(overlayQuery) ? 'present' : 'absent'"), "present")
        XCTAssertEqual(evaluate("String(\(overlayQuery).childNodes.length)"), "1")
        XCTAssertEqual(
            evaluate("\(overlayQuery).firstChild.textContent"), "Nice!\nYou're all set up")
    }

    func testPresentingTwiceLeavesOneOverlay() {
        present()
        present()
        XCTAssertEqual(
            evaluate(
                "String(document.querySelectorAll('#' + window.__lunaSetupCelebrationID).length)"),
            "1")
    }

    /// The self-dismissal, without spending its twenty seconds — and without a
    /// wait of any kind.
    ///
    /// `SETUP_CELEBRATION_DURATION` is a closure-scoped constant, so it can't be
    /// shortened from outside; but the ONE thing the overlay does with it is
    /// hand it to `setTimeout`, and that IS reachable. Stubbing `setTimeout`
    /// across `present()` intercepts the dismissal timer instead of scheduling
    /// it, which lets this assert three things a passive duration mirror could
    /// only imply: the timer was armed with 20000 (not merely that a mirror
    /// global says so), the overlay is still up until it fires, and firing it is
    /// what takes the overlay down and hands the page back.
    func testItDismissesItselfAfterTwentySecondsAndHandsThePageBack() {
        _ = evaluate("""
            window.__lunaRealSetTimeout = window.setTimeout;
            window.__lunaArmedDelay = null;
            window.__lunaArmedCallback = null;
            window.setTimeout = function (fn, delay) {
                if (delay >= 1000 && window.__lunaArmedCallback === null) {
                    window.__lunaArmedDelay = delay;
                    window.__lunaArmedCallback = fn;
                    return 0;
                }
                return window.__lunaRealSetTimeout.apply(window, arguments);
            };
            "stubbed"
            """)
        present()
        _ = evaluate("window.setTimeout = window.__lunaRealSetTimeout; 'restored'")

        XCTAssertEqual(
            evaluate("String(window.__lunaArmedDelay)"), "20000",
            "the dismissal timer must be armed with the celebration's own duration")
        XCTAssertEqual(evaluate("String(window.__lunaSetupCelebrationDuration)"), "20000")
        // Nothing has fired yet, so the overlay is still up.
        XCTAssertEqual(evaluate("\(overlayQuery) ? 'present' : 'absent'"), "present")
        XCTAssertEqual(evaluate("String(window.__lunaTestDismissed)"), "false")

        _ = evaluate("window.__lunaArmedCallback(); 'fired'")

        XCTAssertEqual(evaluate("\(overlayQuery) ? 'present' : 'absent'"), "absent")
        // The callback is how the pill logic gets its turn.
        XCTAssertEqual(evaluate("String(window.__lunaTestDismissed)"), "true")
    }

    func testPageHideDismissesTheOverlayWithoutHandingThePageBack() {
        present()
        _ = evaluate("window.dispatchEvent(new Event('pagehide')); 'hidden'")
        XCTAssertEqual(evaluate("\(overlayQuery) ? 'present' : 'absent'"), "absent")
        XCTAssertEqual(evaluate("String(window.__lunaTestDismissed)"), "false")
    }

    // MARK: - Harness

    private func evaluate(_ script: String) -> String {
        guard let result = js.evaluate(script), !(result is NSNull) else { return "" }
        return result as? String ?? String(describing: result)
    }

    private func number(_ expression: String) -> Double {
        Double(evaluate("String(\(expression))")) ?? .nan
    }

    private func json(_ value: String) -> String { SafariJSTestHarness.jsString(value) }
}
