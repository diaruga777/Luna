//
//  OnboardingSaveDemoTests.swift
//  LunaTests
//

import LunaModels
import LunaShareSurface
import LunaStorage
import UIKit
import XCTest
@testable import Luna

/// The save lesson runs the REAL share surface over a REAL link. These pin the
/// three things that makes possible and the two things it must never do: it must
/// not complete the user's setup step on their behalf, and it must not leave its
/// rehearsal in the deck.
final class OnboardingSaveDemoTests: XCTestCase {

    // MARK: - Which link the lesson rehearses with

    func testALiveWeeklySaveIsWhatTheLessonRehearsesWith() {
        let link = OnboardingSaveDemoLink.resolve(
            practiceURLString: ShareSetupPractice.instaTokURLString,
            app: .downloader,
            weeklyURLString: { _ in "https://example.com/pick-of-the-week" },
            isOnline: { true })

        XCTAssertEqual(link.urlString, "https://example.com/pick-of-the-week")
        XCTAssertTrue(link.isWeeklySave)
        XCTAssertFalse(link.isOffline)
    }

    /// No signed entry (the ordinary state until the weekly feature is deployed)
    /// falls back to this app's OWN practice link — the media app rehearses with a
    /// media link, whatever the browser lesson happens to be showing.
    func testWithoutAWeeklySaveTheAppsOwnPracticeLinkStandsIn() {
        for (app, expected) in [
            (LunaApp.reader, ShareSetupPractice.lunaURLString),
            (LunaApp.downloader, ShareSetupPractice.instaTokURLString),
            (LunaApp.priceTracker, ShareSetupPractice.amayzonURLString),
            (LunaApp.luna, ShareSetupPractice.lunaURLString),
        ] {
            let configuration = OnboardingSurfaceConfiguration.configuration(for: app)
            XCTAssertEqual(configuration.practiceURLString, expected)
            for weekly in [nil, "", "   "] as [String?] {
                let link = OnboardingSaveDemoLink.resolve(
                    practiceURLString: configuration.practiceURLString,
                    app: app,
                    weeklyURLString: { _ in weekly },
                    isOnline: { true })
                XCTAssertEqual(link.urlString, expected)
                XCTAssertFalse(link.isWeeklySave)
                XCTAssertFalse(link.isOffline)
            }
        }
    }

    /// Offline, a weekly pick cannot be fetched, so the lesson does not pretend
    /// one was: the practice link goes in, flagged for the real failure state.
    func testOfflineTheLessonShowsTheRealFailureInsteadOfAFetch() {
        let link = OnboardingSaveDemoLink.resolve(
            practiceURLString: ShareSetupPractice.lunaURLString,
            app: .reader,
            weeklyURLString: { _ in "https://example.com/pick-of-the-week" },
            isOnline: { false })

        XCTAssertEqual(link.urlString, ShareSetupPractice.lunaURLString)
        XCTAssertFalse(link.isWeeklySave)
        XCTAssertTrue(link.isOffline)
    }

    /// Optimistic before the first path update — and deliberately the opposite of
    /// `isOnWiFi`'s pessimism, because this gates a load the user asked for.
    func testReachabilityAnswersOnlineBeforeItKnowsAnything() {
        XCTAssertTrue(NetworkReachability.shared.isOnline)
    }

    // MARK: - The hosted surface

