# Luna Music

Standalone iOS 26 library player: scheme `LunaMusic`, bundle ID
`$(PRODUCT_BUNDLE_PREFIX).music`, app module `LunaMusicApp`. The host links only
`LunaMusicKit` (the `LunaMusicCore` service and `LunaMusicUI` UIKit modules). It does
not initialize the saves database, link-ingest pipeline, CloudKit friends, or
catalog discovery. Music stays in the device's Apple media library.

## Library and playback

MusicKit requests music authorization; MediaPlayer queries expose the complete
synced/local media library, including imports that are not catalog songs.
`MPMusicPlayerController.applicationQueuePlayer` plays that library and owns
system Now Playing, remote transport controls and its queue independently of
Apple Music's app queue. There is no subscription offer, store, radio, or catalog
search. Cloud items in the user's library may stream according to Apple's
account and availability rules. Downloaded filters `isCloudItem == false`.

The library shows playlists, artists, albums, songs and downloaded songs.
There is no Recently Added section. Search covers song titles, album titles, artist names and
playlists. Playlist creation and adding songs use the public media-library APIs;
errors are presented instead of reporting an unsuccessful edit as saved.

Selecting a song anywhere starts it first. Among curated playlists containing
that song, the most recently **successfully played in Luna Music** wins. Smart
and Genius playlists are excluded from automatic continuation so a broad
automatic playlist cannot fill the queue with unrelated tracks. A song tapped
inside a playlist uses that playlist. With no matching
Luna playback history, the largest matching playlist wins (unique song count;
stable persistent-ID tie break). Remaining songs are shuffled without duplicates
or an immediate repeat of the selected song. With no containing playlist, only
the selected song is queued. Playing an album or pressing a playlist's Play or
Shuffle button explicitly uses that collection. Recency is local to Luna Music
and persists across launches. The paused queue, position and playback modes also
persist; restoring the UI does not start audio. An explicit Resume prepares
the saved queue, dropping songs no longer present in the library.

Queue operations use serialized MediaPlayer transactions. The current song and
played history stay in place while upcoming entries are reordered, removed or
inserted. The full player exposes seeking, shuffle, repeat, hardware volume and
AirPlay route selection. The OS owns the lock-screen playback panel.

## Foreground behavior

`MusicSceneDelegate` focuses a cleared library search at cold launch and every
return from background. Permission alerts and transient inactive states do not
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
System playback controls remain owned by MediaPlayer. There is no standalone
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
