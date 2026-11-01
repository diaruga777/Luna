# Luna Music

Mac setup, restored connections, account credentials, and adaptive companion UI are
shared across Vault, Music, and Code. See [One Luna Mac connection](mac-connection.md).

Standalone iOS 26 player: scheme `LunaMusic`, bundle ID
`$(PRODUCT_BUNDLE_PREFIX).music`, app module `LunaMusicApp`. Apple library songs
and Luna Vault files coexist in the same songs, artists, albums and search views. Music owns its library and queue state. Its Reader integration reads text saves from the shared `saves.sqlite` without changing Reader progress.
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

The Music Library root lists Playlists, Artists, Albums and Songs. The floating
player bar switches libraries: Music stays on the left and Podcasts on the right.
The selected surface expands to show its own artwork, title and playback controls;
the other remains a 56-point circular icon button, centered beside the player even
when larger text makes the bar taller. Switching preserves each library's navigation
stack and scroll position, and does not start or interrupt audio. The search text stays
synchronized across both libraries as it changes, and each surface shows its own matches.
If search is focused, focus transfers to the destination's visible search field;
switching with the keyboard dismissed leaves it dismissed.
Play explicitly resumes that surface's queue. There is no tab bar or separate
Downloaded music root destination.
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

`MusicSceneDelegate` restores the last-used Music or Podcasts root at cold launch
and focuses its search field with the keyboard visible. Returning from background
does the same on the selected surface. The former Podcasts tab preference migrates
to this navigation state. Explicit search links return to the Library, and podcast episode/queue
routes select Podcasts and open the requested episode or queue. Permission alerts and transient inactive states do not
reset navigation. An incoming `lunamusic://queue` URL takes precedence and opens
the queue without the keyboard; `lunamusic://search?q=…` supplies a query. App
Intent routes are retained until a cold-start scene has installed observers.

## System surfaces

Siri's **Play Library Music** intent resolves indexed songs, albums, artists and
playlists through the library entity query. A playlist starts in shuffle; a song
starts first and continues with a shuffled containing playlist selected by the same
recency and playlist eligibility rules as in-app playback. See
[music-system-integrations.md](music-system-integrations.md) for Siri, Shortcuts,
widgets, Control Center and CarPlay. The app and
widget use the family App Group for a small, separate music state snapshot.

The UI uses native UIKit navigation search, sheets, controls and iOS 26 Liquid
Glass for floating playback controls. The mini player grows from 56 points to fit
Dynamic Type and opens the selected surface's full-screen player with
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

Podcasts opens from the right-hand player pill. Music and Podcasts retain
independent queues. Its root mirrors Music's selection table: Home
(continue/latest/recent), New (public directory charts and categories), Shows,
Latest Episodes, Downloaded and Played, followed by custom stations and
favorite categories. Both roots share the native stacked navigation search UI.
Podcast search is always available at the root, with Shows, Episodes and Your
Library scopes; clearing the query restores the selection rows. The former top
section selector and separate Search destination are removed.
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
and Last-Modified. Followed feeds check when due on foreground and roughly every
six hours, using BGAppRefreshTask while backgrounded; iOS chooses the actual
background opportunities and can delay them or disable them after force quit.
Opening a show can refresh after 15 minutes; pull-to-refresh bypasses the throttle.
Checks start with the least recently attempted feeds, with at most three requests
in flight. Attempt times persist before networking, including failures, so an
interrupted run gives untouched follows priority next time.

New follows default to episode notifications. A bell beside Following toggles the
same preference as New Episode Notifications in Show Settings; saved preferences,
including existing off choices, survive upgrades and refollows. Following asks for
system notification permission without failing the follow if permission is denied.
Turning the bell back on after denial explains how to enable notifications in
Settings. Unfollow hides the bell and clears undelivered/delivered alerts.

Each newly discovered episode gets **New {Podcast name}** / **{Episode title}**,
grouped by show, with the show's artwork as an image attachment thumbnail. The
system app icon remains Luna Music's: communication notification avatars are for
direct messages/calls, not feed updates. Missing or failed artwork falls back to
the text alert. The initial feed archive never alerts. New episode IDs enter a
device-local outbox in the same atomic transaction as the feed merge; interrupted
runs drain that outbox before the next poll. Stable notification IDs and checking
already delivered notifications avoid duplicates during interrupted delivery.
Muted/unfollowed/permission-denied alerts are discarded without a later backlog.
Tapping an alert uses the existing cold/warm episode-page route. Add to Queue and
Play Next run the episode menu's persisted enqueue operation in the background,
without opening a page or starting playback. Foreground alerts show banners too.
Outbox and check-attempt times stay local when iCloud settings merge.

