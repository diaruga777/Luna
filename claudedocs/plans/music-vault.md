# Luna Music: Apple library and Vault files

## Plan

1. Use source-qualified song and playlist identities throughout the existing UI,
   playback queue and system integrations. Match artist and album names across
   sources. Persist Vault playlists independently; reject mixed-source writes.
2. Serve `Music/<Artist>/<Album>/<file>` under the selected Mac Vault root over
   the existing paired TLS/BEP connection. Index common native AVFoundation
   formats and reuse extracted metadata for unchanged files. No transcoding.
3. Feed authenticated, version-checked byte ranges to AVPlayer using its resource
   loader. Bound temporary buffering, retry transient connections, and cancel
   obsolete requests. Complete private iOS cache files play directly from disk.
4. Persist manual cache pins and automatic cache policy separately. Default to
   the top three played Vault playlists, adjustable from zero to ten. Reconcile
   membership without evicting manual downloads. Explicit cache deletion suppresses
   automatic re-download until manually requested again.
5. Expose caching for songs, playlists, artists and albums, plus Settings for
   pairing, policy and cached-song deletion. Preserve search, player, queue,
   transport, Siri and CarPlay behavior.
6. Verify source rules, persistence, grouping, catalog/range validation, download
   integrity, cache reconciliation, queue behavior, builds and simulator UI.
   Commit logical stages, merge into main and remove the task worktree.

## Decisions

- `/Music/` means the Music directory inside the selected Vault folder, alongside
  Photos. Existing artist/album subfolders are discovered automatically.
- Formats: MP3, M4A (including ALAC), MP4, AAC, WAV, AIFF/AIF, CAF and FLAC where
  AVFoundation reports a playable audio track. Video containers play their audio.
- Metadata tags take precedence; artist/album directory names and filename are
  fallbacks. Album grouping includes album artist to avoid merging unrelated albums.
- The auto-cache count ranks Vault playlists by successful playback starts, then
  most recent play, then stable ID. Never-played playlists are not auto-cached.
- The cache is local to Luna Music, excluded from backup; eviction never sends a
  Vault delete/tombstone or changes Mac files. Catalog and playlists survive offline.
