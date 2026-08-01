//
//  ReaderPlaybackArbiterTests.swift
//  LunaTests
//
//  Two readers on one screen, one moving word.
//

import LunaReaderUI
import XCTest

@MainActor
final class ReaderPlaybackArbiterTests: XCTestCase {

    override func tearDown() {
        ReaderPlaybackArbiter.isPaired = false
        super.tearDown()
    }

    func testPlayingOneColumnPausesTheOther() {
        let left = PlayerSpy()
        let right = PlayerSpy()
        ReaderPlaybackArbiter.isPaired = true

        ReaderPlaybackArbiter.claim(left)
        XCTAssertEqual(right.pauseCount, 0)

        ReaderPlaybackArbiter.claim(right)
        XCTAssertEqual(left.pauseCount, 1)
        XCTAssertTrue(ReaderPlaybackArbiter.holds(right))

        ReaderPlaybackArbiter.claim(left)
        XCTAssertEqual(right.pauseCount, 1)
        XCTAssertEqual(left.pauseCount, 1, "the one being started is never paused")
    }

    func testReclaimingFromTheSameReaderPausesNothing() {
        let player = PlayerSpy()
        ReaderPlaybackArbiter.isPaired = true

        ReaderPlaybackArbiter.claim(player)
        ReaderPlaybackArbiter.claim(player)
        XCTAssertEqual(player.pauseCount, 0)
    }

    /// Luna keeps read-aloud going when you navigate away — that is what the
    /// mini-player is for. Unpaired, starting a reader must not silence whatever
    /// is already playing somewhere else.
    func testUnpairedPlaybackNeverInterruptsAnything() {
        let background = PlayerSpy()
        let opened = PlayerSpy()

        ReaderPlaybackArbiter.claim(background)
        ReaderPlaybackArbiter.claim(opened)
        XCTAssertEqual(background.pauseCount, 0)
    }

    /// Pairing enforces from the next claim on; it does not reach back and stop
    /// whatever was already playing when the second column opened.
    func testPairingEnforcesFromTheNextClaimOnward() {
        let left = PlayerSpy()
        let right = PlayerSpy()

        ReaderPlaybackArbiter.claim(left)
        ReaderPlaybackArbiter.isPaired = true
        XCTAssertEqual(left.pauseCount, 0)

        ReaderPlaybackArbiter.claim(right)
        XCTAssertEqual(left.pauseCount, 1)
    }

    /// A reader that stopped on its own must not still be able to pause its
    /// successor once a new one has claimed playback.
    func testResignOnlyClearsTheClaimItStillHolds() {
        let left = PlayerSpy()
        let right = PlayerSpy()
        ReaderPlaybackArbiter.isPaired = true

        ReaderPlaybackArbiter.claim(left)
        ReaderPlaybackArbiter.claim(right)
        ReaderPlaybackArbiter.resign(left)
        XCTAssertTrue(ReaderPlaybackArbiter.holds(right))

        ReaderPlaybackArbiter.resign(right)
        XCTAssertFalse(ReaderPlaybackArbiter.holds(right))
    }

    /// The claim is weak: a torn-down column can't keep its successor from
    /// playing, and it can't be asked to pause after it is gone.
    func testTheClaimDoesNotRetainTheReader() {
        ReaderPlaybackArbiter.isPaired = true
        autoreleasepool {
            let transient = PlayerSpy()
            ReaderPlaybackArbiter.claim(transient)
            XCTAssertTrue(ReaderPlaybackArbiter.holds(transient))
        }
        let next = PlayerSpy()
        ReaderPlaybackArbiter.claim(next)
        XCTAssertTrue(ReaderPlaybackArbiter.holds(next))
    }
}

@MainActor
private final class PlayerSpy: ReaderPlaybackPausable {
    private(set) var pauseCount = 0
    func pauseForExclusivePlayback() { pauseCount += 1 }
}
