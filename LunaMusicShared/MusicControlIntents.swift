#if LUNA_MUSIC_APP
import LunaMusicCore
#endif
import AppIntents
import Foundation

/// AudioPlaybackIntent executes inside the containing app, including when invoked by a widget.
struct ToggleMusicPlaybackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play or Pause Music"
    static var description = IntentDescription("Play or pause the current Luna Music queue.")
    @MainActor func perform() async throws -> some IntentResult {
        #if LUNA_MUSIC_APP
        try await MediaPlaybackCoordinator.shared.toggle()
        #endif
        return .result()
    }
}

struct NextMusicTrackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Next Track or Episode"
    static var description = IntentDescription("Skip to the next song or podcast episode in the current Luna Music queue.")
    @MainActor func perform() async throws -> some IntentResult {
        #if LUNA_MUSIC_APP
        MediaPlaybackCoordinator.shared.skip(.forward)
        #endif
        return .result()
    }
}

struct PreviousMusicTrackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Previous Track or Episode"
    static var description = IntentDescription("Go back to the previous song or podcast episode in the current Luna Music queue.")
    @MainActor func perform() async throws -> some IntentResult {
        #if LUNA_MUSIC_APP
        MediaPlaybackCoordinator.shared.skip(.backward)
        #endif
        return .result()
    }
}
