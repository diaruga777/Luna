# Luna Vault on Syncthing — plan

Status: PLANNING 2026-09-15. Supersedes the custom Mac protocol, the
client-side encryption tier, and the device/iCloud storage locations.

Luna Vault becomes a partial Syncthing peer. The Mac holds the files in a
plain folder. The iPhone keeps every file's name and metadata, a bounded
content cache, a full-text and vector index, and tiny thumbnails. The two
talk Syncthing's Block Exchange Protocol (BEP v1) over TLS 1.3, so the Mac
side can be either vanilla Syncthing or the Luna Vault Mac companion.

Decisions locked with the owner on 2026-09-15:

1. TLS and connection establishment run in Go inside the vendored
   `LibTailscale.xcframework` build. Swift owns BEP and everything above it.
2. The Mac companion stays, rewritten as a small BEP peer.
3. Device and iCloud locations and the root-key crypto tier are deleted. The
   Mac stores plaintext. iOS relies on Data Protection.
4. iOS writes are add and delete only. No rename, move, or edit in v1.
5. iOS sends an honest index: only the files it created and still holds.
6. Pairing is by device ID, typed or scanned on both sides. Nice-to-have:
   scan once, and the other side accepts automatically.
7. No local discovery in v1 (needs the multicast entitlement). Manual
   address fallback instead.
8. Content cache 500 MB default, reindex scratch 2 GB default. Both are also
   capped at free space minus 200 MB.
9. Transcription: SpeechAnalyzer on iOS 26, on-device SFSpeechRecognizer in
   60 s chunks below that.
10. Existing Vault data is dropped without migration.

## 0. Measured facts the design rests on

- **Syncthing 2.x certificates are Ed25519, and Apple TLS cannot negotiate
  them.** Probed 2026-09-15 with Network.framework against Syncthing 2.1.5
  on this Mac: the server logs `tls: peer doesn't support any of the
  certificate's signature algorithms`. SecureTransport has no TLS 1.3, and
  BEP requires TLS 1.3. So the TLS engine is Go's `crypto/tls`.
- **A Syncthing peer compresses per its own settings.** Advertising
  `COMPRESSION_NEVER` changes nothing. Every message the Mac sends above
  128 bytes arrives as an LZ4 block. Decoding is mandatory; encoding is not.
- **BEP is pull-based.** A peer only sends `Request`s for blocks the other
  side's index advertises. The Mac never pushes a file to iOS.
- **An empty Index is legal.** Syncthing Lite did exactly this. The peer
  shows the partial device as out of sync and does nothing else.
- **The certificate must carry `CN=syncthing`** or Syncthing closes the
  connection after Hello. Exactly one certificate in the chain.
- **Global discovery returns LAN addresses.** `announceLANAddresses`
  defaults to true, so a same-LAN peer finds the direct address through the
  public lookup server.
- Syncthing v2's `go.mod` keeps the unsuffixed module path, so its packages
  cannot be imported with `go get`. The Go layer is stdlib only.
- The full wire reference compiled for this work is
  `claudedocs/vault-bep-reference.md` (copied from the research scratchpad).

## 1. Components

```
iPhone                                          Mac
┌──────────────────────────────┐                ┌──────────────────────────────┐
│ LunaVaultUI                  │                │ LunaVaultMacCompanion (menu  │
│ LunaVaultSync (folder model, │                │   bar app)                   │
│   cache, reindex, sessions)  │                │ LunaVaultMacPeer (scanner,   │
│ LunaVaultSearch / Extraction │                │   index db, BEP server)      │
│ LunaVaultBEP  (protobuf,     │◄── BEP/TLS ───►│ LunaVaultBEP                 │
│   framing, LZ4, state)       │                │                              │
│ LunaVaultNet (Swift shim)    │                │ LunaVaultNet                 │
│ lunabep (Go: TLS, dial,      │                │ lunabep (Go: TLS, listen,    │
│   relay client, discovery)   │                │   relay join, announce)      │
│ tsnet                        │                │ tsnet                        │
└──────────────────────────────┘                └──────────────────────────────┘
                     or: vanilla Syncthing on the Mac
```

### 1.1 `lunabep` — Go connection layer (in the libtailscale C archive)

