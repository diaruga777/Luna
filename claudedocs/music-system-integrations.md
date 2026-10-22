# Luna Music system integrations

## Implemented

- Siri and Shortcuts: Play Library Music resolves songs, albums, artists and playlists through an `EntityStringQuery`. Individual songs use the same playlist continuation rule as the app; playlists and artists shuffle, albums play in album order. Resume, Next Song, Search Library and Resume Podcast Queue have App Shortcuts phrases. The overlapping Open Playback Queue intent and standalone Pause intent have been removed. Entity suggestions return only authorized device-library items; they never prompt from an extension.
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

The standalone `PauseMusicIntent` and its App Shortcut have been removed. Replace
the old Resume Podcast Queue → Pause sequence with a single **Resume Podcast
Queue** action with **Pause Immediately** enabled (default: off). This is suitable
for an AirPods connection automation: it leaves the podcast ready for system
Play without opening Luna Music.

Resume waits for actual playback-clock advancement and an active app-local
`MPNowPlayingSession`. With Pause Immediately enabled it also allows at least three
continuous seconds of playback, extending that window for the route's output
latency plus I/O buffer duration. Buffering resets that handoff window. The first
tick and `isActive` alone do not establish system Now Playing ownership.
AVFoundation automatically publishes transport state; Luna supplies static
metadata and artwork on the player item and retains artwork for the same episode.
Remote Play holds background execution until preparation and audio startup finish.
Remote callbacks finish dispatching to the main actor before acknowledging the
command. A prepared podcast requests AVPlayer playback synchronously in that
callback, rather than waiting for a later Task to run.
An immediate Pause cancels a queued remote Play, and newer transport actions
supersede an older pending shortcut. Natural completion during priming follows
the next queued episode and starts a fresh handoff window before pausing it.

Podcast-only launches do not create Apple's application queue player, and queue
switches pause another surface only when it is playing or buffering. In particular,
an idle Apple Music client must not receive a Pause command during podcast priming.

Verified on iOS 27.1 with real AVPlayer playback, including delayed streaming,
late artwork and resuming the same item after priming. The full hosted suite
completed 126 tests with 10 optional fixture skips and no failures before the
longer handoff window and fallback actions were added. AirPods hardware and
locked-device resumption are not verified by these
simulator checks. Transport diagnostics use the `LunaMusic` subsystem
and `PodcastPlayback` category without publishing episode titles or URLs.

Both shortcut paths are available in the same build. The single-action path uses
**Resume Podcast Queue → Pause Immediately: On** and waits for three seconds of
actual playback before pausing. To test separate invocations, use:

1. **Resume Podcast Queue → Pause Immediately: Off**
2. Shortcuts' **Wait → 1 second**
3. **Pause If Playing**
4. **Seek → Backward → 1 second**

Pause If Playing retains the original `PauseMusicIntent` identifier. It pauses
Luna's active music/podcast source only if playing or buffering. Seek uses the
same active source, accepts a nonnegative finite number of seconds, clamps to
the media bounds, and awaits seek completion without starting paused playback.
Its defaults are Backward and 1 second. All three actions run without opening
Luna Music. The extra actions also support use outside this automation.

For this revision the simulator build, generated intent metadata and 26 routing,
queue and seek checks pass. AudioQueue/HAL startup timeouts block real-audio
validation on both booted simulators (iOS 27.1 and 26.2), including the fallback
regression. Hardware resumption is not claimed as verified.

Automatic publishing follows Apple's [MPNowPlayingSession guidance](https://developer.apple.com/documentation/mediaplayer/mpnowplayingsession/automaticallypublishesnowplayinginfo):
set item metadata and let the session observe transport changes; do not also write
the session's Now Playing info center.

`ResumeLastPodcastIntent`, displayed as **Resume Podcast Queue**, resumes the exact
last-played podcast; it never redirects to generic Now Playing. Its
`overrideOtherAudio` Boolean defaults to `true`. Explicitly setting it to `false`
makes it return without changing playback when `AVAudioSession.isOtherAudioPlaying`
reports other audio. The intent type retains its identity for existing shortcuts.
Natural exhaustion of the final queued item alone allows
the chronological subscription continuation policy documented in `music.md`.
`SwitchMediaQueueIntent`, the CarPlay switch button and the shared media coordinator
preserve independent music/podcast positions. Widget transport/status follows the
active surface. CarPlay includes podcast browsing without Music authorization.
The back→forward chord is implemented for app-owned remote sessions. Apple's
application music player internally owns protected Apple Music remote events, so
that hardware direction remains unsupported by public APIs; explicit switching is
available. Real accessory/CarPlay validation and the managed CarPlay entitlement
are still required before claiming hardware compatibility.

App-owned sessions enable headphone next/previous transport and route it through
the same uptime-based chord recognizer as interval skips. Activation retries after
session eligibility changes and playback startup, so an early failed activation
does not leave the prior session receiving commands. Paused sources cannot reclaim
activation. Apple-library next/previous commands continue to be handled by Apple's
application player; queue switching while it owns remote playback still requires
the explicit switch control or shortcut.