Validation (2026-10-23): all 41 Foundation podcast tests passed. Eight focused
hosted Music tests passed on iPhone 17 Pro / iOS 26.2, including actual local
notification delivery with a downloaded image attachment, exact copy, category
registration, both persisted queue operations and clearing interrupted alerts on
mute. The bell UI test passed default-on, mute, relaunch/refollow persistence,
re-enable and hiding on unfollow; its screenshot was visually inspected. The
additional manual notification-tap check was blocked by the locked Mac; background
scheduling remains system-controlled rather than a measured six-hour guarantee.
Run the fixture server and set
`TEST_RUNNER_LUNA_PODCAST_FIXTURE_URL=http://127.0.0.1:19265/feed.xml` for the
notification delivery and bell checks; system delivery requires notifications
allowed in the simulator.

Streaming uses AVPlayer with a spoken-audio session, elapsed-time checkpoints,
interruption/route handling, lock-screen metadata, remote commands and AirPlay.
Native playback exposes configurable back/forward intervals (15/30 seconds by
default), speed 0.5–3×, time seeking, sleep timers including end-of-episode, volume,
video/Picture in Picture, publisher chapters (RSS, JSON or embedded metadata), and
publisher VTT/SRT/TTML/JSON/plain-text transcripts with search and timed seeking.
Manual played/unplayed changes, share, Play Next, Add to Queue,
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
cellular streaming/downloads, per-show automatic limits,
a download byte cap (2 GB by default; 500 MB, 1/2/5/10 GB choices), played-file
retention for manually marked episodes and storage removal. The current/paused
episode and explicitly queued episodes download first, in playback order, ahead
of manual and per-show automatic requests. Queue edits and launch reconcile
immediately, independently of feed refresh. Downloads run one at a time; unknown
sizes reserve the remaining budget until measured, and the first episode that
cannot fit stops the queue prefix. Queue reordering evicts lower-priority files
and preempts lower-priority transfers. Actual response/file sizes enforce the cap,
including underreported RSS enclosures; HLS packages are measured before retention.
Lowering the cap preserves an asset still open in AVPlayer until it is released.
A paused streaming item switches to its completed local copy on resume. Natural
completion always releases and deletes that episode's download, including
manual downloads and sleep-at-episode-end, then refills the queue within the
cap. Completed episodes do not automatically download again. Explicit
deletion suppresses automatic re-download until a download, play or requeue is
requested. Unplayed automatic downloads that have never started expire seven days
after the download request was created, during download reconciliation (launch,
library changes and refresh/background maintenance). Playback history or a nonzero
saved position protects an episode from this expiry, including a started episode
rewound to zero. Manual downloads, explicit queue items and the active player asset
are also protected. Expiry deletes the local file and suppresses automatic
re-download until an explicit download, play or requeue request; feed/library
metadata is retained. Failed automatic downloads retry on a later poll after 15
minutes. HTTP is permitted because arbitrary publisher RSS feeds and enclosures may still use it; Luna's own services retain
their separate authenticated protocols.

Optional iCloud sync uses a private `LunaPodcastLibrary` record with a CKAsset,
optimistic conflict retries, timestamp merges and station-deletion tombstones.
Follows, show settings, episodes, listened/progress state and stations merge;
local media files, global device settings and active queues remain device-specific.
A fresh device imports the last-listened identity; an existing device retains its
own resume identity. OPML export/import provides portable followed-show lists.
Sync requires the app's CloudKit entitlements, a signed-in account and production
CloudKit schema deployment for distribution. Local debug entitlement overrides
must also include the CloudKit container/services keys; the repository's normal
Music entitlements include them.

### Resume and queue switching contract

`ResumeLastPodcastIntent` appears as **Resume Podcast Queue** and is an
AudioPlaybackIntent with `openAppWhenRun = false`. Its Boolean `overrideOtherAudio`
parameter defaults to `true`, allowing resuming even when other audio is playing.
When explicitly set to `false`, it returns without installing the playback
coordinator or resuming playback if
`AVAudioSession.sharedInstance().isOtherAudioPlaying` is true.
Its **Pause Immediately** Boolean defaults to `false`. When enabled and podcasts
retain playback ownership, it pauses without starting or replacing the item. An
already paused item stays paused at its exact position. Ownership is tracked from
actual playback with an active podcast session and cleared by audio interruptions
or switching to music; the shortcut also checks for other playing audio. This is
conservative process-local evidence, since `MPNowPlayingSession.isActive` does not
identify the system-wide playback app.
Otherwise it starts playback, waits for the media clock to advance and the
podcast's Now Playing session to become active, then allows a continuous handoff
window before pausing.
That window is at least three seconds, or the audio route's output latency plus I/O
buffer duration when longer; buffering resets the window. A single advancing tick
and `MPNowPlayingSession.isActive` only establish player/app-local state, not that
iOS has selected Luna as the system playback app. Normal Resume returns after
playback starts. Startup is bounded and cancellation or a newer transport action
cannot cause a late pause. After priming, it pauses and completes an exact seek to
the item's pre-playback offset, persisting that restored position before returning.
The rewind holds a background execution task through seek completion so pausing
background audio cannot suspend it halfway through. A repeated Pause Immediately
invocation during priming, a native player pause that cuts its handoff short, or
cancellation of the priming intent also restores that item's starting offset.
A newer explicit transport action always wins; normal already-playing podcasts
still pause at their current position.
Natural completion during the handoff follows the next queued episode and pauses
after that item's playback window, restoring that next item's starting offset and
retaining a resumable item.

