import AVFoundation
import Foundation
import Speech

/// Microphone and speech-recognition authorization. Neither is requested at
/// launch — a caller asks only at the moment the user turns voice commands
/// on, so the system prompt arrives with the feature it is for.
public enum VoicePermissions {

    public enum MicrophoneStatus: Equatable, Sendable { case granted, denied, undetermined }
    public enum SpeechStatus: Equatable, Sendable { case granted, denied, restricted, undetermined }

    public struct Status: Equatable, Sendable {
        public let microphone: MicrophoneStatus
        public let speech: SpeechStatus

        public init(microphone: MicrophoneStatus, speech: SpeechStatus) {
            self.microphone = microphone
            self.speech = speech
        }

        public var isGranted: Bool { microphone == .granted && speech == .granted }
    }

    public static var status: Status {
        Status(microphone: microphoneStatus, speech: speechStatus)
    }

    /// Requests microphone access, then speech-recognition access, and
    /// reports the combined result on the main queue. Skips a request that
    /// has already been answered — iOS asks a permission only once.
    public static func request(_ completion: @escaping (Status) -> Void) {
        AVAudioApplication.requestRecordPermission { _ in
            SFSpeechRecognizer.requestAuthorization { _ in
                DispatchQueue.main.async { completion(status) }
            }
        }
    }

    private static var microphoneStatus: MicrophoneStatus {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .undetermined
        @unknown default: return .undetermined
        }
    }

    private static var speechStatus: SpeechStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .undetermined
        @unknown default: return .undetermined
        }
    }
}
