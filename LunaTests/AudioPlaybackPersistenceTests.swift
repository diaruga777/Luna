//
//  AudioPlaybackPersistenceTests.swift
//  LunaTests
//

import XCTest
@testable import LunaAudioPlayback

/// `AudioPlaybackPositionStore` round-trip (scratch `UserDefaults` suite, per
/// the SafariExtensionStatusStoreTests pattern) and `AudioSettings` clamping /
/// defaults (the shared App-Group suite, with original values restored).
final class AudioPlaybackPersistenceTests: XCTestCase {

    // MARK: - Position store

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: AudioPlaybackPositionStore!

    override func setUp() {
        super.setUp()
        suiteName = "AudioPlaybackPersistenceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = AudioPlaybackPositionStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testLoadReturnsNilWhenNothingSaved() {
        XCTAssertNil(store.load())
    }

    func testSaveLoadRoundTrip() {
        let position = AudioPlaybackPositionStore.Position(
            itemID: UUID(), wordIndex: 123, elapsed: 45.5, title: "An Article")
        store.save(position)
        XCTAssertEqual(store.load(), position)
    }

    func testSaveOverwritesPreviousPosition() {
        store.save(.init(itemID: UUID(), wordIndex: 1, elapsed: 1, title: "first"))
        let second = AudioPlaybackPositionStore.Position(
            itemID: UUID(), wordIndex: 2, elapsed: 2, title: "second")
        store.save(second)
        XCTAssertEqual(store.load(), second)
    }

    func testClearRemovesThePosition() {
        store.save(.init(itemID: UUID(), wordIndex: 1, elapsed: 1, title: "x"))
        store.clear()
        XCTAssertNil(store.load())
    }

    func testCorruptPayloadLoadsAsNil() {
        defaults.set(["itemID": "not-a-uuid", "wordIndex": 3], forKey: "audioPlaybackPosition.v1")
        XCTAssertNil(store.load())
    }

    // MARK: - AudioSettings

    /// AudioSettings is deliberately App-Group-global (no injectable suite —
    /// it mirrors ReaderSettings/VoiceModelStore exactly), so these tests
    /// save and restore the live values around each assertion.
    private func withSavedSettings(_ body: () -> Void) {
        let autoplay = AudioSettings.isAutoplayEnabled
        let trimming = AudioSettings.isIntelligentTrimmingEnabled
        let rate = AudioSettings.preferredRate
        body()
        AudioSettings.isAutoplayEnabled = autoplay
        AudioSettings.isIntelligentTrimmingEnabled = trimming
        AudioSettings.preferredRate = rate
    }

    func testAudioSettingsDefaults() {
        withSavedSettings {
            let suite = UserDefaults(suiteName: AudioSettings.appGroupID) ?? .standard
            suite.removeObject(forKey: "audioAutoplayEnabled")
            suite.removeObject(forKey: "audioIntelligentTrimmingEnabled")
            suite.removeObject(forKey: "audioPreferredRate")
            XCTAssertTrue(AudioSettings.isAutoplayEnabled, "autoplay defaults ON")
            XCTAssertTrue(AudioSettings.isIntelligentTrimmingEnabled, "intelligent trimming defaults ON")
            XCTAssertEqual(AudioSettings.preferredRate, 1.0, "rate defaults to 1.0")
        }
    }

    func testAudioSettingsRoundTrip() {
        withSavedSettings {
            AudioSettings.isAutoplayEnabled = false
            XCTAssertFalse(AudioSettings.isAutoplayEnabled)
            AudioSettings.isIntelligentTrimmingEnabled = false
            XCTAssertFalse(AudioSettings.isIntelligentTrimmingEnabled)
            AudioSettings.preferredRate = 1.5
            XCTAssertEqual(AudioSettings.preferredRate, 1.5)
        }
    }

    func testPreferredRateClampsToLegacySteps() {
        withSavedSettings {
            AudioSettings.preferredRate = 0.1
            XCTAssertEqual(AudioSettings.preferredRate, 0.8, "clamped up to the lowest step")
            AudioSettings.preferredRate = 9.9
            XCTAssertEqual(AudioSettings.preferredRate, 1.5, "clamped down to the highest step")
            AudioSettings.preferredRate = 1.34
            XCTAssertEqual(AudioSettings.preferredRate, 1.2, "snapped to the nearest step")
        }
    }

    func testRateStepsMatchTheLegacySpeechControllerSet() {
        XCTAssertEqual(AudioSettings.rateSteps, [0.8, 1.0, 1.2, 1.5])
    }
}
