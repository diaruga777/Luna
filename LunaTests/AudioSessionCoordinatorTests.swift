//
//  AudioSessionCoordinatorTests.swift
//  LunaTests
//

import AVFoundation
import XCTest
@testable import LunaAudioPlayback

/// `AudioSessionCoordinator`'s interruption/route-change DECISIONS, driven by
/// posting the real notification names with synthesized `userInfo` (the
/// observers filter on `object == AVAudioSession.sharedInstance()`, so these
/// run headless without ever activating a session). Actual session
/// activation/deactivation is Apple's behavior and is not asserted here.
final class AudioSessionCoordinatorTests: XCTestCase {

    private var coordinator: AudioSessionCoordinator!
    private var actions: [AudioSessionCoordinator.Action] = []

    override func setUp() {
        super.setUp()
        coordinator = AudioSessionCoordinator()
        actions = []
        coordinator.actionHandler = { [weak self] action in self?.actions.append(action) }
        coordinator.start()
    }

    override func tearDown() {
        coordinator = nil
        super.tearDown()
    }

    private func postInterruption(type: AVAudioSession.InterruptionType, options: AVAudioSession.InterruptionOptions? = nil) {
        var userInfo: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: type.rawValue]
        if let options {
            userInfo[AVAudioSessionInterruptionOptionKey] = options.rawValue
        }
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), userInfo: userInfo)
    }

    private func postRouteChange(reason: AVAudioSession.RouteChangeReason) {
        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionRouteChangeReasonKey: reason.rawValue])
    }

    func testInterruptionBeganPauses() {
        postInterruption(type: .began)
        XCTAssertEqual(actions, [.pause])
    }

    func testInterruptionEndedWithShouldResumeResumes() {
        postInterruption(type: .ended, options: .shouldResume)
        XCTAssertEqual(actions, [.resume])
    }

    func testInterruptionEndedWithoutShouldResumeDoesNotResume() {
        postInterruption(type: .ended, options: [])
        XCTAssertEqual(actions, [.none])
    }

    func testInterruptionEndedWithMissingOptionsDoesNotResume() {
        postInterruption(type: .ended)
        XCTAssertEqual(actions, [.none])
    }

    func testOldDeviceUnavailablePauses() {
        postRouteChange(reason: .oldDeviceUnavailable)
        XCTAssertEqual(actions, [.pause], "headphones unplugged -> pause")
    }

    func testNewDeviceAvailableNeverAutoResumes() {
        postRouteChange(reason: .newDeviceAvailable)
        XCTAssertEqual(actions, [], "a new route (e.g. AirPods connecting) must not auto-resume")
    }

    func testUnrelatedRouteChangeReasonsAreIgnored() {
        postRouteChange(reason: .categoryChange)
        postRouteChange(reason: .override)
        XCTAssertEqual(actions, [])
    }

    func testMalformedInterruptionUserInfoIsIgnored() {
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), userInfo: [:])
        XCTAssertEqual(actions, [])
    }

    func testStartIsIdempotent() {
        coordinator.start()
        coordinator.start()
        postInterruption(type: .began)
        XCTAssertEqual(actions, [.pause], "duplicate start() must not double-deliver")
    }
}
