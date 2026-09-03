//
//  ReadAlongAvailabilityTests.swift
//  LunaTests
//

import XCTest
@testable import LunaWriterReadAlong
@testable import LunaWriterVoice

final class ReadAlongAvailabilityTests: XCTestCase {

    func testVoiceIsAvailableWhenTheTranscriberIs() {
        let transcriber = FakeSpeechTranscriber()
        transcriber.isAvailable = true
        transcriber.unavailabilityReason = nil
        let availability = ReadAlongAvailability.resolve(transcriber: transcriber)
        XCTAssertTrue(availability.voice)
        XCTAssertNil(availability.voiceReason)
        XCTAssertFalse(availability.voiceIsUnasked)
    }

    /// #12: permission-not-asked must read as distinct from a hard no — the
    /// caller can still offer the toggle and ask.
    func testVoiceIsUnaskedWhenPermissionHasNeverBeenRequested() {
        let transcriber = FakeSpeechTranscriber()
        transcriber.isAvailable = false
        transcriber.unavailabilityReason = .permissionNotRequested
        let availability = ReadAlongAvailability.resolve(transcriber: transcriber)
        XCTAssertFalse(availability.voice)
        XCTAssertEqual(availability.voiceReason, .permissionNotRequested)
        XCTAssertTrue(availability.voiceIsUnasked)
    }

    func testAHardNoIsNotReportedAsUnasked() {
        for reason: SpeechUnavailability in [.permissionDenied, .microphoneDenied, .noOnDeviceModel, .unsupported] {
            let transcriber = FakeSpeechTranscriber()
            transcriber.isAvailable = false
            transcriber.unavailabilityReason = reason
            let availability = ReadAlongAvailability.resolve(transcriber: transcriber)
            XCTAssertFalse(
                availability.voiceIsUnasked, "\(reason) is a hard no, not merely unasked")
        }
    }

    /// `resolve` is callable again after the answer changes — nothing is
    /// cached at rest, so a stub whose `isAvailable` flips after an
    /// authorization prompt returns a current answer on the next call.
    func testResolveReflectsAStubThatFlipsAvailableAfterAuthorization() {
        let transcriber = FakeSpeechTranscriber()
        transcriber.isAvailable = false
        transcriber.unavailabilityReason = .permissionNotRequested

        let before = ReadAlongAvailability.resolve(transcriber: transcriber)
        XCTAssertFalse(before.voice)
        XCTAssertTrue(before.voiceIsUnasked)

        // The user granted the permission the prompt asked for.
        transcriber.isAvailable = true
        transcriber.unavailabilityReason = nil

        let after = ReadAlongAvailability.resolve(transcriber: transcriber)
        XCTAssertTrue(after.voice)
        XCTAssertNil(after.voiceReason)
    }

    func testANilTranscriberIsUnavailableWithNoReasonGiven() {
        let availability = ReadAlongAvailability.resolve(transcriber: nil)
        XCTAssertFalse(availability.voice)
        XCTAssertEqual(availability.voiceReason, .unsupported)
        XCTAssertFalse(availability.voiceIsUnasked)
    }
}
