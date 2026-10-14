# Luna Music

Standalone iOS 26 player: scheme `LunaMusic`, bundle ID
`$(PRODUCT_BUNDLE_PREFIX).music`, app module `LunaMusicApp`. Apple library songs
and Luna Vault files coexist in the same songs, artists, albums and search views. Music uses its own library state; it does not use `saves.sqlite`.
The app links `LunaMusicKit` plus the existing Vault connection/pairing services.

## Library and playback

MusicKit authorizes Apple music access and MediaPlayer queries the synced/local
Apple library. Apple-only queues retain `applicationQueuePlayer` and its system
playback behavior. Denying Apple access does not prevent Vault browsing/playback.
`MusicSong`, `MusicPlaylist` and source-qualified `MusicID` values keep Apple IDs
separate from Mac paths. Artist strings are matched case/diacritic-insensitively;
albums match title plus album artist. Songs from different sources remain distinct.

Playlists have exactly one source. New Playlist asks for Apple Music or Luna Vault;
creation from a song inherits its source. Add Music and destination menus filter
by source, and the underlying write APIs reject mixed-source changes. Vault
playlists, ordering, play counts and catalog metadata persist atomically in
`Application Support/LunaMusic/vault-library.json` in the Music app container.
Vault playlists can be created, populated, have songs removed, and be deleted
without modifying the original files on the Mac. Apple playlists still use the
public media-library APIs and surface write failures.

Selecting a song plays it first, then shuffles its most recently successfully
played containing playlist, excluding Smart/Genius playlists. With no history,
the largest containing playlist wins, with stable ID ties. Explicit collection
Play/Shuffle uses that collection. Artist/album queues may span both sources;
playlists cannot. Queue editing, seeking, shuffle, repeat and the same compact/full
player work for both sources. Queue snapshots preserve source-qualified identities
and restore paused; legacy numeric Apple queue IDs still decode.

Vault tracks use AVPlayer: downloaded files play directly, and uncached files use
`AVAssetResourceLoader` over the paired Mac connection. Ranges are 512 KiB, verified
against the Mac's file version before/after reading, deduplicated in flight and
retained in a 12 MiB LRU. Startup primes up to 1 MiB. AVFoundation can request the
end of an MP4 before the beginning and seek without a sequential full download.
Transient range failures retry twice with backoff; deadlines/reconnects come from
BEP. Superseded AVFoundation requests are cancelled. A changed file fails cleanly
instead of mixing versions; refresh the library before retrying that song.
Custom loaders disable Apple's network-rate predictor; the player maintains a
20-second forward-buffer preference and resumes a requested playback after a stall
when at least three seconds (or the remaining track) are buffered.
An AVPlayer-associated Now Playing session owns Vault metadata/remote commands;
Apple playback uses MediaPlayer's session. Audio interruptions and unplugged
routes pause appropriately. Metadata feeds the existing widgets and CarPlay/Siri.

## Mac folder and supported formats

Inside the selected Mac Vault root, place files under
`Music/<Artist>/<Album>/<file>`. Luna Mac creates Music at startup. Metadata tags
supply title/artist/album/track/disc with directory and filename fallbacks. The Mac
scans on catalog requests (at most once per 15 seconds per connection); the iPhone
refreshes on foreground, manually, and every minute while foregrounded. Unchanged
files reuse metadata persisted in `.luna-music-index.json`. No transcoding runs.
Supported extensions are MP3, M4A, MP4, AAC, WAV, AIF/AIFF, CAF and FLAC, provided
AVFoundation finds playable audio. MP4 video containers contribute their audio.
Symbolic links and paths escaping Music are rejected. Reads use the existing paired
TLS/BEP connection, including LAN or the user's separately installed Tailscale.
Both the app and Mac companion must be updated for the music service.

## Downloads

