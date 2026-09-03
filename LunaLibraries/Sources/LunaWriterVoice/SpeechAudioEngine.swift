//
//  SpeechAudioEngine.swift
//  LunaWriterVoice
//

import AVFoundation
import Foundation
import Speech

/// The one precondition check both transcribers run — speech-recognition
/// authorization, then microphone authorization, matching the order
/// `VoicePermissions.request` asks in — so a locale/model check is the only
/// way their `unavailabilityReason`s can still disagree.
enum SpeechPermissionCheck {
    enum Override {
        case available
        case unavailable(SpeechUnavailability)
    }

    /// Test seam, mirroring `GazeTrackingPermission.statusOverride`. `nil`
    /// (the default) means "ask the device" — the real authorization APIs
    /// have no test double, and a unit test cannot grant them.
    static var testOverride: Override?

    static func unavailability() -> SpeechUnavailability? {
        if let testOverride {
            switch testOverride {
            case .available: return nil
            case .unavailable(let reason): return reason
            }
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: break
        case .notDetermined: return .permissionNotRequested
        case .denied, .restricted: return .permissionDenied
        @unknown default: return .permissionNotRequested
        }
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return nil
        case .undetermined: return .permissionNotRequested
        case .denied: return .microphoneDenied
        @unknown default: return .permissionNotRequested
        }
    }
}

/// The slice of `AVAudioEngine` a transcriber depends on, seamed so a test can
/// drive a tap callback and an interruption without real audio hardware.
public protocol SpeechAudioEngine: AnyObject {
    var isRunning: Bool { get }
    var inputFormat: AVAudioFormat { get }
    func installTap(bufferSize: AVAudioFrameCount, block: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void)
    func removeTap()
    func prepare()
    func start() throws
    func stop()
    func pause()
}

/// Wraps a real `AVAudioEngine`.
public final class SystemSpeechAudioEngine: SpeechAudioEngine {
    private let engine = AVAudioEngine()

    public init() {}

    public var isRunning: Bool { engine.isRunning }
    public var inputFormat: AVAudioFormat { engine.inputNode.outputFormat(forBus: 0) }

    public func installTap(
        bufferSize: AVAudioFrameCount, block: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) {
        engine.inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat, block: block)
    }

    public func removeTap() { engine.inputNode.removeTap(onBus: 0) }
    public func prepare() { engine.prepare() }
    public func start() throws { try engine.start() }
    public func stop() { engine.stop() }
    public func pause() { engine.pause() }

    /// The real engine, for observing `.AVAudioEngineConfigurationChange` —
    /// the notification is posted with the engine as its object.
    public var underlyingEngine: AVAudioEngine { engine }
}

/// Converts an `AVAudioTime`'s host-time stamp into `Date`, anchored to a
/// captured host-time/date pair — steadier than reading `Date()` fresh inside
/// a render-thread callback that may run slightly late.
public struct AudioClockReference {
    private var hostTime: UInt64
    private var date: Date

    public init(date: Date = Date(), hostTime: UInt64 = mach_absolute_time()) {
        self.date = date
        self.hostTime = hostTime
    }

    public mutating func reset(date: Date = Date(), hostTime: UInt64 = mach_absolute_time()) {
        self.date = date
        self.hostTime = hostTime
    }

    public func date(for time: AVAudioTime) -> Date {
        guard time.isHostTimeValid else { return Date() }
        let elapsed = AVAudioTime.seconds(forHostTime: time.hostTime)
            - AVAudioTime.seconds(forHostTime: hostTime)
        return date.addingTimeInterval(elapsed)
    }
}
