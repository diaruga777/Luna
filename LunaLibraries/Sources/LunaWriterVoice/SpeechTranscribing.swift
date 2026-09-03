import Foundation

/// Why a `SpeechTranscribing` cannot run right now.
public enum SpeechUnavailability: Equatable, Sendable {
    /// The recognizer has no on-device model for the requested locale.
    case noOnDeviceModel
    /// Speech-recognition or microphone authorization has never been asked —
    /// distinct from `.permissionDenied`/`.microphoneDenied`: a caller can
    /// still turn this on by asking, and availability should be re-resolved
    /// once the answer comes back.
    case permissionNotRequested
    /// Speech-recognition authorization was denied.
    case permissionDenied
    /// Microphone authorization was denied.
    case microphoneDenied
    /// This engine cannot run in this process or on this OS version.
    case unsupported
}

/// Thrown by `start()` when a transcriber cannot begin capturing.
public enum SpeechTranscribingError: Error, Equatable, Sendable {
    case unavailable(SpeechUnavailability)
}

/// The reader of a `SpeechTranscribing`'s events.
public protocol SpeechTranscribingDelegate: AnyObject {
    /// Speech has started — the caller should snapshot whatever it wants to
    /// anchor the eventual utterance to, since ASR text has not arrived yet.
    func speechDidDetectOnset()
    /// One finished utterance's transcript. Empty text means the segment
    /// closed with nothing usable in it.
    func speechDidFinishUtterance(_ text: String)
}

/// A source of transcribed speech. Callers talk to this rather than to
/// `SFSpeechRecognizer` or `SpeechAnalyzer` directly, so the OS-version
/// switch (`SpeechTranscriberFactory`) and test stubs both stay behind one
/// seam.
public protocol SpeechTranscribing: AnyObject {
    var delegate: SpeechTranscribingDelegate? { get set }
    /// Whether this engine can run right now, on this device and locale.
    var isAvailable: Bool { get }
    /// Why `isAvailable` is false; `nil` while it is true.
    var unavailabilityReason: SpeechUnavailability? { get }
    /// Starts capturing the microphone and transcribing. Throws rather than
    /// starting partially when a precondition (on-device model, permissions)
    /// fails closed.
    func start() throws
    /// Stops capture and releases the audio session. Safe to call when not
    /// running.
    func stop()
}
