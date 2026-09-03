import Foundation

/// Picks the transcriber for the running OS: `SpeechAnalyzerTranscriber` on
/// iOS 26 and later, `SFSpeechTranscriber` otherwise.
public enum SpeechTranscriberFactory {
    public static func make(locale: Locale = .current) -> SpeechTranscribing {
        if #available(iOS 26, *) {
            return SpeechAnalyzerTranscriber(locale: locale)
        }
        return SFSpeechTranscriber(locale: locale)
    }
}