AirPods connection automations can use this one action with Pause Immediately
enabled. **Pause If Playing** (`PauseMusicIntent`, restored) and **Seek**
(`SeekMusicIntent`) provide the separate-invocation alternative: Resume with Pause
Immediately off, Shortcuts Wait 1 second, Pause If Playing, then Seek Backward
1 second. Seek has direction and seconds parameters (defaults: Backward, 1),
preserves the paused state and waits for completion. Invalid durations fail and
out-of-range positions clamp to the media bounds. These actions never open the app.
It resumes the actual last-played episode, preserving position across launches and
regardless of the selected media surface. Preparation alone does not overwrite
last-played history: AVPlayer must start playing. An empty history does nothing.
Starting playback through this intent preserves the explicit Up Next list and its
order, including when the selected episode is already queued. It does not requeue
an interrupted episode. Natural completion uses the ordinary queue advancement:
remove the completed episode, play the first remaining item, and retain the rest.
If completion already staged the next item while paused or during restoration,
the intent resumes that item instead of returning to the completed last-played one.
When the last-played episode is completed and there is no pending selection or
explicit queue, the intent chooses the oldest downloaded, unplayed episode after
each followed show's saved listening cursor, then takes the oldest of those
candidates, with stable ID ties. It validates the local file, so incomplete or
missing downloads cannot qualify. It does not refresh feeds or stream a new
fallback episode. A completed episode is never implicitly replayed, regardless of
how the queue became empty or whether its natural-exhaustion flag is set. If
nothing qualifies, playback and played history stay unchanged. Explicit queued
work still takes priority. A never-played followed show contributes its oldest
eligible download when there is playback history elsewhere in the library.

Validation (2026-10-19): all 36 Foundation podcast tests and 34 focused simulator
tests passed; three optional long-MP3 fixture tests were skipped. Coverage includes
intent queue preservation, repeated resume, restored pending-next selection, and
real AVPlayer natural completion into the next explicit queue item.

Validation (2026-10-22): the full LunaMusic hosted suite passed on iOS 27.1
(122 tests, 10 optional fixture skips, zero failures), including cold/warm offline
priming, immediate sequential Resume/Pause, delayed streaming, late artwork,
cancellation and superseding Play. All 36 Foundation podcast tests passed. Removing
the readiness wait reproduced an inactive session with no clock advancement in
the sequential Resume/Pause regression. Generated App Intents metadata confirms
Pause Immediately defaults to false. The standalone Pause action was absent in
that revision and has since been restored as Pause If Playing.
AirPods stem/locked-device behavior still requires a physical-device check.

Follow-up (2026-10-22): the initial first-tick change did not resolve the reported
device behavior. Podcasts now use AVFoundation automatic Now Playing publishing;
static title/artwork live on `AVPlayerItem.nowPlayingInfo`, while the framework
owns elapsed time, duration and playback state. Artwork is retained when reopening
the same episode. Apple Music's application queue player is created only for Apple
Music playback, and switching to podcasts no longer sends Pause to an idle music
player. Remote Play holds a UIKit background task through asynchronous preparation
and actual audio startup; an immediate Pause cancels a queued remote Play. Cancelled
buffering timers cannot fail a newer attempt. `LunaMusic/PodcastPlayback` OSLog
events record intent/remote transport state without episode titles or URLs.

The revised full hosted suite passes on iOS 27.1 (126 tests, 10 optional fixture
skips, zero failures). Coverage now invokes the remote Play handler and checks
that podcast activation never creates an Apple Music player, newer remote Play
requests survive cancellation of older tasks, and natural completion during priming
leaves the successor paused and resumable. These simulator checks do not establish
locked-device AirPods resumption by themselves.

The subsequent AirPods report (first press ignored, second press playing Apple
Music) is not considered resolved by those app-local assertions. The handoff
window is now three seconds, and separate Pause/Seek actions allow testing the
alternative shortcut in the same build. Off-main remote callbacks synchronously
reach the main actor before returning success; prepared podcast playback starts
within the callback. The fallback regression runs Resume, Wait, Pause and a
one-second backward seek, then checks that a single off-main Play requests audio
before the callback returns. Physical devices were not accessed for this revision.
The simulator build and generated App Intents metadata pass; 26 routing, queue,
and relative-seek checks pass. Full audio validation was attempted on iOS 27.1
and iOS 26.2 but is blocked by simulator AudioQueue/HAL startup timeouts
(`AQMEIO` / `AddRunningClient`, including existing playback tests). The longer
play/pause path and the real-audio fallback regression remain unverified in that
environment; these results do not establish that the hardware report is fixed.

Validation (2026-10-23): the Music simulator build-for-testing and all 42 Foundation
podcast tests passed. The eight hosted remote-command tests also passed. Playback
regressions cover already-paused/playing sessions, interrupted and music-switched
ownership, exact clock/persisted-position restoration and natural advancement.
Their runtime verification remains pending: audio output stalled on both iOS 27.1
and a fresh iOS 26.2 simulator, including the existing ordinary local-resume test.

