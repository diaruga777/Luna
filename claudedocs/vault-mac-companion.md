# Luna Vault Mac companion

The companion is the Mac-side BEP peer and a small menu-bar accessory built
from the existing SwiftPM executable. It has no Xcode application target.

At startup it chooses one folder, ensures `.stfolder` exists, scans files, and
stores its index in `companion.sqlite`. Rescans run on a timer and from file
system events. Syncthing metadata folders, temporary files, and ignored
folders are skipped. The scanner reuses block hashes when mtime and size are
unchanged.

The server accepts authenticated BEP streams on the configured TCP listener,
relay listener, or tailnet listener. Each accepted peer must be paired before
its index is applied. The server sends `ClusterConfig` and a full or resumable
index, serves requested blocks directly from disk with hash verification, and
pulls iPhone-created blocks into a temporary file before atomic installation.
Deletes become tombstones in the index and remove the local file only after
the protocol has accepted the change.

Pairing mode lasts five minutes and displays the Mac device ID as QR/text. A
new iPhone is shown with its ID and an Accept button. The menu exposes status,
folder selection, public-discovery and Tailscale toggles, device-ID copying,
Pair iPhone, and Quit.