Source: `LunaVaultTailscale/GoSources/lunabep/*.go`. `scripts/build_libtailscale.sh`
copies these files into the libtailscale clone as extra `package main` files
before `go build -buildmode=c-archive`, so the exports land in the same
archive as `tailscale_*`. Stdlib only. `go test` runs on macOS from the
clone. Exports:

| C export | Purpose |
| --- | --- |
| `lunabep_identity(dir, out_device_id)` | Load `cert.pem`/`key.pem` from `dir` or create them (ECDSA P-256, `CN=syncthing`, SAN `syncthing`, 20 years). Returns the device ID string. Swift applies Data Protection to `dir`. |
| `lunabep_dial(dir, address_url, expected_device_id, ts_handle, out_fd)` | Dials `tcp://host:port` (plain TCP or through tsnet when `ts_handle != 0`) or `relay://host:port/?id=…` (relay client flow, then session join). TLS 1.3 client, ALPN `bep/1.0`, verifies SHA-256(peer DER) == expected. Bridges plaintext to a socketpair; returns one end. |
| `lunabep_lookup(device_id, out_json)` | Global discovery GET on the default lookup server. Returns the addresses JSON or a `Retry-After` value. |
| `lunabep_listen(dir, bind_address, ts_handle, out_listener)` | TLS server listener on TCP or tsnet. |
| `lunabep_relay_join(dir, relay_url, out_listener)` | Joins a relay (answers pings, receives invitations, joins sessions, TLS server role). Presents as a listener. |
| `lunabep_relay_pick(out_url)` | Fetches the public pool, picks the lowest-latency relay. |
| `lunabep_accept(listener, out_fd, out_peer_device_id)` | Blocks for the next authenticated connection. Swift decides whether the peer is known. |
| `lunabep_announce(dir, addresses_json, out_reannounce_seconds)` | POST to the default announce servers with the client certificate. |
| `lunabep_close_listener(listener)` | |

Every connection reaching Swift is already mutually authenticated and
plaintext. Timeouts: TCP dial 10 s, TLS 10 s, relay invitation 10 s.

### 1.2 `LunaVaultNet` — Swift shim (LunaVaultTailscale package)

Wraps the exports above as `VaultPeerDialing` / `VaultPeerListening`
witnesses (protocols in `LunaVaultBEP`), owns the identity directory, and
routes `.tailscale` endpoints through the existing `VaultTailnetNodeRunner`.
Only the Vault app, the companion, and `LunaVaultTests` link it.

### 1.3 `LunaVaultBEP` — Swift protocol library (LunaLibraries, Foundation only)

- `ProtobufReader`/`ProtobufWriter` (varint, LEN, unknown-field skipping,
  packed and unpacked repeated scalars).
- Message types: `Hello`, `Header`, `ClusterConfig` (Folder, Device),
  `Index`, `IndexUpdate`, `FileInfo`, `BlockInfo`, `Vector`/`Counter`,
  `Request`, `Response`, `DownloadProgress` (decode only), `Ping`, `Close`.
- `BEPFraming`: Hello magic + length, header/message frames, 500 MB cap,
  `LZ4Block.decode(src, uncompressedLength)`.
- `DeviceID`: parse (52/56 chars, typo fixes), format, luhn32, short ID.
- `VersionVector`: update (`max(old+1, unixNow)`), compare, merge, sorted
  counters.
- `BlockLayout`: block size table, block list hashing (CryptoKit SHA-256),
  `blocksHash`, empty-file block.
- `BEPByteStream` protocol with `FileDescriptorByteStream` and an
  in-memory `PipeByteStream` pair for tests.
- `BEPConnection` actor: Hello exchange, ClusterConfig-first rule, request
  multiplexing by id, 45 s ping, 300 s receive timeout, `Close`, and a
  `BEPConnectionDelegate` (protocol, weak) receiving index batches, requests,
  and lifecycle events. Both platforms use it.

### 1.4 iOS folder model — `LunaVaultSync` rewritten, `LunaVaultStorage` rewritten

`vault.sqlite`, schema version 1 of the new line (the old file is deleted on
first launch). Tables:

- `peer` — the one paired Mac: device id, name, network mode, manual
  addresses, folder id, folder label, stored `index_id`/`max_sequence` for
  delta resume, our own `index_id` and sequence counter.