    /// The practice link never reaches the network in ANY surface: the extensions
    /// recognize it and show the bundled preview instead. Hosted, that same real
    /// path is what the lesson displays — which is why the stub sheet that used to
    /// impersonate a reader could be deleted.
    @MainActor
    func testHostedPracticeLinkShowsTheRealPreviewAndSavesNothing() throws {
        let url = try XCTUnwrap(URL(string: ShareSetupPractice.lunaURLString))
        let before = Set(ReadingListStore.shared.items().map(\.id))
        let setup = LunaSetupStatusStore.shared
        let evidenceBefore = setup.shareActionHasRun(isCentral: true)

        var finished = 0
        let surface = ShareViewController(hosted: .url(url)) { finished += 1 }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = surface
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        surface.view.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))

        XCTAssertTrue(surface.isHosted)
        XCTAssertTrue(
            surface.isActionExtension,
            "A hosted surface wants the status chrome and the reader, not the "
                + "zero-UI terminal")
        XCTAssertTrue(
            surface.children.contains { $0 is UINavigationController },
            "The practice preview is presented in the surface's own nav context")
        XCTAssertEqual(Set(ReadingListStore.shared.items().map(\.id)), before)
        XCTAssertEqual(finished, 0, "Nothing has completed the request yet")
        XCTAssertEqual(
            setup.shareActionHasRun(isCentral: true), evidenceBefore,
            "A rehearsal must not complete the user's setup step for them")
    }

    /// The one honest thing to show with no connection: `SaveFailureReason.offline`
    /// in the surface's real error state — the real headline, under the symbol for
    /// it, over a line saying what the user is looking at instead of a save.
    ///
    /// NOT the failure's own `suggestion`: "it will retry once you're back online"
    /// describes a save that was kept, and the rehearsal's row is deleted either
    /// way. The assertion is on its ABSENCE for that reason.
    @MainActor
    func testHostedOfflineInputRendersTheRealOfflineFailure() throws {
        let url = try XCTUnwrap(URL(string: ShareSetupPractice.lunaURLString))
        let surface = ShareViewController(hosted: .offlineFailure(url)) {}
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = surface
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        surface.view.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        let shown = window.descendants(of: UILabel.self).compactMap(\.text)
        XCTAssertTrue(
            shown.contains { $0.contains(SaveFailureReason.offline.headline) },
            "Expected the real offline headline, got \(shown)")
        XCTAssertTrue(
            shown.contains {
                $0.contains(L10n.string("ShareExtension_share_hostedOfflineDetail"))
            },
            "Expected the rehearsal's own explanation, got \(shown)")
        let suggestion = try XCTUnwrap(SaveFailureReason.offline.suggestion)
        XCTAssertFalse(
            shown.contains { $0.contains(suggestion) },
            "The failed-card retry hint is not true of a rehearsal")
        let icon = window.descendants(of: UIImageView.self).first {
            $0.accessibilityIdentifier
                == ExtensionLoadingViewController.terminalIconIdentifier
        }
        XCTAssertNotNil(
            icon?.image,
            "Expected the offline state to be drawn, not only written")
    }

    /// Completion is one chokepoint and it is idempotent, hosted or not — a
    /// double `completeRequest` is undefined behavior, and a double `onFinish`
    /// would advance the lesson twice.
    @MainActor
    func testHostedCompletionFiresExactlyOnce() throws {
        let url = try XCTUnwrap(URL(string: ShareSetupPractice.lunaURLString))
        var finished = 0
        let surface = ShareViewController(hosted: .url(url)) { finished += 1 }
        surface.loadViewIfNeeded()

        surface.completeSilently()
        surface.completeSilently()
        surface.failOrComplete("and again")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        XCTAssertEqual(finished, 1)
    }

    /// The evidence guard, both ways round. A real extension records a run for
    /// ANY handled URL — the lesson hands the real sheet a real weekly pick, and
    /// that save is exactly the evidence being asked for — while the in-app
    /// rehearsal records nothing at all.
    @MainActor
    func testOnlyARealSurfaceRecordsSetupRunEvidence() throws {
        let url = try XCTUnwrap(URL(string: ShareSetupPractice.lunaURLString))
        XCTAssertFalse(
            ShareViewController(hosted: .url(url)) {}.recordsSetupRunEvidence)
        XCTAssertFalse(
            ShareViewController(hosted: .offlineFailure(url)) {}
                .recordsSetupRunEvidence)
        XCTAssertTrue(ShareViewController().recordsSetupRunEvidence)
    }

    // MARK: - The rehearsal's own row

    /// A rehearsal leaves the deck exactly as empty as the user left it. The row
    /// the real surface appends is marked as this app's temporary save while it
    /// exists, and gone by the time the lesson ends.
    @MainActor
    func testTheDemonstrationTakesItsOwnRowBackOut() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SaveDemo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let suite = "OnboardingSaveDemoTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }

        let contentStore = ReadingListStore(containerURL: directory)
        let onboardingStore = AppOnboardingStore(app: .reader, defaults: defaults)
        let link = OnboardingSaveDemoLink.resolve(
            practiceURLString: ShareSetupPractice.lunaURLString,
            app: .reader,
            weeklyURLString: { _ in nil },
            isOnline: { true })
        let demo = OnboardingSaveDemoController(
            link: link,
            onboardingStore: onboardingStore,
            contentStore: contentStore)

        // What the hosted surface's append leaves behind, and the marker that
        // keeps it from answering the first run.
        let userSave = contentStore.add(urlString: "https://example.com/real")
        let rehearsal = contentStore.add(urlString: link.urlString)
        onboardingStore.recordTemporarySave(identifier: rehearsal.id)
        XCTAssertEqual(onboardingStore.temporarySaveIdentifier, rehearsal.id)

        demo.tearDown()

        XCTAssertNil(contentStore.item(withID: rehearsal.id))
        XCTAssertEqual(contentStore.item(withID: userSave.id)?.id, userSave.id)
        XCTAssertNil(onboardingStore.temporarySaveIdentifier)
    }

    /// The sheet is chrome and nothing else now: it carries no article of its own
    /// (the hand-drawn reader it used to impersonate is gone), it is inert, and its
    /// card sits exactly where the old one did.
    @MainActor
    func testTheSaveSheetIsChromeOnlyAndNotTappable() {
        let sheet = OnboardingHostedShareSheetView(
            frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        sheet.layoutIfNeeded()

        XCTAssertFalse(sheet.isUserInteractionEnabled)
        XCTAssertEqual(sheet.cardFrame.minY, OnboardingHostedShareSheetView.cardTop)
        XCTAssertEqual(sheet.cardFrame.maxY, 852)
        XCTAssertEqual(sheet.content.bounds.height, sheet.cardFrame.height)
        XCTAssertTrue(
            sheet.descendants(of: UILabel.self).isEmpty,
            "The sheet must carry no copy of its own — what is inside it is the "
                + "real surface")
    }

    /// The hold on a finished screen is the same beat the mock used to spend on a
    /// fake one, and the video plays long enough to read as playback.
    func testSaveDemoTimingsStayDeliberate() {
        XCTAssertEqual(
            OnboardingSaveDemoTiming.terminalHoldDuration,
            OnboardingShortcutRunTiming.extensionSheetHoldDuration)
        XCTAssertGreaterThanOrEqual(
            OnboardingSaveDemoTiming.videoPlaybackDuration, 1.5)
        XCTAssertLessThan(OnboardingSaveDemoTiming.mediaSettleInterval, 0.25)
    }

    /// A hosted session's floor is the whole reason a preloaded download is still
    /// visible: nothing may resolve before the sheet has opened, and then not for
    /// another beat.
    @MainActor
    func testAHostedSessionHoldsResultsUntilItsSheetHasOpened() {
        let session = HostedShareSession()
        XCTAssertNil(session.revealDate)
        XCTAssertNil(
            session.earliestDownloadResolution,
            "Nothing may resolve while the sheet is still opening")

        session.markRevealed()
        let first = session.revealDate
        session.markRevealed()
        XCTAssertEqual(session.revealDate, first, "One reveal per pass")
        let earliest = session.earliestDownloadResolution
        XCTAssertNotNil(earliest)
        XCTAssertEqual(
            earliest?.timeIntervalSince(try! XCTUnwrap(first)) ?? 0,
            session.minimumDownloadIndication,
            accuracy: 0.001)

        // Each pass of the looping demonstration gets its own floor.
        session.beginReveal()
        XCTAssertNil(session.revealDate)

        var released = 0
        session.retain("artifact") { released += 1 }
        XCTAssertEqual(session.retainedArtifacts.count, 1)
        session.releaseArtifacts()
        session.releaseArtifacts()
        XCTAssertEqual(released, 1, "Artifacts are let go exactly once")
        XCTAssertTrue(session.retainedArtifacts.isEmpty)
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