The Library root lists Playlists, Artists, Albums, Songs and **Podcasts**, all in one
navigation stack. There is no tab bar or separate Downloaded root destination.
**Downloaded** is a checked filter in the root search menu and every music list's
filter/sort menu, including playlist options and Add Music. It combines with search,
shows artists/albums/playlists with at least one local track, and carries into opened
collections. Turning it off restores the complete list without changing the library.
Apple tracks use MediaPlayer's local/cloud status; Vault tracks require a complete
current-version cache. Play/Shuffle and song-start playlist continuation respect the
filter, so a filtered list does not enqueue remote tracks. Playback queues themselves
remain intact and show their actual contents.

Song menus and collection download buttons cache Vault songs individually or by
playlist, artist, or album. Files live in the Music app's private
`Application Support/LunaMusic/Audio` directory, excluded from backup, with complete
files installed atomically after all ranges arrive. Temporary partials are removed
on failure/cancellation and next startup. Cache filenames include source identity
and file version; truncated/obsolete copies cannot masquerade as the current song.

Settings lists cached songs and size; swipe to remove a local download. This never
sends a delete or tombstone to the Mac. A removed song is excluded from automatic
re-download until the user explicitly downloads it again. Automatic caching defaults
to the top **3** played Vault playlists, configurable from **0 to 10**. Ranking uses
successful playlist starts, then recency and ID. Never-played playlists are excluded.
Reconciliation removes obsolete automatic copies and retains manual downloads.
Downloads are serialized and can be retried in Settings; offline refresh failures
preserve the last catalog and playlists. iOS may suspend optional downloads when
backgrounded without active audio; retry/foreground refresh resumes the policy.

## Foreground behavior

`MusicSceneDelegate` focuses a cleared library search at cold launch and every
return from background while browsing music. Podcast browsing stays open on return
and is restored on cold launch; the former Podcasts tab preference migrates to this
navigation state. Explicit search links return to the Library, and podcast episode/queue
routes open Podcasts within the same stack. Permission alerts and transient inactive states do not
reset navigation. An incoming `lunamusic://queue` URL takes precedence and opens
the queue without the keyboard; `lunamusic://search?q=…` supplies a query. App
Intent routes are retained until a cold-start scene has installed observers.

## System surfaces

See [music-system-integrations.md](music-system-integrations.md) for Siri,
Shortcuts, widgets, Control Center and CarPlay. The app and
widget use the family App Group for a small, separate music state snapshot.

The UI uses native UIKit navigation search, sheets, controls and iOS 26 Liquid
Glass for floating playback controls. The compact 48-point mini player opens the full-screen player with
UIKit's interactive zoom transition; artwork changes use a brief dissolve.
List typography, artwork sizes, collection headers and search typography follow
the supplied Apple Music references while retaining Dynamic Type.

