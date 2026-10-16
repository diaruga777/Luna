# Luna Vault

Mac setup, restored connections, account credentials, and adaptive companion UI are
shared across Vault, Music, and Code. See [One Luna Mac connection](mac-connection.md).

Luna Vault is a file browser for one paired Mac, with one indexed, writable Vault folder. The
Mac keeps the plaintext folder; iPhone keeps the mirrored index, a bounded
plaintext cache, thumbnails, and on-device search data protected by iOS Data
Protection.

The peer wire is Syncthing BEP v1. TLS 1.3, certificate identity, discovery,
relay, and optional tsnet dialing live below Swift in `lunabep`. Swift owns the
authenticated BEP session and all Vault policy. The iPhone never accepts an
unauthenticated stream.

## v1 policy

- One paired Mac and one indexed, writable folder. **Mac Files** browses the
  rest of the Mac on demand, read only, subject to the companion’s macOS permissions.
- Browse opens with Mac Files, Vault Folder, Downloads, a separate Transfers
  screen, and the Vault root’s files/folders. Search covers only Vault contents.
- External Mac files download to temporary previews. Quick Look’s Share action
  can save a copy; closing the preview removes the temporary download. They never
  enter the mirror, offline cache, content search, or sync announcements.
- The active iOS UI imports files and folders, previews files, and confirms deletion
  from Vault root/search/folder rows. Downloads lists current local copies for offline
  use. Rename, move, and edit are not exposed.
- Folder import stages its visible regular files and directories (including
  empty directories) under the selected folder name. It is a one-time import;
  later source-folder edits are not watched on iOS. Hidden entries and links
  are excluded because the Mac scanner does not index them. Existing Mac
  directories can be reused; conflicting file names are rejected.
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
The import sheet stays open through the Mac's index acknowledgement, which
arrives after the companion has written the bytes. Hiding the sheet lets the
import continue while the app is open; Browse shows the pending item count; Transfers shows per-file progress and cancellation
until a later connection confirms it. A transport failure is shown as pending
rather than a false successful import.

## Pairing and networking

The companion is a SwiftPM app with a window and menu-bar item. Copy its
pairing code into iPhone Settings, then Accept on the Mac. The code includes
the Mac's certificate identity and direct addresses. The iPhone reports
success only after authentication and a real initial-index exchange. Both
home and Settings use the same durable peer. A separately installed Tailscale
client can provide routing; the active runtime does not start embedded tsnet.
Public discovery/relay publication and the legacy share extension are not
wired into this runtime. See [the pairing repair](vault-pairing-repair.md) for
current behavior, test commands, and remaining boundaries.

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

## Read-only Mac browser

`VaultMacBrowseProtocol` is a Luna-specific extension on the authenticated BEP
connection. It uses Request/Response in the reserved `luna-mac-browser-v1`
namespace for locations, paged directory listings, file stat, and bounded reads.
It is never advertised as a sync folder, and incoming indexes in this namespace
are ignored. Older companions return a clear update message.

The Mac delegate checks pairing authorization before routing browser requests.
`CompanionMacBrowser` opens files with read-only descriptors, rejects special
files, follows links for browsing, and reads at most 1 MiB per request. Each
read checks device/inode, size, mtime, and ctime before and after the read;
the phone checks again at completion. Changed files fail instead of producing a
mixed preview. Downloads check available disk space, support cancellation, and
remove partial files on failure. TLS authenticates live browser replies;
ordinary indexed BEP blocks retain their SHA-256 checks.

Directory listings are 256 entries per page, hide dotfiles by default, and never
recurse or persist in an index. The UI offers Show Hidden Files and Go to Folder.
macOS Files and Folders / Full Disk Access can restrict access; the phone shows
an actionable error. `/` and `/Volumes` expose the filesystem and mounted disks.
Only the existing `vault` sync namespace can create, replace, or delete files;
its folder-relative path and symlink restrictions remain in force.