- `files` — mirror of the Mac's index plus local state: `name` (PK), `type`,
  `size`, `modified_s`, `modified_ns`, `modified_by`, `deleted`, `invalid`,
  `version` (blob), `sequence`, `block_size`, `blocks` (blob: 32-byte hashes
  concatenated; sizes derive from block_size and size), `blocks_hash`,
  `first_seen`, `content_date` (from EXIF/QuickTime/PDF metadata when
  indexed), `needs_index` (dirty bit), `indexed_blocks_hash`,
  `thumbnail_blocks_hash`, `cache_blocks_hash`, `cache_bytes`,
  `cache_last_access`, `cache_pinned`.
- `local_changes` — iOS-originated adds and deletes awaiting confirmation
  from the Mac's index: name, version, blocks, staged path, created_at.
- `settings` — cache quota, reindex scratch quota, network mode.

Identity is the folder-relative `name`, as in BEP. A changed `blocks_hash`
is a content change: it sets `needs_index`, invalidates the cached copy and
thumbnail.

Directories under the App Group, all `completeUntilFirstUserAuthentication`:
`VaultCache/` (plaintext content by name hash), `VaultScratch/` (reindex
downloads), `VaultThumbnails/` (existing store, rekeyed by name +
blocks_hash), `VaultIdentity/` (cert and key), `VaultStaging/` (imports).

### 1.5 Sessions and polling

`VaultSyncSession` (one connection): resolve addresses in the chosen network
mode → dial → Hello → ClusterConfig (our entry `index_id`/`max_sequence` from
`peer`, peer entry with stored values so the Mac sends deltas) → send our
`Index` (files in `local_changes` plus confirmed iOS-created files still
cached) → apply incoming `Index`/`IndexUpdate` to `files` transactionally →
serve `Request`s from the cache for our own files → run the fetch queue.

Address resolution:
- `.syncthingPublic` (default): `lunabep_lookup` → `tcp://` addresses first
  (LAN before WAN), then `relay://`. Cache the lookup for the
  `Retry-After` or 10 minutes.
- `.tailscale`: `tcp://<tailnet host>:<port>` through tsnet.
- Manual addresses (either mode) are tried first when present.

Lifecycle (`VaultConnectionController`): connect on foreground and stay
connected — the Mac pushes `IndexUpdate` live, so new files appear without
polling. Every 60 s while foregrounded: reconnect if the session dropped.
Pull-to-refresh: force a fresh lookup and reconnect, then run the queue.
Background: `applicationDidEnterBackground` closes the session and submits
the nightly `BGProcessingTask` (`requiresNetworkConnectivity`, earliest
begin 01:00 local, re-submitted after each run).

Nightly task order, each step budgeted and resumable: connect and sync the
index → confirm pending local changes → cache refresh (re-fetch cached
files whose `blocks_hash` changed, evict expired) → reindex dirty files →
thumbnails → disconnect → resubmit.

### 1.6 Content cache

`VaultCacheManager`. Effective quota = `min(userQuota, freeSpace − 200 MB)`,
recomputed at each admission. Admission never refuses a file for size: a
file larger than the quota is admitted alone and everything else is evicted.
Eviction order: expired (24 h since last access) first, then LRU, never a
pinned entry (active preview, or an iOS-created file the Mac has not
confirmed). Access on open, on import, and on fetch completion.

`VaultBlockFetcher`: up to 8 outstanding `Request`s per file, SHA-256
verified per block, written to a temp file, then installed atomically with
its `blocks_hash` recorded. Serves both the cache (user opens a file) and
the reindex scratch (separate destination and budget).

### 1.7 iOS writes

Import: copy into `VaultStaging/`, hash blocks, insert into `files` with
`version = [Counter(ourShortID, max(1, now))]`, `modified_by = ourShortID`,
`no_permissions = true`, `sequence = next`, move into the cache pinned, add
a `local_changes` row, send `IndexUpdate`. Serve the Mac's `Request`s from
the cache. When the Mac's index reports the file with a version ≥ ours, the
change is confirmed: unpin, drop the `local_changes` row. Delete: set
`deleted`, clear blocks, bump our counter, send `IndexUpdate`, remove cache,
thumbnail, and index entry; keep the tombstone row. Confirmation as above.

An unconfirmed change survives relaunch and is re-announced on every
session. A file the Mac reports with a strictly newer concurrent version
wins; our copy is dropped (no edit in v1, so this only happens if the user
also changed the file on the Mac).

