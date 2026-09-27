# Luna Music system integrations

## Implemented

- Siri and Shortcuts: Play Library Music resolves songs, albums, artists and playlists through an `EntityStringQuery`. Individual songs use the same playlist continuation rule as the app; playlists and artists shuffle, albums play in album order. Pause, Resume, Next Song, Search Library and Open Playback Queue have App Shortcuts phrases. Entity suggestions return only authorized device-library items; they never prompt from an extension.
- Lock Screen, Control Center media transport, headphones and the system Dynamic Island Now Playing surface belong to `MPMusicPlayerController.applicationQueuePlayer`. Luna does not overwrite `MPNowPlayingInfoCenter` or add duplicate remote command handlers.
- A separate ActivityKit queue activity shows the current item, next song, playback progress and transport buttons. Its URL is `lunamusic://queue`; the scene preserves that destination instead of focusing search. This supplements the system media surface.
- Home Screen small/medium and Lock Screen circular/rectangular widgets open library search or the queue. Home Screen widgets include playback controls. Control Center has Play/Pause and Next Song controls.
- Shared `AudioPlaybackIntent` types execute in the containing app process, allowing widget/activity controls to call the real playback controller. The app target defines `LUNA_MUSIC_APP`; both targets compile `LunaMusicShared`.

## Lifecycle and freshness

`MusicSystemIntegration.shared.start()` observes playback and foreground changes. A single task serializes activity updates and coalesces pending changes. Starting an activity requires an active app and the user's ActivityKit authorization. Existing activities from a terminated app are ended before starting the current session. No current song ends all previous queue activities immediately.

The activity expires its current content at the expected track end plus 15 seconds (at least 30 seconds from the update), or after five minutes while paused. Stale activity layouts replace song/artist details with a queue refresh prompt and hide next-song, progress and playback buttons. System Now Playing remains responsible for live playback controls. An app using the system music player may be suspended even while playback continues; ActivityKit updates cannot be guaranteed during that suspension. There is no server or push-update workaround. Activities are reconciled when the process next runs; ActivityKit controls their ultimate lifetime while it does not.

Widget snapshots are written atomically to `music-widget.json` in the configured App Group. Timelines include a future empty entry at snapshot expiration, so they do not continue presenting an old track as currently playing. Paused snapshots expire after a day. WidgetKit decides when reload requests are serviced. No library contents are exported beyond the small current-playback snapshot.

App Intent deep links use `MusicIntentRoute.pendingURL` for cold-start delivery and `.lunaMusicOpenQueue` / `.lunaMusicOpenSearch` notifications for an existing scene. Search text is a URL-encoded `q` parameter. The scene consumes and clears the pending URL.

## Public API boundaries and validation

This is a public-API library client, so exact Apple Music parity is not a supportable guarantee. Native Now Playing is supplied by iOS; Luna supplies its own library and queue views. No catalog subscription offers, radio or advertising are added.

- CarPlay's browsable audio-app UI requires Apple's approved `com.apple.developer.carplay-audio` entitlement and CarPlay scenes. That entitlement and UI are not enabled here. Ordinary system playback routing remains available.
- Live synchronized Apple Music lyrics, Apple Music Sing, Apple's private crossfade/AutoMix UI and collaborative-listening experiences are not implemented. `Song.hasLyrics` only reports availability; it does not supply synchronized lyric text. MediaPlayer has no app-specific crossfade control here.
- AirPlay routing and system volume are exposed using platform controls in the app. This app does not implement independent watchOS, tvOS, visionOS, iMessage or SharePlay companions.
- App Shortcut invocation, actual library playback, Lock Screen/Dynamic Island presentation and background transitions require a signed physical-device run with a populated music library. Simulator compilation does not verify those runtime capabilities. No WebDriverAgent workflow is used.

Verified: shared/widget sources and app integration sources typecheck against the iOS 26.2 SDK; widget plist and entitlements validate. Full simulator app/widget build and 19 unit/UI tests pass; populated-library device checks remain outstanding.

## Apple references

- [AudioPlaybackIntent](https://developer.apple.com/documentation/appintents/audioplaybackintent)
- [Interactive widgets and Live Activities](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities)
- [Displaying live data with Live Activities](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)
- [Activity updates](https://developer.apple.com/documentation/activitykit/activity/update(_:))
- [Creating controls](https://developer.apple.com/documentation/widgetkit/creating-controls-to-perform-actions-across-the-system)
- [CarPlay entitlement approval](https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements)
- [Song.hasLyrics](https://developer.apple.com/documentation/musickit/song/haslyrics)
