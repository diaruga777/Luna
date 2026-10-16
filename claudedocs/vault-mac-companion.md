# Luna Vault Mac companion

The companion is the Mac-side BEP peer and a small menu-bar accessory built
from the existing SwiftPM executable. It has no Xcode application target.

The companion chooses one shared folder and stores its index in
`companion.sqlite`. On an authenticated reconnect it sends the saved snapshot
before rescanning the folder. Rescans run every five seconds on a dedicated
filesystem queue. Syncthing metadata folders, temporary files, and ignored
folders are skipped. The scanner reuses block hashes when mtime and size are
unchanged.

The server accepts authenticated BEP streams on the configured TCP listener,
relay listener, or tailnet listener. Each accepted peer must be paired before
its index is applied. The server sends `ClusterConfig` and a full or resumable
index, serves requested blocks directly from disk with hash verification, and
pulls iPhone-created blocks into a temporary file before atomic installation.
It enables serving before advertising the saved index, so Code, Music, and
Mac browsing can start even while a Vault folder scan or macOS permission probe
is pending. Fresh scan results follow as a full index. Folder access errors
appear in the companion and are retried without closing the shared connection.
Block serving still checks the indexed hash against current disk content.
Changing the selected folder clears its previous snapshot before advertising it.
Deletes become tombstones in the index and remove the local file only after
the protocol has accepted the change.

Upload staging has a stable name for each file version. On reconnect the Mac
hashes completed blocks in that staging file, reports them to the phone, and
requests only the remainder. New blocks use a rolling window of up to eight
requests, capped at 32 MiB of payload. Out-of-order responses are written at
their verified offsets; staging is synchronized every 32 MiB and before atomic
installation. Reconnect verifies the contiguous completed prefix and safely
truncates any incomplete or out-of-order tail before resuming. Individual
block requests time out even if
connection pings continue. The folder scan preserves confirmed iPhone versions
and tombstones across reconnects. It reuses block hashes for files whose size
and modification time are unchanged, avoiding repeated reads of large files.
Deletion checks the indexed version and on-disk content before removing a file;
it leaves a newer or locally changed Mac file alone.

Pairing mode lasts five minutes and displays the Mac device ID as QR/text. A
new iPhone is shown with its ID and an Accept button. The menu exposes status,
folder selection, public-discovery and Tailscale toggles, device-ID copying,
Pair iPhone, and Quit.

## Read-only browsing beyond Vault

The paired iPhone can request live locations, directory pages, and regular-file
reads from anywhere the companion is allowed to read. `CompanionMacBrowser`
serves these through the versioned Luna browser namespace after the same pairing
gate as Vault sync. No browser path is scanned recursively or stored in
`companion.sqlite`; only the selected Vault folder is indexed and writable.

Home/Desktop/Documents/Downloads, `/`, and `/Volumes` are offered as locations.
Symbolic links can be followed for reads. Writes still use the original
folder-relative, link-rejecting sync path. The pairing dialog states both scopes.
For protected folders, grant the companion Files and Folders or Full Disk Access
in macOS Privacy & Security. The app never changes these permissions itself.
Both the iPhone app and companion need this version for Mac Files browsing.

## Music library

Luna Music uses the same pairing through the read-only `luna-music-v1` service.
The companion creates `Music` inside the selected Vault root; use artist/album
subfolders. `CompanionMusicLibrary` indexes native AVFoundation audio metadata,
keeps a version-keyed metadata cache, and serves paginated catalogs plus bounded,
version-checked byte ranges. It never writes audio or applies Music cache deletions
to the Mac. See [music.md](music.md) for formats, playback, and iPhone cache policy.

## Recovery after network changes

Every protocol write has a 30-second deadline that closes a stalled stream;
the 20-second Hello deadline covers both writing and reading the greeting.
A blocked keepalive write therefore cannot disable dead-peer cleanup. The Mac
keeps up to eight authenticated sessions; when full, a newer approved connection
retires the oldest session instead of rejecting reconnects until a restart.
Retired delegates are revoked and their streams closed before the new exchange.

Run the focused macOS regressions with:

```sh
swift test --package-path LunaVaultTailscale --filter ReconnectTests
```

They cover blocked Hello/index/ping writes, repeated connection replacement,
folder-specific snapshot reuse, and Code requests before the Vault rescan.

## Local signing and folder permissions

`script/build_and_run.sh` signs the staged app ad hoc by default. To keep macOS
folder permissions stable across rebuilds, set `LUNA_MAC_SIGNING_IDENTITY` to
an exact valid Apple Development certificate name or SHA-1 from that Mac's
Keychain. The script verifies a supplied identity before signing and verifies
the completed bundle before launch.

Keep the bundle identifier and installed app location consistent. Certificate
signing gives rebuilds a stable designated requirement instead of the
binary-specific hash used by ad hoc signing. Moving from the old ad hoc build
may require approving folder access once for the new identity. Future builds
with a compatible signing identity should retain those grants. Permissions
remain managed by macOS; repeated folder reads do not themselves reset them.
The five-second folder checks remain enabled.
