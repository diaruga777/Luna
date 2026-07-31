//
//  OnboardingDemoSaveEvictionTests.swift
//  LunaTests
//

import LunaMediaDownload
import LunaModels
import LunaStorage
import XCTest
@testable import Luna

final class OnboardingDemoSaveEvictionTests: XCTestCase {
    /// The demonstration item is scaffolding for the empty deck. The first REAL
    /// save retires it — and nothing else does: not a pre-existing item, not a
    /// change notification that added nothing.
    @MainActor
    func testDemonstrationSaveEvictsItselfOnTheFirstRealSave() throws {
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

        let store = ReadingListStore(containerURL: directory)
        let registry = AppOnboardingStore(app: .reader, defaults: defaults)
        let center = NotificationCenter()
        // Content the user already had before this onboarding run.
        let preexisting = store.add(urlString: "https://example.com/kept")
        let demoURL = "https://luna.app?test=evict"
        XCTAssertTrue(BundledLunaArticle.installTemporary(
            urlString: demoURL, registry: registry, in: store))
        let demoID = try XCTUnwrap(registry.temporarySaveIdentifier)

        let save = OnboardingTemporarySave(
            install: { true },
            cleanup: {
                BundledLunaArticle.cleanupTemporary(
                    registry: registry, in: store)
            },
            changeNotifications: [.readingListChanged],
            storedIdentifiers: { Set(store.items().map(\.id)) })
        let evictor = OnboardingDemoSaveEvictor()
        evictor.arm(save, registry: registry, notificationCenter: center)
        XCTAssertTrue(evictor.isArmed)

        // A change that added nothing new leaves the demonstration standing —
        // the pre-existing item is not the user's first save.
        evictor.contentDidChange()
        XCTAssertTrue(evictor.isArmed)
        XCTAssertNotNil(store.item(withID: demoID))
        XCTAssertNotNil(store.item(withID: preexisting.id))

        // The first real save takes it back out, and the watch ends there.
        let real = store.add(urlString: "https://example.com/first-real-save")
        evictor.contentDidChange()
        XCTAssertNil(store.item(withID: demoID))
        XCTAssertNil(registry.temporarySaveIdentifier)
        XCTAssertNotNil(store.item(withID: real.id))
        XCTAssertNotNil(store.item(withID: preexisting.id))
        XCTAssertFalse(evictor.isArmed)
    }

    @MainActor
    func testEvictorNeverArmsWithoutADemonstrationItemToRemove() {
        let suite = "ReaderOnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let registry = AppOnboardingStore(app: .reader, defaults: defaults)
        var cleanups = 0
        let evictor = OnboardingDemoSaveEvictor()
        evictor.arm(
            OnboardingTemporarySave(
                install: { true },
                cleanup: { cleanups += 1 },
                changeNotifications: [.readingListChanged],
                storedIdentifiers: { [] }),
            registry: registry,
            notificationCenter: NotificationCenter())

        // `installTemporary` clears ownership when the item was already the
        // user's; there is nothing of onboarding's to evict.
        XCTAssertFalse(evictor.isArmed)
        evictor.contentDidChange()
        XCTAssertEqual(cleanups, 0)
    }

    /// The central app's deck draws every kind, so its demonstration item has to
    /// watch every store it saves into — a media save must retire the mock
    /// article just as an article save does.
    func testTheCentralAppsDemonstrationSaveWatchesEveryStoreItSavesInto() {
        let central = KindWiring.onboardingDemoSave
        XCTAssertTrue(central.changeNotifications.contains(.readingListChanged))
        XCTAssertTrue(central.changeNotifications.contains(.savedMediaChanged))
        // The reading list alone would miss a downloaded video.
        XCTAssertTrue(
            central.storedIdentifiers().isSuperset(
                of: SavedMediaStore.shared.items().map(\.id)))
    }
}