`MediaPlaybackCoordinator` owns active media and transport routing. Back always
applies immediately. Once that operation finishes successfully, a forward command
within **one monotonic second of completion** switches queues instead of applying
forward; the already-applied back remains in the source queue. A forward received
before completion, more than one second later, or without a destination performs
an ordinary forward. Every newer transport command invalidates older completion
callbacks, so cancelled, failed or superseded backs cannot arm a later switch.
The same path serves in-app controls, widget commands, CarPlay and app-owned
headphone/system remote commands, including mixed hardware/software sequences.
Podcast seeks report AVPlayer completion; Vault seeks and previous-track loading
report completion when ready, and Apple Music state updates confirm native backs.
A failed switch attempts to restore the prior source at its updated back position.
`SwitchMediaQueueIntent` and a CarPlay Now Playing button also switch explicitly.
The music player shows a labeled Podcasts
switch; the podcast player offers Switch to Music in its episode menu in both
artwork and queue modes. A successful switch replaces the displayed player,
preserving whether the queue was open; an empty destination is disabled.
A queued podcast can be started even before there is listening history. CarPlay can browse podcasts with music access
denied, and exposes followed shows, recent/downloaded episodes, stations and
Now Playing/queue controls.

### Verification and platform boundaries

The implementation is **not a claim of full Apple Podcasts parity**. Apple's
application music player owns protected Apple Music hardware-command handling;
public MediaPlayer APIs do not expose those commands for interception. Consequently
the completion-based gesture works through Luna's controls and its app-owned
podcast/Vault remote handlers. Apple's protected playback commands remain owned
by Apple Music and cannot be intercepted by Luna.
Use the explicit CarPlay switch button or Switch Music and Podcasts shortcut there.
Hardware accessory delivery and entitlement-enabled CarPlay require real-device
validation; simulator policy tests cannot establish that evidence.

App-owned podcast and Vault sessions explicitly enable next/previous commands for
headphone double/triple presses. Podcasts also accept interval skip commands from
system controls. Both routes use the same completion-based gesture as in-app
controls. There is no intentional transport delay. Completion and arrival times
use monotonic uptime; remote-event timestamps are not mixed with uptime.
Isolated podcast players route skips to themselves when no coordinator is installed.

Now Playing activation waits for session eligibility and retries when eligibility
changes or audio begins playing. A failed attempt during startup cannot permanently
leave hardware commands routed to the preceding session. Paused sources do not
reclaim activation. These changes do not intercept Apple's application music
player's commands; its ordinary next/previous behavior remains system-owned.

Verification (2026-10-14): the LunaMusic simulator suite completed 88 tests with
13 fixture-dependent skips and zero failures; all 29 Foundation podcast tests
passed. Regression coverage checks headphone command enablement, monotonic skip
timing, late session eligibility, paused/cancelled activation, podcast intervals,
and both directions of queue switching with preserved positions. The switch test
also waits for the destination's real Now Playing session to become active.
Actual AirPods button delivery remains a physical-device acceptance check.

Skip gesture correction (2026-10-16): removed the delayed-back recognizer and
the separate immediate-only headphone path. Back takes effect immediately and
only forward is consumed when it switches within one second after back completes.
Regression coverage exercises mixed software/remote commands, exact window
boundaries, slow seeks, unsuccessful/superseded completions and retained back
positions. Ten focused Music tests and all 34 Foundation podcast tests pass,
including an actual paused AVPlayer back-seek callback and superseded seek
cancellation. Actual AirPods delivery and response time require device validation.

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
  episodes advance at natural completion. The Resume Podcast Queue intent retains
  its separately specified deterministic fallback to eligible local downloads.

Tapping Play on another podcast episode moves the unfinished current episode to
the front of the existing queue, preserving its latest playback position. This
also works when the current episode is paused or restored after relaunch. The
selected episode and interrupted episode are not duplicated in the queue;
completed episodes and repeat taps on the current episode do not add a queue
entry. Automatic queue advancement and explicit Play All retain their existing
behavior.
Validation: all 17 `PodcastTransportTests` passed on iOS 26.2, including actual
audio switching, return to the saved position, paused restoration, duplicate
prevention and completion handling.

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
paused state; the Resume Podcast Queue intent never replays completed history and
can choose an eligible local download when no queued work remains. The final
episode can replay with Play. Restoration prefers the persisted current item, recovers stale terminal positions into queued
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

Launch restores only the saved episode identity, position and cached duration from
library/download metadata. It does not open an audio asset, create an AVPlayerItem,
load tracks, or seek/preroll the episode. The earlier launch-time prewarming has
been removed. On Play, AVPlayer opens the complete local file and seeks directly
to the saved position. It loads only tracks, uses approximate asset timing, disables
stall prediction for local files, and does not wait for download-session restoration
or Now Playing activation. A no-op cold selection also avoids encoding and atomically
rewriting the entire feed library before audio opens. Remote HTTP/HLS playback
retains its three-second forward buffer and cellular policy.