Now Playing reserves the bottom of the screen for seeking, transport, system
volume and AirPlay. Artwork fits the remaining space; playback controls never
scroll away. In landscape, artwork/queue and playback controls occupy separate
columns. The queue button or an upward drag over the artwork reveals the queue:
artwork and track labels move into its compact header with an interruptible spring.
The queue scrolls independently. Tap the queue button again or pull down on the
queue header to restore artwork. Shuffle and repeat have filled selected states,
VoiceOver values, and a distinct repeat-one symbol. Queue rows retain reordering;
long-press a row to remove it. The top grabber is also an accessible close button.
Transitions honor Reduce Motion (queue switches immediately and the full-screen
player uses the system's standard modal presentation). Apple Music's private UI,
catalog lyrics, Sing, AutoMix and download-management interfaces are not
available through this implementation. CarPlay has a separate template scene
for browsing the device library and uses the system Now Playing template.
Distribution requires Apple to grant the `com.apple.developer.carplay-audio`
managed entitlement to the app's signing profile.
Apple playback controls are owned by MediaPlayer; Vault playback uses its AVPlayer Now Playing session. There is no standalone
watchOS app or independent Apple Watch library.

## Development

- Run `ruby scripts/add_luna_music_app.rb` after adding app, widget, shared or
  test Swift files; package source files are discovered automatically.
- `LunaMusic` scheme tests queue policy and URL routes; `LunaMusicUI` scheme
  runs focused XCUITests for cold/resume search and queue-link routing.
- Use normal simulator signing. Do not strip App Group entitlements.
- The native icon source is `Design/IconComposer/Luna Music.icon`; it extends
  the family's existing moon/glass artwork with a music note. Export using
  Xcode 27 Icon Composer, then use `scripts/export_music_icon.swift` to generate
  the opaque 1024px asset for stable Xcode 26 builds.
- Simulator tests cannot validate a signed-in device library, protected cloud
  playback, AirPods, AirPlay, or Siri speech recognition. Verify these on an
  authorized device before distributing the app. Never use WebDriverAgent on
  the user's phone.

## Verification (2026-09-27)

Stable Xcode 26.2 build and simulator launch succeeded on iPhone 17 Pro / iOS
26.2. All 16 unit tests and all 3 UI tests passed. UI tests exercise keyboard
focus on cold launch, clearing/refocusing search on foreground, and queue deep
links on warm and cold launches. A screenshot confirmed the library categories,
search field, keyboard and mini player. Real-device music playback and system
surfaces still require the populated-library checks described above.

The follow-up build passes with the CarPlay scene and Liquid Glass controls.
The revised song-queue policy has a regression test for automatic playlists;
all 17 Music unit tests and 3 UI tests passed on the iOS 26.2 simulator.
CarPlay template interaction and real-library queue membership still need a
CarPlay simulator or authorized device with a populated music library.

The UX polish passes all 17 Music unit tests and 4 UI tests on iPhone 17 Pro /
iOS 26.2. The added UI test verifies queue-button and upward-drag navigation,
shuffle/repeat selection values, unchanged transport position across the
transition, and player dismissal. Search focus and warm/cold queue routes still
pass. Simulator screenshots were reviewed against the supplied references;
MPVolumeView does not expose a working volume slider on Simulator, so actual
volume output and populated-library artwork remain device checks.

## Screenshot polish (2026-09-29)

Artist, album, playlist and category screens have native pull-down search. A
query filters only the current collection and clearing it restores the header.
Artist grids show album years. Playlists build a four-cover mosaic when four
distinct album artworks are available and use an artwork-derived background.
The collection title appears in the navigation bar after its header scrolls away.

Playlists expose **Add Music** in the header and overflow menu. The sheet searches
library songs and preserves multiple selections across searches. Add submits the
selection through `MPMediaPlaylist.add`; failures retain the selection and show
an error. A successful edit reloads the open playlist. Creating a playlist opens
its detail screen, and song menus also offer New Playlist. Smart/Genius playlists
are excluded from song-menu destinations; other API write failures are surfaced.

The mini player grows to fit Dynamic Type and reserves separate 44-point play
and skip targets. Queue layout uses untransformed frames so repeated layout and
queue transitions cannot shift mode buttons over the compact song header. Rows
size to their text, empty collection messages follow the header, and the player
uses smaller paused artwork, a song menu, a subdued artwork color and audio-output
name. Search uses the native text size instead of an oversized custom field font.

Verification: Xcode 26.2 / iPhone 17 Pro / iOS 26.2. The 22 unit/layout tests cover
queue policy, large-text mini-player bounds and hit targets, repeated queue
layout, empty playlist geometry, collection search and multi-selection across
searches. All 4 foreground/queue UI tests pass. Layout tests use in-memory media
snapshots and do not write the real library. Real playlist writes, populated
library artwork, volume and audio routes still require a signed-in device check.

## Vault music verification (2026-10-07)

Xcode 26.2 / iPhone 17 Pro / iOS 26.2: all 31 Music unit/layout/playback tests
pass. Coverage includes shared artist/album grouping, source guards, persisted
Vault playlists and cache policy, manual pins and explicit removals, deduplicated
ranges, version isolation, cancelled/incomplete downloads, and queue transport.
A generated three-minute MP4 starts through the production resource loader before
the complete file arrives over a throttled test transport, supports a seek near
the end, and produces a byte-identical cache that decodes with the server offline.
The simulator's audio-output restart can time out; offline validation therefore
uses AVAssetReader decoding rather than relying on simulated speaker output.

The seven Mac music tests pass, covering catalog discovery, metadata fallbacks,
pagination, source identity, cache policy, path restrictions and
version-checked range reads. The full LunaVaultMacCompanion product builds.
A physical iPhone paired to Luna Mac over LAN/Tailscale, signed-in Apple playback,
source transitions on a populated library, AirPlay, and Siri still require device
validation before distribution.

All five Music UI checks pass (the four existing checks in the full run, then
the new focused check after correcting its iOS 26 search-dismiss button label).
The new check exercises Settings, both policy limits, restoring the default of
three, choosing the playlist source, and creating/deleting a Vault playlist.
The settings screenshot was inspected for layout and readable controls.

## Podcasts (2026-10-08)

Podcasts opens from the Library root alongside the music categories. Music and
Podcasts retain independent queues.
The Podcasts surface includes Home (continue/latest/recent), New (public directory
charts and categories), Library (followed shows/latest/saved/downloaded/played,
custom stations and favorite categories), and show/episode/library search.
Apple's public iTunes directory supplies discovery; publisher RSS/Atom feeds
supply the episodes. A URL entry point accepts private or public feed addresses.
Podcast access does not depend on Apple Music authorization.

`LunaPodcastCore` contains Foundation-only models, namespace-aware RSS parsing,
transcript/OPML parsing, atomic persistence, merge policy and continuation/gesture
rules. `LunaMusicCore` owns the runtime services and `LunaMusicUI` owns UIKit views.
State lives in `Application Support/LunaMusic/Podcasts/library.json`, independently
of `saves.sqlite` and the music queue. Corrupt/unknown-version libraries report an
error instead of replacing the user's file. Feed refresh preserves removed archive
episodes, listening history and per-show settings. Conditional requests use ETag
and Last-Modified. Followed feeds poll on foreground and every 15 foreground
minutes, with opportunistic BGAppRefreshTask polling while backgrounded; iOS does
not promise a polling interval. Notification opt-in is per show.

Streaming uses AVPlayer with a spoken-audio session, elapsed-time checkpoints,
interruption/route handling, lock-screen metadata, remote commands and AirPlay.
Native playback exposes configurable back/forward intervals (15/30 seconds by
default), speed 0.5–3×, time seeking, sleep timers including end-of-episode, volume,
video/Picture in Picture, publisher chapters (RSS, JSON or embedded metadata), and
publisher VTT/SRT/TTML/JSON/plain-text transcripts with search and timed seeking.
Saved episodes, manual played/unplayed changes, share, Play Next, Add to Queue,
queue reordering/removal/clear are available. The podcast player uses a dark,
artwork-colored background and grabber dismissal. Its upper stage animates vertically
between full artwork/date/title/show and a compact current-episode header plus queue;
the timeline, five transport buttons (speed, back, play, forward, sleep), volume
with speaker icons, and transcript/AirPlay/queue row stay fixed. Long current titles
scroll behind a trailing fade (truncate with Reduce Motion); queue titles and
date/duration metadata occupy one line each, without descriptions or a delete
column. Drag handles reorder; long-press menus and VoiceOver actions remove queue
items. Chapters and the Music queue switch live in the current episode menu. A single episode
never adds the rest of its show: the queue contains only explicit selections and
shows an empty state when exhausted. Legacy automatic continuation lists are
discarded on load without changing explicit queue entries or listening history. Stations select followed shows, count, order, played state and media type.


Podcast player layout verification (2026-10-13): 49 Music hosted tests passed,
with three optional streaming-fixture tests skipped. Layout regressions cover
long titles, compact queue rows, fixed playback controls across queue toggles,
320-point portrait, landscape, larger text, queue removal/clear, and preserving
queue mode across Music/Podcasts switches. The local-fixture UI test passed for
playback, episode menus, both queue modes, adding and long-press removing an item,
and dismissal. Simulator tap/swipe checks also verified the vertical artwork/queue
transition and grabber dismissal. MPVolumeView's actual volume track is supplied
by iOS on device; the simulator exposes no system volume slider.

Downloads use background URLSession tasks, with AVAssetDownloadURLSession for HLS.
The persisted manifest reconnects tasks across launches and reports interrupted or
failed downloads for retry. Completed ordinary files are installed atomically and
checked against the manifest size before playback. HLS locations remain where
AVFoundation installs them. The cache is excluded from backup. Settings cover
cellular streaming/downloads, per-show automatic limits, saved-episode downloads,
a download byte cap (2 GB by default; 500 MB, 1/2/5/10 GB choices), played-file
retention for manually marked episodes and storage removal. The current/paused
episode and explicitly queued episodes download first, in playback order, ahead
of manual, saved and per-show automatic requests. Queue edits and launch reconcile
immediately, independently of feed refresh. Downloads run one at a time; unknown
sizes reserve the remaining budget until measured, and the first episode that
cannot fit stops the queue prefix. Queue reordering evicts lower-priority files
and preempts lower-priority transfers. Actual response/file sizes enforce the cap,
including underreported RSS enclosures; HLS packages are measured before retention.
Lowering the cap preserves an asset still open in AVPlayer until it is released.
A paused streaming item switches to its completed local copy on resume. Natural
completion always releases and deletes that episode's download, even for saved
or manual downloads and sleep-at-episode-end, then refills the queue within the
cap. Completed saved episodes do not automatically download again. Explicit
deletion suppresses automatic re-download until a download, play or requeue is
requested. Failed automatic downloads retry on a later poll after 15 minutes. HTTP is permitted because arbitrary
publisher RSS feeds and enclosures may still use it; Luna's own services retain
their separate authenticated protocols.

Optional iCloud sync uses a private `LunaPodcastLibrary` record with a CKAsset,
optimistic conflict retries, timestamp merges and station-deletion tombstones.
Follows, show settings, episodes, listened/saved/progress state and stations merge;
local media files, global device settings and active queues remain device-specific.
A fresh device imports the last-listened identity; an existing device retains its
own resume identity. OPML export/import provides portable followed-show lists.
Sync requires the app's CloudKit entitlements, a signed-in account and production
CloudKit schema deployment for distribution. Local debug entitlement overrides
must also include the CloudKit container/services keys; the repository's normal
Music entitlements include them.

### Resume and queue switching contract

`ResumeLastPodcastIntent` is an AudioPlaybackIntent with `openAppWhenRun = false`.
It resumes the actual last-played episode, preserving position across launches and
regardless of what media is currently active. Preparation alone does not overwrite
last-played history: AVPlayer must start playing. An empty history does nothing.
Only a natural end of the final queue item permits another episode. It refreshes
followed feeds, then chooses the oldest unplayed episode after each show's saved
listening cursor and takes the oldest of those candidates, with stable ID ties.
For the requested example, B/3 yields C versus 4; D/4 yields no playback. Manually
marking an episode played never grants the fallback permission. Explicit queued
work added after exhaustion takes priority. A never-played followed show contributes
its oldest episode when fallback is permitted.

`MediaPlaybackCoordinator` owns active media and transport routing. For app-owned
sessions, back then forward within **at most two monotonic seconds** consumes both
skips and switches queues. A standalone back waits two seconds before applying,
so a chord leaves the source queue/position untouched. No destination means normal
skip behavior; a failed switch attempts to restore the prior playing source.
The same policy serves in-app controls, widget commands, podcast and Vault remote
sessions, and CarPlay. `SwitchMediaQueueIntent` and a CarPlay Now Playing button
provide an explicit switch as well. The music player shows a labeled Podcasts
switch; the podcast player offers Switch to Music in its episode menu in both
artwork and queue modes. A successful switch replaces the displayed player,
preserving whether the queue was open; an empty destination is disabled.
A queued podcast can be started even before there is listening history. CarPlay can browse podcasts with music access
denied, and exposes followed shows, recent/downloaded/saved episodes, stations and
Now Playing/queue controls.

### Verification and platform boundaries

The implementation is **not a claim of full Apple Podcasts parity**. Apple's
application music player owns protected Apple Music hardware-command handling;
public MediaPlayer APIs do not expose those commands for interception. Consequently
the two-button chord works through Luna's app-owned podcast/Vault command handlers
and in-app controls, but cannot be promised while Apple Music owns remote playback.
Use the explicit CarPlay switch button or Switch Music and Podcasts shortcut there.
Hardware accessory delivery and entitlement-enabled CarPlay require real-device
validation; simulator policy tests cannot establish that evidence.

Apple account follows/history, Apple-paid podcast audio, ratings/reviews,
Apple editorial/personalized recommendations, proprietary Enhance Dialogue, and
Apple-generated transcripts/chapters are not exposed through the public directory
and RSS interfaces. Luna uses supplied publisher metadata; it does not fabricate
those services. CloudKit live multi-device sync, HLS background completion, media
interruption behavior and actual car/headphone switching remain device checks.
Queues/global settings are not cross-device synchronized. These limits are tracked
explicitly rather than labeled a reduced v1.

Validation on Xcode 26.2 / iPhone 17 Pro / iOS 26.2:

- App build succeeds with normal signing and background/CloudKit entitlements.
- 34 hosted Music unit tests pass, including three podcast runtime restoration,
  no-history/no-audio-ownership, and playback setting tests.
- All 16 Foundation policy/feed/store/merge tests pass; run with
  `swift test --package-path tools/podcast-tests`.
- Existing five Music UI tests pass. The new Podcasts navigation/settings test
  now covers the Library-root Podcasts destination and shared navigation stack.
- The local RSS integration UI test passes for following, automatic media download,
  saving/unsaving, and marking played. Show and settings screenshots were inspected.
  Run `python3 tools/podcast-tests/fixture_server.py` and prefix the Xcode UI test
  command with `TEST_RUNNER_LUNA_PODCAST_FIXTURE_URL=http://127.0.0.1:19265/feed.xml`.
  Without this opt-in fixture URL, only that integration test is skipped.
- Live public-directory probes returned show search, episode search and 100 chart
  results. No Apple account or private credentials were used.

Root navigation/filter validation (2026-10-08, same iOS 26.2 simulator): 37 hosted
Music unit tests pass. All nine Music UI checks pass across the suite and focused
reruns, including root options, filter toggles in all music categories, podcast
foreground retention, music search/queue links, settings and the local RSS fixture.
The fixture check resets an already-played episode and uses navigation back buttons
so it can repeat against persisted simulator data. The root screenshot was inspected.

Podcast playback and interaction fixes (2026-10-08):

- The spoken-audio playback session no longer explicitly requests `allowAirPlay`.
  That option is valid only for `playAndRecord`, causing OSStatus -50 on devices;
  the playback category already supports AirPlay ([Apple documentation](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/allowairplay)). Resume reapplies spoken-audio
  mode when returning from music. The same invalid option was removed from Vault
  music start/resume so it cannot break the return trip.
- Directory search shows `HorizonSpinnerView` throughout debounce/network loading.
  Opening a directory row shows the same spinner in its accessory, blocks repeat
  selections, and discards late navigation after leaving or changing the search.
- Automatic show continuation and its settings have been removed. The old model
  fields remain readable for persistence compatibility; only explicit queued
  episodes advance at natural completion. The Resume Last Podcast intent retains
  its separately specified deterministic fallback after natural exhaustion.

Validation: Xcode 26.2 / iPhone 17 Pro / iOS 26.2. All 42 Music tests passed,
including real AVPlayer podcast start, legacy queue migration, search loading,
repeated taps and cancelled navigation; the additional bidirectional player
presentation test also passed. Focused podcast/Vault playback reruns passed after
resume changes. All 16 Foundation tests passed. The nine UI tests passed across
the full run and focused reruns: the fixture now verifies actual podcast playback,
the empty explicit queue and visible media switch. UI launch arguments isolate
active-media state so a previous podcast test cannot change a music-route check.
Queue screenshots were inspected. Physical-device playback, the exact publisher
stream from the report, and AirPlay have not been verified in this fix.

### Podcast loading and responsiveness (2026-10-11)

Directory searches, lookups and category charts share a bounded five-minute memory
cache and coalesce concurrent requests. Feed previews use a separate bounded cache;
search/chart results and approaching rows warm at most three shows concurrently.
Discovery also warms up to three favorite/leading category pages. Speculation only
fetches metadata: it does not follow shows, persist episodes, or download audio.
Opening a known show immediately displays stored episodes and refreshes stale data
in the background. Opening a prefetched show reuses its feed response. Cancelled
navigation cannot push a late destination or cancel a shared request still needed
by another screen. Explicit feed/chart pull-to-refresh bypasses cached responses.
Followed-show refreshes run three at a time, with per-show deduplication, so opening
another show cannot lose its refresh behind unrelated library work.

New, categories, search, show updates, URL entry, import/sync/settings actions,
transcripts and chapters show loading feedback. Failed requests expose errors and
retry actions. The New-page indicator appears above categories so it stays visible
while charts load. Download rows report waiting/progress/failure, and audio buffering
appears in episode rows, the mini player and the full player; Pause remains usable.
Cached artwork is downsampled and bounded to 32 MB, and concurrent artwork requests
are shared. Show headers are reused when their metadata has not changed.

AVPlayer continues to consume remote HTTP ranges/HLS incrementally, using a
three-second forward buffer target instead of thirty seconds and immediate play.
Downloaded files still take priority and cellular-streaming policy still applies.
Preparation, resumed seeks and stalls retain buffering feedback. Thirty seconds of
continuous buffering produces a retryable error; pausing invalidates pending
preparation. Artwork, publisher transcripts and chapters load independently, with
separate loading/error states and retries, without delaying audio. Supplementary
loads have a thirty-second UI deadline; metadata URLSession requests have a
forty-five-second total resource deadline. Publisher range support, encoding and
network throughput still determine actual startup latency.

Validation on Xcode 26.2 / iPhone 17 Pro / iOS 26.2: the full 47-test Music suite
passed, followed by 15 focused podcast tests after the final loading changes and
additional cancellation/error cases. All 20 Foundation tests passed. The local
throttled HTTP test confirms actual AVPlayer playback before the whole MP4 arrives,
transcript/chapter availability while artwork is delayed, visible buffering until
readiness, no late playback after Pause, and clearing loading on HTTP failure.
Run `python3 tools/podcast-tests/streaming_server.py` and prefix the Music test command
with `TEST_RUNNER_LUNA_PODCAST_STREAM_FIXTURE_URL=http://127.0.0.1:19266/slow.mp4`.
These transport checks skip without the opt-in local fixture. They do not establish
publisher-specific or physical-device startup times.

All nine existing Music UI tests passed, including the local RSS follow/download/
playback flow. A tenth focused UI test passed against a four-second delayed feed,
verifying that a visible activity indicator remains until navigation completes.
The loading and populated-show screenshots were inspected. Use the existing
`TEST_RUNNER_LUNA_PODCAST_FIXTURE_URL` setup for both RSS UI checks.

Podcast queue download regressions are covered by the pure `tools/podcast-tests`
suite and hosted `PodcastQueueDownloadTests`. For the hosted fixture, run
`python3 tools/podcast-tests/fixture_server.py` and set
`TEST_RUNNER_LUNA_PODCAST_DOWNLOAD_FIXTURE_URL=http://127.0.0.1:19265` when running
`xcodebuild test -scheme LunaMusic`. Tests cover byte accounting with unknown and
underreported sizes, enqueue/reorder-triggered downloads, paused local playback
after manifest restoration, natural-end deletion/refill and sleep-at-end cleanup.
The completion regression delivers AVPlayer’s end notification after playback
starts, avoiding dependence on the simulator’s sometimes-stalled audio clock.

### Podcast transport recovery (2026-10-14)

Podcast seeks retain the latest requested position through preparation and repeated
seeks. Periodic callbacks read the current AVPlayer time instead of applying a
possibly obsolete callback time, and do not overwrite an in-flight seek. Seeking
an unprepared/restored episode persists its position without claiming listening
history. Seeking back into a completed episode clears its completion marker so
Resume honors that position. Touch release and VoiceOver slider changes commit
seeks; the timeline has a 44-point interaction height.

Natural completion advances the explicit queue before asynchronous download
reconciliation. Completion notifications are checked against the current item and
play intent, and duplicate/late events cannot advance twice or autoplay after
Pause. Seeking/skipping to EOF advances an existing explicit queue while preserving
paused state; manual completion never grants the Resume Last Podcast intent's
natural-exhaustion fallback. The final episode can replay with Play. Restoration
prefers the persisted current item, recovers stale terminal positions into queued
work while paused, and resolves the actual asset duration on resumed seeks when
RSS duration is missing or inaccurate. Native video transport changes are reflected
in Luna's play intent, preventing a later seek from undoing a native Pause.

Validation: Xcode 26.2 / iPhone 17 Pro / iOS 26.2. All 69 hosted Music tests passed,
including 12 real-AVPlayer transport regressions and the existing throttled HTTP,
offline download, completion/refill and sleep-at-end checks. All 29 Foundation
podcast tests passed. The expanded RSS UI integration passed with actual slider
interaction, paused foreground retention, skip back, speed, sleep timer, episode
actions and queue editing. Player artwork/queue layouts were inspected. These
checks establish simulator behavior; the reported physical-device session,
headphones and AirPlay have not been reproduced by this change.

### Local podcast cold-start resume (2026-10-14)

The saved complete episode is opened and sought as Luna Music launches, without
activating the audio session, recording listening history, playing audio, or
contacting its publisher. Resume and Resume Last Podcast reuse that AVPlayerItem;
Play during preparation waits for the same task instead of rebuilding the item.
Pause invalidates preparation and rapid seeks retain only the latest target.
Actual duration is resolved during local preparation so missing/inaccurate feed
lengths still recover a saved EOF into the explicit queue.

Playback no longer awaits URLSession/AVAssetDownloadURLSession task restoration.
The download manifest and file-size validation already identify complete local
files synchronously; reconciliation remains asynchronous. File-based items disable
stall prediction and use the default forward buffer; remote streams retain their
three-second target and cellular policy. Items automatically load only tracks,
matching [Pocket Casts' playback item setup](https://github.com/Automattic/pocket-casts-ios/blob/46952f88227581c27d4013cde1874a3db1b4cc69/podcasts/PlaybackItem.swift).
AVURLAsset's approximate timing mode avoids requesting a precise whole-file scan;
exact seeks are retained to preserve the listener's chosen position. Audio is
file-backed and decoded incrementally, rather than read into a whole-file Data or
PCM buffer. Download priority already retains the current episode and explicit
queue subject to the configured storage budget and deletion preferences.

Now Playing activation runs alongside playback instead of preceding it. Artwork,
chapters and transcripts start after the play request. Loading Audio remains until
the playback clock actually advances; AVPlayer's `playing` state alone is no longer
sufficient. A temporary 50 ms time observer checks startup and is removed as soon
as the clock advances; steady-state playback keeps its 500 ms observer. This
reports media delivery, not whether a headset/AirPlay route is audibly producing
sound, nor whether the publisher encoded silence at that position.

Validation: Xcode 26.2 / iPhone 17 Pro / iOS 26.2. All 74 hosted Music tests passed,
including five new offline restoration, cancellation, latest-seek, EOF and long-MP3
checks, plus existing throttled streaming and download lifecycle tests. All 29
Foundation podcast tests passed. Prepared local resume reached an advancing clock
in 0.144 s for the three-minute MP4 fixture and 0.140 s halfway through a generated
two-hour, 28.8 MB MP3, using an unreachable publisher URL. These are simulator
measurements after local preparation; physical-device/Bluetooth/AirPlay latency
and a user tapping before preparation finishes are not established by those timings.
