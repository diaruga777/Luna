# Luna Music system integrations

## Implemented

- Siri and Shortcuts: Play Library Music resolves songs, albums, artists and playlists through an `EntityStringQuery`. Individual songs use the same playlist continuation rule as the app; playlists and artists shuffle, albums play in album order. Pause, Resume, Next Song, Search Library and Open Playback Queue have App Shortcuts phrases. Entity suggestions return only authorized device-library items; they never prompt from an extension.
- Lock Screen, Control Center media transport, headphones and the system Dynamic Island Now Playing surface belong to `MPMusicPlayerController.applicationQueuePlayer`. Luna does not overwrite `MPNowPlayingInfoCenter` or add duplicate remote command handlers.
- Luna does not create a separate playback Live Activity. At launch it dismisses queue activities left by older builds, leaving the system media controls as the playback surface.
- Home Screen small/medium and Lock Screen circular/rectangular widgets open library search or the queue. Home Screen widgets include playback controls. Control Center has Play/Pause and Next Song controls.
- Shared `AudioPlaybackIntent` types execute in the containing app process, allowing widget controls to call the real playback controller. The app target defines `LUNA_MUSIC_APP`; both targets compile `LunaMusicShared`.
- The CarPlay audio scene browses playlists, albums, artists, songs and downloaded songs with CarPlay list templates. Song selection uses the same queue policy as the phone; CarPlay presents its shared system Now Playing template. Library authorization must be completed on iPhone first.

## Lifecycle and freshness

`MusicSystemIntegration.shared.start()` observes playback and foreground changes and coalesces widget snapshot writes. It ends Live Activities from older builds once at launch. System Now Playing remains responsible for live playback controls.

Widget snapshots are written atomically to `music-widget.json` in the configured App Group. Timelines include a future empty entry at snapshot expiration, so they do not continue presenting an old track as currently playing. Paused snapshots expire after a day. WidgetKit decides when reload requests are serviced. No library contents are exported beyond the small current-playback snapshot.

App Intent deep links use `MusicIntentRoute.pendingURL` for cold-start delivery and `.lunaMusicOpenQueue` / `.lunaMusicOpenSearch` notifications for an existing scene. Search text is a URL-encoded `q` parameter. The scene consumes and clears the pending URL.

## Public API boundaries and validation

This is a public-API library client, so exact Apple Music parity is not a supportable guarantee. Native Now Playing is supplied by iOS; Luna supplies its own library and queue views. No catalog subscription offers, radio or advertising are added.

- CarPlay's browsable audio-app UI requires Apple's approved `com.apple.developer.carplay-audio` managed entitlement. The scene and entitlement declaration are present in the project; Apple must grant the capability and a new distribution provisioning profile before a signed release can use it.
- Live synchronized Apple Music lyrics, Apple Music Sing, Apple's private crossfade/AutoMix UI and collaborative-listening experiences are not implemented. `Song.hasLyrics` only reports availability; it does not supply synchronized lyric text. MediaPlayer has no app-specific crossfade control here.
- AirPlay routing and system volume are exposed using platform controls in the app. This app does not implement independent watchOS, tvOS, visionOS, iMessage or SharePlay companions.
- App Shortcut invocation, actual library playback, Lock Screen/Dynamic Island presentation and background transitions require a signed physical-device run with a populated music library. Simulator compilation does not verify those runtime capabilities. No WebDriverAgent workflow is used.

Verified: shared/widget sources and app integration sources typecheck against the iOS 26.2 SDK; widget and app plists validate. The current simulator app/widget build passes, along with 17 unit tests and 3 UI tests. Populated-library playback and CarPlay display checks remain outstanding.

## Apple references

- [AudioPlaybackIntent](https://developer.apple.com/documentation/appintents/audioplaybackintent)
- [Interactive widgets](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities)
- [Creating controls](https://developer.apple.com/documentation/widgetkit/creating-controls-to-perform-actions-across-the-system)
- [CarPlay entitlement approval](https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements)
- [Song.hasLyrics](https://developer.apple.com/documentation/musickit/song/haslyrics)

## Podcast integration (2026-10-08)

`ResumeLastPodcastIntent` resumes the exact last-played podcast; it never redirects
to generic Now Playing. Natural exhaustion of the final queued item alone allows
the chronological subscription continuation policy documented in `music.md`.
`SwitchMediaQueueIntent`, the CarPlay switch button and the shared media coordinator
preserve independent music/podcast positions. Widget transport/status follows the
active surface. CarPlay includes podcast browsing without Music authorization.
The back→forward chord is implemented for app-owned remote sessions. Apple's
application music player internally owns protected Apple Music remote events, so
that hardware direction remains unsupported by public APIs; explicit switching is
available. Real accessory/CarPlay validation and the managed CarPlay entitlement
are still required before claiming hardware compatibility.
