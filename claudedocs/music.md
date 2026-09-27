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

The library shows playlists, artists, albums, songs and downloaded songs, plus
recent albums. Search covers song titles, album titles, artist names and
playlists. Playlist creation and adding songs use the public media-library APIs;
errors are presented instead of reporting an unsuccessful edit as saved.

Selecting a song anywhere starts it first. Among playlists containing that song,
the most recently **successfully played in Luna Music** wins. With no matching
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
Shortcuts, widgets, Control Center and the queue Live Activity. The app and
widget use the family App Group for a small, separate music state snapshot.

The UI is implemented with public UIKit components. Apple Music's private UI,
catalog lyrics, Sing, AutoMix and download-management interfaces are not
available through this implementation. Dedicated CarPlay browsing requires
Apple's `com.apple.developer.carplay-audio` entitlement and is not enabled.
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
