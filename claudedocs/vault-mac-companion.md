# Luna Vault Mac companion

The companion is the Mac-side BEP peer and a small menu-bar accessory built
from the shared companion sources. `Luna.xcodeproj` has a native macOS app target
and shared scheme named `LunaVaultMac`; the SwiftPM executable remains available
for focused package tests.

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

Select **LunaVaultMac → My Mac** in Xcode. Run and Profile install the successfully
built app at `/Applications/Luna Vault.app`, then launch that exact bundle. The
bundle ID derives from `Config/Luna.xcconfig` as
`$(PRODUCT_BUNDLE_PREFIX).vault.mac` (currently `com.hsanabria.luna.vault.mac`).
Ordinary Build produces a signed app in DerivedData without installing it, so
Orbit can build in isolation and own its installation transaction.

`script/build_and_run.sh` uses the same native target and installer. Its default
is the canonical installed path; `LUNA_MAC_APP_BUNDLE` can select another existing
installation. It resolves the installed app's exact valid Apple Development
certificate, or accepts `LUNA_MAC_SIGNING_IDENTITY`. Ad-hoc signing is rejected.
Keep this Mac's team in ignored `Config/Local.xcconfig`; select the existing
certificate through `LUNA_MAC_SIGNING_IDENTITY` in that ignored file if multiple
certificates are available.
`LUNA_MAC_DERIVED_DATA` optionally selects a build-cache location.

`script/install_vault_mac.py` validates the new bundle's signature, bundle ID,
exact leaf certificate and existing designated requirement before stopping the
installed copy. It stages the replacement beside the destination and restores
the old bundle if replacement validation fails. Run/Profile call this installer
as a launch pre-action; their executable path is the canonical installed app.
Permissions remain managed by macOS; pairing and folder-access identity stay
with that same bundle and certificate.

The Mac icon comes from `Design/IconComposer/Luna Vault.icon`, rendered for macOS
with transparent corners into `LunaVaultMac/Assets.xcassets/AppIconVaultMac.appiconset`.
Regenerate with `DEVELOPER_DIR=<Xcode>/Contents/Developer
scripts/export_vault_mac_icon.sh`. Xcode compiles the asset catalog and declares
`CFBundleIconFile = AppIconVaultMac`, with a matching ICNS in Resources. Orbit
reads the installed bundle icon into its shared Mac/iOS catalog thumbnail.

## Transfer priority and App Nap

An approved peer session holds a
`ProcessInfo.userInitiatedAllowingIdleSystemSleep` activity until that session
closes or is replaced. The menu-bar companion usually has no visible window;
without an activity, macOS can demote its sockets to background traffic and
LEDBAT while the phone is actively downloading. A live inspection on 2 November
2026 showed `BG+R` traffic management and `ledbat` on the LAN peer socket.
The activity spans disk reads, asynchronous response writes, and the Go TLS
bridge drain. It is released on every session exit, and permits idle system
sleep. It does not change pairing, encryption, or the transfer window.

The build script and Xcode Run use the same installed path on this Mac, including
when invoked from a worktree. They do not create a second persistent client.

Validation: the native Debug app builds with Xcode 27.1 beta, installs and launches
from `/Applications/Luna Vault.app`, and passes strict signature verification
with the existing certificate. The three installer regressions cover bundle-ID
and certificate changes plus rollback after failed replacement validation.
