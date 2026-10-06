# Luna Music

Standalone iOS 26 player: scheme `LunaMusic`, bundle ID
`$(PRODUCT_BUNDLE_PREFIX).music`, app module `LunaMusicApp`. Apple library songs
and Luna Vault files coexist in the same songs, artists, albums, search and
Downloaded screens. Music uses its own library state; it does not use `saves.sqlite`.
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