Download completion prepares durable playback data on a utility task: actual
duration and embedded chapter titles are saved with the download manifest. Raw MP3
and AAC packets are copied into an indexed QuickTime `.mov` container using
AVAssetExportPresetPassthrough, preserving compressed audio without decoding it
into a whole-episode PCM buffer or re-encoding it. MP4/M4A and PCM need no remux.
Apple documents that [QuickTime/MPEG-4 carry timing information that other formats
may require media parsing to determine](https://developer.apple.com/documentation/avfoundation/avurlassetpreferprecisedurationandtimingkey).
[Tracks-only playback preparation](https://github.com/Automattic/pocket-casts-ios/blob/46952f88227581c27d4013cde1874a3db1b4cc69/podcasts/PlaybackItem.swift)
also follows the open-source Pocket Casts player. Apple's own app internals are not
publicly established by this research.

A download is published as complete only after optional preparation and atomic
installation. A failed/cancelled export retains the transferred original; a container
whose overhead would exceed the retained download budget also falls back to the
original. Temporary remux files are cleaned up. Preparation holds a background task
and delays background URLSession completion while its jobs finish. MP3 download
staging keeps a valid audio extension, since format discovery for an extensionless
staged file can fail on iOS. Embedded chapters survive container replacement through
the manifest. HLS packages continue to use AVAssetDownloadURLSession and their native
manifest timing; older files without timing metadata resolve/cache duration on use.

Existing downloads upgrade during app backgrounding or scheduled background refresh,
never on foreground launch or Play. Each maintenance pass prepares up to five files,
prioritizing the current episode and explicit queue. It skips files already open in
the player, checks that the record is still current after asynchronous work, respects
storage limits, commits the replacement manifest before deleting the original, and
cannot resurrect a user-deleted download. The optional metadata/version fields remain
compatible with earlier download manifests.

Loading Audio remains until the playback clock advances. A temporary 50 ms observer
is removed at that point; steady-state playback keeps its 500 ms cadence. Chapters,
transcripts and artwork load after the play request. This confirms media delivery,
not physical headset output or the absence of silence encoded by the publisher.

Validation: Xcode 26.2 / fresh iPhone 17 Pro / iOS 26.2. All 83 hosted Music tests
and all 29 Foundation podcast tests passed. The download integration used a two-hour
VBR MP3 without a Xing seek header and verified the indexed file still has the MP3
codec, duration survives manifest restoration, and the restored player opens no
audio at launch. A native passthrough probe also produced identical SHA-256 hashes
for source and output compressed packet streams. Storage-cap fallback, cancellation,
legacy conversion, active-file protection, and deletion during preparation passed.

With launch prewarming removed, the entire Resume request reached an advancing clock
in 0.161 s for the local three-minute MP4 and 0.135 s halfway through the indexed
two-hour MP3. Play after only metadata restoration measured 0.162 s. A separate
fresh-item open-and-exact-seek check reached readyToPlay in 0.013 s. These are simulator
measurements; physical device, Bluetooth and AirPlay latency remains unmeasured.
The actual terminate/relaunch UI check passed with the paused position restored and
clock advancement after Play, alongside the existing RSS playback/queue integration.
On the freshly created simulator, the first UI attempt was displaced by the initial
Music authorization callback; the cold-relaunch check passed after that setup settled.
The resumed-player screenshot was inspected.

### Show-page and library scrolling responsiveness (2026-10-15)

Podcast feed imports/refreshes prepare, merge, encode and stage their library
snapshot on a utility task. The main actor only validates its revision, atomically
renames the staged file and publishes. An intervening edit retries against the
latest state; cancellation and failed preparation cannot publish or replace the
library. Feed metadata and episodes commit together. Mark All as Played also
uses one background transaction instead of one complete library rewrite per item.
Periodic playback checkpoints use the same background path and cannot overwrite a
newer seek, pause or completion. Their notifications update visible episode status
without rebuilding lists or recalculating automatic downloads.

Podcast artwork uses ImageIO thumbnail creation and decoding on a utility task.
Episode rows cache description conversion and date formatting, limit the two-line
summary to 500 characters, and create action menus only when opened. Full show
notes remain available in Episode Details. Show headers ignore refresh bookkeeping
when deciding whether to rebuild. Download/buffering status refreshes reuse static
row content, throttle progress updates and coalesce list reloads. Hidden screens
defer notification-driven work until they reappear. Download callbacks reuse the
current byte reservation, rebuilding the plan only when queue/settings change or
the response exceeds its reservation, while retaining oversized-response checks.

Music library sorting/grouping and root/collection text searches run in background
tasks. Searches debounce briefly, cancel obsolete workers and reject stale results;
clearing search restores rows immediately. Album grids are derived once per result
change instead of for every row request. Four-cover playlist artwork stops after
finding four usable covers instead of decoding the entire playlist's album art.
Song menus are also deferred until opened.

The Foundation regression fixture imports 2,000 episodes with long show notes.
On the development Mac, the synchronous comparison blocked the main actor for
79 ms; background import took 85 ms while its 5 ms heartbeat's largest observed
gap was 8 ms. This measures storage work, not physical-device scroll frame times.
Regression tests cover concurrent edits/imports, cancellation, atomic durability,
batched publication, hidden-screen updates, position-only notifications, bounded
summaries, menu ownership and search cancellation. The local RSS fixture server
also provides `/large-feed.xml`; the Music UI suite's large-archive test opens,
scrolls and visits an episode menu/details page using the usual
`LUNA_PODCAST_FIXTURE_URL` test-runner environment setup.

Validation: Xcode 26.2 / iOS 26.2. All 34 Foundation podcast tests passed;
51 focused hosted Music tests completed with three optional streaming-fixture
skips and zero failures. Five UI checks passed across focused runs, covering the
large archive, loading feedback, foreground search, podcast navigation and
Downloaded filters. The archive and episode layouts were inspected. Broader audio
checks timed out starting AVPlayer on both the existing and a fresh simulator;
the local-audio start regression also failed in a separate unchanged-`main`
checkout on that fresh simulator. Those audio failures are not claimed green.
Physical-device scroll frame times have not been measured.

### Long text and player layout (2026-10-16)

The mini player, music player, podcast player/show name and podcast queue use a
clipped single-line ticker for overflowing titles. It pauses at either end,
stops when removed/backgrounded, restarts after foreground/layout changes and
respects Reduce Motion; VoiceOver retains the complete title. Tapping podcast
player titles opens the episode/show, and episode-row titles or summaries open
full details. Show descriptions expand/collapse with More/Less, resizing the
header above playback/filter controls. Accessibility text sizes stack show artwork
above metadata. Row labels yield horizontal space to artwork and action controls.

Episode details use a compact navigation title and a scrollable, selectable text
view with separate title, show, date and notes styles. Sticky podcast section
headers use the system background to keep episode text from showing through.

Validation: Xcode 26.2 / iPhone 17 Pro / iOS 26.2. All 21 focused layout,
responsiveness and long-text tests passed. The large-archive UI check passed
More/Less expansion, scrolling and full notes; the RSS playback/queue integration
also passed. Screenshots of the player, rows and episode details were inspected.

### Player-bar library switching (2026-10-18)

`MediaLibraryNavigationController` retains a stack per library. Switching from an
active search waits for UIKit's dismissal before replacing the stack, then restores
the outgoing query. A focused outgoing search transfers first responder to the
destination's search without clearing either query. Returning to a saved detail
screen without search does not force navigation back to its library root.
Foreground music focus uses a cancellation token so leaving
Music cancels pending focus without suppressing the normal foreground retry.
Queue and episode links dismiss current presentations before routing. Mini and
full-player controls target the displayed surface; remote queue changes still
replace an already-open player after its presentation finishes.

Validation: Xcode 26.2 / iPhone 17 Pro / iOS 26.2. Across targeted runs, 29 hosted
navigation, layout, search and player regressions and seven UI checks passed.
UI coverage includes both pill directions with the keyboard open, retained
navigation/query, clearing podcast search, podcast settings, music filters,
foreground search and warm/cold queue links. Both expanded-bar layouts and podcast
search were visually inspected. The existing local-audio startup regression timed
out both here and on unchanged main; audio startup is not claimed green.

The search-focus follow-up passes four focused UI checks plus four hosted
navigation/layout checks on the same simulator. The new UI regression types into
both destination search fields without refocusing, checks each retained query,
verifies both switchers are square, and confirms a dismissed keyboard stays
dismissed. Focused switches skip the crossfade so focus can transfer as soon as
UIKit attaches the incoming navigation search. The focused podcast search and
circular switcher screenshot was visually inspected.

### Remembered player view (2026-10-18)

Music and podcast players each remember whether their upper stage last showed the
queue list or the current item's artwork. Opening the mini player restores that
view after dismissal and across app launches. Queue buttons, completed drag
transitions and VoiceOver actions save the choice immediately. Explicit queue
links still open the list, and switching between the full music/podcast players
keeps the displayed mode and remembers it for the destination player. A fresh
installation starts with artwork.

Validation: Xcode 26.2 / iPhone 17 Pro / iOS 26.2. All four focused UI tests
passed: music and podcast queue/artwork restoration after close/reopen and actual
terminate/relaunch, existing queue controls/drag behavior, and warm/cold explicit
queue links. No audio playback is required by these view-state checks.

### Episode list titles and bookmark removal (2026-10-23)

Episode rows use the existing single-line ticker in library, show and station
lists. Overflowing titles scroll behind a trailing fade, pause at each end and
respect Reduce Motion. Title length does not increase row height, including at
accessibility text sizes. VoiceOver retains the full title, and tapping it opens
episode details. Descriptions remain two-line previews.

The Saved library and CarPlay collections, show filter, Save/Unsave Episode
commands, Download Saved Episodes preference and bookmark-based download rules
are removed. Old bookmark keys are ignored when loading and syncing libraries
and disappear on the next write; listening progress, follows, queues and download
settings still decode normally. Downloads remain available from episode menus,
the Downloaded collection and per-show automatic download settings.

Validation: Xcode 26.2 / iPhone 17 Pro / iOS 26.2. All 42 Foundation podcast tests
and 10 focused hosted tests passed. The hosted checks include title layout
at 320/402 points with default and maximum accessibility text, download
menu availability, library navigation and deferred screen updates. Row screenshots
were inspected at both text sizes.

Two focused UI checks also passed for podcast settings and switching between
Music and a Downloaded detail page, including clearing podcast search and
confirming the Saved row is absent.

Follow-up: replaced expanding episode titles with compact tickers after user
review. All 11 focused hosted tests passed, comparing short/long title row
heights, verifying overflow animation and retaining full accessible titles at
both widths and text sizes. Compact row screenshots were inspected.

iPad window cleanup (2026-10-24): library row content follows UIKit’s readable width and the floating player bar is centered with the shared 680-point cap. The landscape Music player keeps AirPlay centered in the playback-controls column. The LunaMusic Simulator build passes.

### Podcast resume and automatic-download expiry (2026-10-27)

Resume no longer relies on the natural-exhaustion flag to avoid replaying completed
history. Empty-queue fallback uses only complete local downloads newer than the
corresponding show's listening cursor. Seven-day expiry removes unstarted automatic
downloads and persists suppression so maintenance cannot immediately fetch them again.

Validation: all 45 Foundation podcast tests passed. On Xcode 26.2 / iPhone 17 Pro /
iOS 26.2, 49 focused hosted tests passed and five optional fixture checks skipped.
Coverage includes empty-queue completed-history no-op, offline fallback past older
backlog and a missing local file, queue preservation, transport, expiry protection
and durable suppression after download-manifest restoration. The existing
`testPauseImmediatelyPrimesColdAndInterruptedPodcastAndRestoresPosition` fails its
start-count assertion (3 versus 2) on both this change and unchanged `main`; it was
excluded from the passing focused run.

### Podcast queue download chime (2026-10-27)

When an episode finishes naturally and the next queued episode has no complete
local download, a soft two-note chime repeats every two seconds while its audio
loads. The cue uses the existing reader transition tone with a silent tail,
looped by AVAudioPlayer so background playback does not depend on a repeating
timer. It stops as soon as the next episode's playback clock advances, or on
Pause, an audio interruption, a removed audio route, a playback error or selection
of another episode. Explicit Play, seek-to-end advancement, complete local files
and sleep-at-episode-end do not start it. The existing streaming path and
thirty-second loading timeout remain in effect. Regenerate the bundled cue with
`scripts/make_tones.py`.

Validation: Xcode 26.2 / iPhone 17 Pro / iOS 26.2: all 38 selected hosted
transport and loading tests passed with the local streaming fixture enabled.
The six-second handoff verifies a complete two-second chime cycle followed by
actual clock advancement and chime cleanup. Pause (including late network data),
interruption, failure, replacement playback, explicit Play and sleep-at-end are
covered. The previously documented prime start-count failure remains excluded.
Physical-device/background audio output and AirPlay have not been measured.

### Luna Reader readouts

When Luna Reader is installed, the podcast root includes **Luna Reader**, with
Reader’s monochrome app artwork. It opens a searchable list of ready, unread text
saves and extracted documents. Read, archived, pending-archive and deleted saves
are omitted. Reader readouts use that same bundled icon in the queue, episode
rows, mini-player and expanded player, including after reusing podcast cells. Tapping a save creates its
readout and appends it to the podcast queue; long press also offers **Play Next**.
Generation shows per-save progress and failures can be retried. Reader’s active
and archived text-save menus offer **Add to Luna Music** when Music is installed.
The `lunamusic://reader?save=<UUID>` handoff opens this page and adds that save;
a bare `lunamusic://reader` opens the browser. Invalid save IDs are rejected.

Adding a save does not change its read state. After natural readout completion,
Music calls the shared store's `markFinishedReading`, setting Reader's read state,
terminal progress and pending-archive marker together. Pausing, skipping to another
episode or seeking directly to the end does not finish the source save. A deleted
source is never recreated; Music's exported audio remains playable. The browser
reloads for saves changes and on foreground. Normal adds follow Reader's voice preference. If a Gemini
API key is saved in Reader, the plus menu and long-press menu also offer **Add with
Gemini** and **Play Next with Gemini**, even when the device voice is preferred.
No second key setup is needed: the credential is read from the shared Keychain.
Gemini uses the same generated-section cache as Reader, so audio generated in
either app can be reused by the other without another API request. Existing
Reader-local cache entries migrate automatically. See [Gemini read-aloud](gemini-tts.md)
for quotas, privacy, progress, cancellation and request deadlines.

Both voices use the cached trimming script (or the same heuristic fallback).
Each block is written to AAC in turn; memory does not grow with the full readout.
Explicit Gemini adds can replace an existing device readout rather than silently
reusing it. A current episode must be changed before changing its voice. Both
exports are retained for reuse; changing voices clears the old listening position.
Failure preserves the existing readout and never silently substitutes another voice.
The completed M4A is installed before a stable, save-ID-based episode is queued.
Concurrent adds share generation and repeated adds reuse audio without duplicating
queue entries. Adding a readout does not start or interrupt playback.

Readouts live in Music’s private `Podcasts/ReaderAudio` directory and survive
deletion of the source save. They support podcast transport, seeking, speed,
listening progress, queue ordering and restoration alongside RSS episodes.
**Remove Readout** deletes Music’s copy (after selecting another episode if it is
current); it does not delete the Reader save or shared Gemini sections. Missing audio is regenerated on an
explicit add. Container URLs are rebased when the Music sandbox moves.
Readouts are excluded from RSS refresh, URLSession downloads and their byte budget,
and podcast iCloud uploads/imports. No Reader text, metadata or audio is uploaded
by podcast sync. Podcast follow and automatic-download behavior stays independent.

Validation: Xcode 26.2 / iPhone 17 Pro / iOS 26.2. All 46 Foundation podcast
tests, 12 focused Music tests, 20 focused Reader tests and two UI checks passed.
Coverage includes actual speech-to-M4A rendering and playback after a podcast,
selection order, concurrent duplicate adds, queue restoration, failed-render
cleanup/retry, readout removal, Reader menu installation checks, cloud exclusion,
and warm/cold Reader routes. The UI saved-item route rendered an existing text
save and verified its title in the podcast queue. Root, browser and queued-state
screenshots were visually inspected. Physical-device/background playback was not
measured.

Streaming/readout replacement validation (2026-10-28): focused Reader/audio and
Music integration simulator suites pass, including actual device-voice rendering
and podcast-to-Reader playback followed by the original save's read transition.
Live Google synthesis has not been exercised with a user credential.

## System automation

See [composable-automation.md](composable-automation.md) for the App Entity and
App Intent surface, mutation notifications, change tokens and the Reader-to-Music
Shortcuts workflow.

## YouTube audio through Luna Mac (2026-11-01)

The Podcasts root places **Add YouTube Audio** below Home, and Home offers the
same action. It accepts pasted watch, `youtu.be` share, Shorts, live-video and
embed links, including sharing/tracking parameters. The action is absent until
the paired Mac advertises this capability; older companions and unavailable
connections quietly hide it. A previously downloaded episode remains playable
without the Mac or these tools.

Luna Mac checks Homebrew's standard Apple Silicon/Intel locations and its PATH,
queries the installed `yt-dlp` formula, and verifies that formula's executable.
A standalone/pip installation does not enable the feature. Detection runs at Mac
startup; **Settings → Audio → Check for YouTube Audio** checks again. Nothing is
automatically installed, and an unavailable feature has no iOS setup/upsell UI.
Homebrew's yt-dlp dependencies supply its JavaScript runtime through the brew
prefix's bin directory, including when Luna Mac launches without a shell PATH.

`CompanionYouTubeAudio` serves jobs over the existing authenticated Music RPC.
It passes canonical single-video URLs to yt-dlp as arguments, never shell text,
and disables user configuration and plugin directories. Extraction requests
`bestaudio[ext=m4a][protocol=https]` with `--skip-download --dump-single-json`.
Only an audio-only M4A HTTPS result is handed to iOS, with its HTTP headers and
metadata. This selects natively playable AAC/M4A without adding ffmpeg or
performing a lossy conversion. A video without that format fails explicitly.
A tool failure runs `brew update`, then `brew upgrade yt-dlp`, and retries once;
concurrent upgrades are shared and further upgrade attempts are limited to once
per 15 minutes. Failed upgrades stop the job. Jobs are polled rather than keeping
an RPC open through extraction, Homebrew work or downloading.

The direct iOS leg uses the existing background podcast URLSession, including
cellular-download policy and task restoration. HTTP/media rejection or an
unplayable response asks the Mac to download the audio with yt-dlp, then reads
bounded 512 KiB ranges over the paired connection. Offline/DNS/timeout errors,
cancellation, denied cellular data, and local storage failures do **not** trigger
a Mac download. TLS/connection failures are retryable as iOS download failures.
An interrupted Mac transfer can be retried from podcast download management;
the Mac must stay awake and reachable, and iOS may interrupt this app-owned leg
when its background execution time expires.

Successful files enter the ordinary podcast download manifest, byte budget,
queue-priority scheduler, offline player and played-file cleanup. Failed requests
remain retryable in **Settings → Manage Downloads**. Queue removal/preemption
cannot install a stale result. A queued YouTube item waits for its owned audio;
the canonical YouTube webpage is never passed to AVPlayer as a stream.
The library stores only the stable video ID and canonical page URL. Expiring
media URLs/headers stay out of library and download manifests; the background
URLSession owns its pending request. These device-local episodes are excluded
from podcast iCloud sync. Mac temporary files are released after transfer or
failure and abandoned jobs/files expire after 24 hours.
