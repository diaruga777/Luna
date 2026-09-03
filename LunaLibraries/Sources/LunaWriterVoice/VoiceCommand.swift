import Foundation

/// A spoken instruction recognized in a transcript, or a free-form remark
/// when no instruction phrase matches. The caller maps `.needsWork` /
/// `.expand` / `.cut` / `.keep` onto its own annotation kind and stores a
/// `.comment`'s text as a note.
public enum VoiceCommand: Equatable, Sendable {
    case needsWork
    case expand
    case cut
    case keep
    case comment(String)
}