### 1.8 Indexing

Kept: `LunaVaultIndexExtraction` (routing, bounded chunking, PDF/DOCX/EPUB/
HTML/RTF text, archive preflight), `LunaVaultSearch` (FTS5 + vector +
groups), `LunaVaultEmbeddings` (protocol).

Changed:
- Real adapters wired in `KindWiring+Vault`: `SystemVaultVisionOCR`,
  `VaultSpeechAnalyzerTranscriber` (new, iOS 26, mirrors
  `LunaTranscribe`'s analyzer use without linking it, since LunaTranscribe
  depends on LunaSaves) with `SystemVaultSpeechTranscriber` chunked at 60 s
  below iOS 26.
- `NLContextualEmbeddingGenerator` (new): language detection,
  `requestAssets`, mean-pooled token vectors, L2-normalised, dimension read
  at runtime; `NLEmbedding.sentenceEmbedding` fallback. Model version string
  includes the asset identifier so a model change reindexes.
- Embeddings become per chunk: `embeddings(object_id, chunk_index,
  model_version, values)`, up to 32 chunks per file; a query scores a file
  by its best chunk.
- `documents` keyed by file `name`; `created_at` = `content_date` if any,
  else `modified`; `updated_at` = BEP `modified`.
- `VaultReindexRunner` replaces `VaultIndexWorker`: claims dirty files
  (`needs_index = 1`, not deleted, type FILE), fetches up to 3 in parallel
  into `VaultScratch/` under `min(scratchQuota, freeSpace − 200 MB)`,
  extracts, embeds, generates the thumbnail, upserts the search document,
  sets `indexed_blocks_hash`, deletes the scratch file. Deleted files are
  removed from the index in the same transaction that records the
  tombstone. Runs opportunistically while foregrounded (low priority, pauses
  while the user fetches) and in the nightly task.
- Content dates: EXIF `DateTimeOriginal`, QuickTime creation date, PDF
  `CreationDate`, DOCX `dcterms:created`, else none.

### 1.9 Search with dates

`VaultDateQueryParser` strips date terms from the query and produces a
range: month names ("October" → the most recent October not in the future),
"October 2023", "2023", "yesterday", "today", "last week", "last month",
"this year", ISO `2023-10-05`, `10/2023`. Matching: `created_at` OR
`updated_at` within the range. A date-only query lists files in the range
by date. Text plus date filters the hybrid results.

### 1.10 Thumbnails

Generated during the reindex fetch and on user open, for images, video,
PDF and audio artwork. Target 96 × 96 pt at 3× (288 px longest side), HEIC
or JPEG, kept in the existing `VaultThumbnailStore` rekeyed by (name,
blocks_hash). Quota 64 MB, no expiry; invalidated on content change or
delete.

### 1.11 UI (iOS)

- Home: search field, connection status line (Connected · Syncing · Offline
  · Not paired), recents rail, results with thumbnails, snippets and date
  chips, pull-to-refresh, and a Browse entry (folder tree from `files`).
