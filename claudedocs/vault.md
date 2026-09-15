# Luna Vault

Luna Vault is a local-first file surface backed by one paired Mac folder. The
Mac keeps the plaintext folder; iPhone keeps the mirrored index, a bounded
plaintext cache, thumbnails, and on-device search data protected by iOS Data
Protection.

The peer wire is Syncthing BEP v1. TLS 1.3, certificate identity, discovery,
relay, and optional tsnet dialing live below Swift in `lunabep`. Swift owns the
authenticated BEP session and all Vault policy. The iPhone never accepts an
unauthenticated stream.

## v1 policy

- One paired Mac and one folder.
- iOS may add and delete files; it does not rename, move, or edit them.
- The iPhone announces only local files that it created and still retains.
- File dates are the BEP modification time. Creation or embedded content dates
  are intentionally ignored.
- The foreground app keeps one session alive. A 60-second check reconnects a
  dropped session; pull-to-refresh forces fresh address discovery.
- Background processing syncs the index, confirms local changes, refreshes the
  cache, reindexes dirty files, and regenerates thumbnails in resumable steps.
- The default cache quota is 500 MB and the reindex scratch quota is 2 GB;
  both are capped at free space minus 200 MB.
- Search stores at most eight Float16 embedding chunks per file.

## Storage

`vault.sqlite` is the source of truth for the iPhone mirror. Its `files` table
contains the Mac index plus dirty/indexed/cache/thumbnail state. `peer` stores
the single pairing and index resume cursors; `local_changes` makes iOS writes
durable across relaunch; `settings` stores quotas and network mode.

Cached content, scratch files, thumbnails, staging imports, and the identity
certificate live below the Vault App Group directory and use
`completeUntilFirstUserAuthentication` on iOS.

## Pairing and networking

The companion is a SwiftPM menu-bar accessory. Pairing is a Mac QR/text device
ID plus one Accept click on the Mac; typing the ID is the fallback on either
side. The companion owns an embedded tsnet node. The iPhone can use Syncthing
public discovery/relay, Tailscale, or manually entered addresses. The existing
Vault share extension remains unchanged.

## Module boundaries

- `LunaVaultBEP`: Foundation/CryptoKit protocol codec, framing, IDs, vectors,
  blocks, and connection actor.
- `LunaVaultStore`: iPhone SQLite mirror and cache-state transitions.
- `LunaVaultSync`: sessions, reconnection, block transfer, and local changes.
- `LunaVaultSearch` and `LunaVaultIndexExtraction`: on-device index and search.
- `LunaVaultMacPeer`: folder scanner, companion index, and BEP peer behavior.
- `LunaVaultTailscale`: Go transport archive and Swift transport shim.
- `LunaVaultUI`: iPhone browse, search, pairing, cache, and index surfaces.

The older root-key crypto, iCloud/device backends, and custom Mac frame
protocol are not part of this design.
