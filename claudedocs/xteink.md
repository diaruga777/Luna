# Send to Xteink

Delivery of saved articles to an Xteink X3 pocket e-reader. The current
transport is a direct Wi-Fi HTTP upload to the device's stock-firmware file
manager. No account or email is involved. BLE delivery and X3 periodic wake
are a forthcoming custom-firmware companion, not behavior provided by this
stock-firmware client.

## The device protocol (stock firmware)

The X3 has no USB data port (its pogo pins only charge). While the device is
awake on its **Cloud** screen or **Settings → App Connect**, the stock
firmware serves plain HTTP on port 80, reachable by its mDNS name
`E-Paper.local` or its DHCP IP. It sleeps off the network within seconds of
leaving those screens, so delivery is opportunistic by design. The endpoints
(community-documented; the same ones the official companion app and the
open-source sync clients use):

- `GET /status` — JSON with `device_type` (`ESP32…`), used as the probe.
- `POST /edit` — multipart upload. Field name `data`; the multipart FILENAME
  is the destination path. The firmware prepends that path to `/push.txt`,
  its "Pushed Books" shelf manifest — that is what makes an upload appear on
  the device's shelf.
- `PUT /edit` with form `path=<dir>/` — mkdir (trailing slash required).
- `GET /list?dir=<dir>` — listing (`type`/`name`/`size`), used to verify an
  upload's byte count; the ESP32 truncates silently when interrupted.
- `DELETE /edit` with form `path=<p>` — used to remove a truncated upload.

Uploads land in `/Pushed Books/` (`XteinkDeviceClient.pushDirectory`). The
ESP32-C3 receives slowly: the upload timeout is 120 s + 45 s/MB. Article
EPUBs are usually well under 1 MB.

## Xteink EPUB profile and routing seam

`EpubBuilder.Profile.xteink` is intentionally different from Kindle and
generic-export EPUBs. It never resolves, reads, or embeds article-image files:
there are no `OEBPS/images/` entries, image manifest items, or `<img>` elements.
Nonempty image alternative text and standalone caption blocks remain ordinary
italic text. Its XML/XHTML ZIP entries use DEFLATE when that makes them
smaller, while the required first `mimetype` entry remains stored.

`ArticleSendCoordinator` chooses that profile for the built-in Xteink
destination and consequently skips `ArticleExportService.prepareImages` for
that send. Kindle and generic EPUB exports retain their existing image-bearing,
stored-entry profile.

`XteinkTransferSizePolicy` is the shared route-decision API for the upcoming
transport clients. It evaluates the **final Xteink-profile EPUB bytes** after
image removal and compression: files at or below 200 KiB use
`.bluetoothLowEnergy`; larger files use `.wifi`. The current stock Wi-Fi
destination does not yet consume this decision, so it continues uploading all
sizes over HTTP.

## Modules and types

All in **LunaSend** (linked by the central Luna app and LunaReader only):

- `XteinkDeviceClient` — the HTTP protocol above. Every connection-level
  `URLError` (timeout, cannot connect, DNS, connection lost) maps to
  `UnreachableError`, which conforms to `SendDeferralError`.
- `XteinkDestination: ArticleDestination` — the second conformer beside
  `KindleDestination`. It inherits the coordinator's whole queue/retry/gating
  machinery; `send` funnels through `XteinkTransferQueue`.
- `XteinkTransferQueue` (actor, `.shared`) — serializes transfers (the ESP32
  takes one upload at a time) and caches the reachability probe for 10 s, so
  a sweep of N queued articles against an asleep device costs one probe, not
  N. A transfer that dies mid-upload invalidates the cached probe.
- `XteinkSendSettings` — App-Group defaults: `xteinkEnabled` (the one consent
  switch, off by default — probing the LAN is what triggers the iOS local-
  network permission prompt), `xteinkDeviceAddress` (optional; tried before
  the default mDNS name), `xteinkSendMode` (defaults to `.allSaves`: once the
  switch is on, saves queue automatically, which also makes every other
  capture source default on through `SourceSendSettings.legacyDefault`).
- `XteinkTransferSizePolicy` — pure, transport-independent 200 KiB decision
  based on finalized Xteink EPUB bytes; the BLE and AP/Wi-Fi implementations
  will consume it.

## Deferral vs failure

`SendDeferralError` (declared next to `ArticleDestination`) is the contract
for "the receiver isn't reachable right now, and that is normal". On a
deferral the coordinator leaves the item `.queued` with NO failure count and
NO backoff date — the next sweep retries at full strength. Real protocol
failures (HTTP error, size-verification failure) still take the ordinary
soft-failure backoff and terminal-failure path. Without this split, five
sweeps past a sleeping e-reader would terminally fail every queued article.

Sweeps run at the existing trigger points (`ArticleShellWiring
.retryPendingSends`): launch, foreground, background, the mail-fetch BGTask —
plus `wifiBecameAvailable`, added for this feature in both article apps'
`KindWiring` variants. The intended flow: saves queue as they become ready;
the user wakes the X3 on its Cloud screen and opens (or foregrounds) Luna;
everything pending uploads.

## UI

- **Settings → Xteink** (`Luna/Settings/XteinkSettingsScreen.swift`, compiled
  into Luna and LunaReader; membership-excluded from Downloader and Price
  Tracker like the other article settings screens): enable switch (toggling
  on fires one probe so the permission prompt appears while the user is
  looking), device address field, Auto-Send by Source
  (`AutoSendBySourceScreen`, already destination-generic), Send Test
  Document, Transfer Pending Saves.
- There is deliberately NO per-article "Send to Xteink" share-menu row
  (owner decision, 2026-08-22): auto-send plus the Settings screen's manual
  sweep cover delivery; the share menu stays link/export-only.
- `NSLocalNetworkUsageDescription` lives in the shared `Luna/Info.plist`.

## What this deliberately does not do

- **No Xteink cloud sync.** The official cloud path requires patching the
  device firmware to point at a custom server. If direct Wi-Fi upload proves
  too fiddly, that is the revisit.
- **No background LAN scanning.** iOS gives no way to probe the local network
  from a suspended app; the background-enter sweep and BGTask sweeps are
  best-effort, and the reliable path is "wake device, open app".
- **No push-manifest rebuilding.** The firmware appends to `/push.txt` on
  every upload; duplicates only accumulate on re-sends, and the resend
  cooldown already guards that.

## Tests

`XteinkDeviceClientTests` (URLProtocol-stubbed: multipart shape, probe
filtering, truncation → delete + throw, connection error → unreachable,
transfer-queue serialization and probe caching) and the deferral cases in
`ArticleSendCoordinatorTests`.