- Settings → Mac: pairing (our device ID as text + QR; scan or type the
  Mac's ID; folder acceptance), network mode (Syncthing public / Tailscale),
  manual addresses, Tailscale login/logout (existing screen), Unpair.
- Settings → Cache: quota slider, usage, clear.
- Settings → Search index: reindex status, rebuild.
- Security and Storage screens are removed.

### 1.12 Mac companion — `LunaVaultMacCompanion` rewritten

A menu-bar accessory app (AppKit `NSStatusItem`, no bundle), built as the
existing SwiftPM executable. Library `LunaVaultMacPeer` (LunaLibraries,
macOS only by usage) holds the logic:

- `FolderScanner`: full scan on start and every 60 s, plus FSEvents
  triggers; skips `.stfolder`, `.stignore`, `.stversions`, temp prefixes;
  hashes blocks with an mtime+size cache in `companion.sqlite`; assigns
  `sequence` and version vectors; maintains the `.stfolder` marker.
- `CompanionIndex` (`companion.sqlite`): files, peers, per-peer index
  state.
- `CompanionServer`: accepts on TCP `0.0.0.0:22000` (configurable), on the
  relay, and on the tailnet; per connection a `BEPConnection`; sends
  ClusterConfig and full or delta Index; serves `Request`s from disk with
  hash verification; applies the iPhone's `IndexUpdate` by pulling blocks
  into `.syncthing.<name>.tmp` and renaming; applies deletes; re-announces
  to global discovery on the `Reannounce-After` cadence.
- Pairing mode: "Pair iPhone…" shows a window with the QR and text of the
  Mac's device ID and, for five minutes, holds any unknown connecting device
  for a one-click Accept that shows its ID.
- Menu: status, connected devices, folder chooser, network toggles
  (Syncthing public on/off, Tailscale connect/logout), device ID copy,
  Pair iPhone…, Quit.

Companion ↔ vanilla Syncthing is not a v1 requirement but should work, and
a live script (`scripts/vault_interop.sh`) uses a local vanilla Syncthing as
the oracle for the companion's server side.

## 2. What is deleted

`LunaVaultCrypto`, `LunaVaultBackend` (Mac protocol, iCloud, device
backend, tailnet control protocol moves to `LunaVaultNet`), old
`LunaVaultMac`, old `LunaVaultSync`, `VaultImportCoordinator`'s encryption
and remote-import paths, `VaultSetupCoordinator`'s root-key flow, iCloud
entitlements and Info.plist keys, `VaultTailscaleFrameChannel`,
`VaultTailnetListener`'s frame server, and the tests for all of these.
`claudedocs/vault-crypto.md`, `vault-storage-backends.md`, `vault-mac.md`,
`vault-stage5.md` are replaced by `claudedocs/vault.md`, `vault-bep.md`,
`vault-mac-companion.md`; `vault-indexing.md`, `vault-search.md`,
`vault-storage.md`, `vault-testing.md`, `vault-topology.md` are rewritten.

## 3. Work packages

Wave 0 (lead, sequential — the seams everyone else builds on):
- W0.1 `LunaVaultBEP` protobuf codec, messages, framing, LZ4, DeviceID,
  VersionVector, BlockLayout, byte streams, `BEPConnection`. Tests: golden
  bytes from the reference (Header, Counter, Hello), round trips, LZ4
  vectors, luhn32 against known IDs, connection state machine over pipes.
- W0.2 Go `lunabep` + `scripts/build_libtailscale.sh` changes + rebuilt
  xcframework + `LunaVaultNet` shim. Go tests: identity, device ID, relay
  XDR, in-process dial/listen TLS round trip, discovery against
  `httptest`. Live check: `lunabep_dial` against the local Syncthing.
- W0.3 New `vault.sqlite` schema and `VaultFolderStore` (files, peer,
  local_changes, settings) with the dirty-bit and cache-state transitions.

Wave 1 (parallel agents, one owner per module):
- W1.A iOS sessions: `VaultSyncSession`, `VaultConnectionController`,
  address resolution, `VaultBlockFetcher`, `VaultCacheManager`, writes
  (import/delete/confirm), BG task.
- W1.B Indexing: `VaultReindexRunner`, real OCR/speech adapters,
  `NLContextualEmbeddingGenerator`, per-chunk embeddings, content dates,
  thumbnails rekeyed, `VaultDateQueryParser`, search integration.
- W1.C Mac companion: `LunaVaultMacPeer` + menu-bar app.
- W1.D iOS UI: home changes, Browse, Settings rewrite, pairing screens
  with QR, `KindWiring+Vault` composition, Info.plist/entitlement cleanup.

Wave 2 (lead): deletions, docs, `scripts/run_vault_tests.sh` update,
interop script, full suite on a fresh simulator, live check iPhone
simulator ↔ vanilla Syncthing and ↔ companion, merge.

## 4. Testing

- `LunaVaultTests` stays deterministic: BEP over in-memory pipes, a
  `FakeSyncthingPeer` (Swift) that speaks the wire format from the
  reference, store transitions, cache policy, date parser, reindex runner
  with fake extraction.
- Go tests in the clone via `scripts/build_libtailscale.sh --test`.
- Live: `LUNA_VAULT_LIVE_SYNCTHING=127.0.0.1:22000` runs a simulator test
  against the Homebrew Syncthing (removed when the work is done).
- `scripts/vault_interop.sh`: companion ↔ vanilla Syncthing on this Mac.

## 5. Open questions for the owner

See the conversation of 2026-09-15; answers are folded into §0 decisions.
