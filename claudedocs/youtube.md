# YouTube Support

> YouTube is now also one entry in the platform registry (`YouTubePlatform`) —
> see `content-platforms.md` for the multi-platform architecture. It keeps its
> bespoke ingest (oEmbed + watch-later + channel-keyed suggestions) and
> `openVideo`/thumbnail path described here; `YouTubeURL` moved to `ReaderKit/`.

YouTube links are first-class reading-list items: thumbnail rows, app/in-app
playback, playlist auto-add, and a channel+title search intent. Videos are
NEVER sent to Kindle; social sharing works normally.

## Key files (`Luna/YouTube/`)

- `YouTubeURL.swift` — `videoID(from:)` (watch?v= / youtu.be / shorts / embed
  / live / v; 11-char ID validation), `watchURLString`, `appURL`
  (`youtube://watch?v=`), `thumbnailURL` (img.youtube.com hqdefault).
- `YouTubeMetadataFetcher.swift` — keyless oEmbed (title + author_name) +
  thumbnail download; protocol seam for tests.
- `YouTubePlayerViewController.swift` — in-app player when the YouTube app
  isn't installed. **Loads the /embed/ URL directly with a neutral `Referer`
  header** — loadHTMLString origins and youtube.com referers are rejected
  with errors 152/153. An injected `WKUserScript` watches the page's
  `<video>` `ended` event → mark read + dismiss. Inline + PiP config (PiP
  reachable from the fullscreen controls on device).
- `GoogleAuthClient.swift` — Google OAuth (ASWebAuthenticationSession, PKCE
  S256, redirect = reversed client ID scheme), tokens in Keychain
  (`com.hpiddy.luna.google`), auto-refresh. The OAuth client ID is **shipped
  in the app** (`YouTubeSettings.googleClientID`, a constant); users don't
  enter one.
- `YouTubeQuery.swift` — parses the intent's "channel:title" input: splits on
  the FIRST colon (titles may contain colons), drops a leading "@" from the
  channel, and strips ellipses (… and "...") from both terms.
- `YouTubeAPIClient.swift` — Data API v3 (Bearer): channel search, video
  search, playlists list/create, playlistItems insert.
  `VideoMatchSelection.bestMatch` = exact title → prefix → top result.
- `YouTubeSettings.swift` — `googleClientID`, `playlistID`/`playlistTitle`,
  `autoAddToPlaylist`.
- `WatchLaterAutoAdder.swift` — on FIRST ingest of a video (never repeat
  presses): if signed in + auto-add on + playlist chosen → add to playlist.
  It does NOT mark the item read — saved inputs always stay unread on insert.
  The real Watch Later playlist is closed to the API (since 2016);
  users pick/create a playlist (settings offers "Watch Later (Luna)").

## Ingestion & model

`ReadingListIngestor.ingest` branches on `YouTubeURL.videoID`: oEmbed fetch →
thumbnail to `Articles/<id>-thumb.jpg` → `store.saveYouTubeMetadata` (ready,
no article content) → `WatchLaterAutoAdder.videoBecameReady`. Item fields:
`youtubeVideoID`, `channelName`, `thumbnailFileName` (+ `isYouTubeVideo`).

## List behavior

- Video rows: 96×54 thumbnail with play glyph (composited in
  `videoThumbnail(for:)`), subtitle `channel · date`.
- Filter: All / Articles / Videos segmented header, persisted
  (`readingListFilter`).
- Tap: YouTube app if installed (`LSApplicationQueriesSchemes: youtube`;
  marks read on handoff) else in-app player. No reader, no RSVP swipe.
- Kindle excluded: coordinator guard, allSaves skip, double-press → ignore
  (`SavePressPolicy` isVideo), context menu hides the action.

## Settings → YouTube

Client ID field, Sign In/Out, Playlist picker (lists user's playlists +
"Create 'Watch Later (Luna)'"), Auto-Add toggle. Footer documents the Watch
Later API limitation and Google Cloud setup (create iOS OAuth client for
com.hpiddy.luna + enable YouTube Data API v3).

## Intent

`FindYouTubeVideoIntent(channel:videoTitle:)` — requires sign-in; channel
search → video search → match selection → `handleSavePress` (same dedupe-first
path as all saves) → returns saved URL. In `LunaShortcuts`.

## Tests

`YouTubeURLTests`, `VideoMatchSelectionTests`, `SavePressPolicyTests` (video
double-press), plus suggestion/social additions (see social-sharing.md).
