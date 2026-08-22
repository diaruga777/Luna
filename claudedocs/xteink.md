# Send to Xteink

Background delivery of saved articles to a custom-firmware **Xteink X3**. Luna
is the Bluetooth LE central and CrossPoint is the peripheral; the reader's
power-button wake is the primary rendezvous. No account or email is involved.

## CrossPoint X3 sync

`XteinkSyncProtocol` defines the stable v1 GATT UUIDs (service
`6F9F0A00-9B1D-4D1F-9F53-5B6B8B3D0F10`, control `0A01`, data-in `0A02`, status
`0A03`, data-out `0A04`) and v2 JSON controls: `hello`, `start_put`, `commit`,
`cancel`, `delete`, and `wifi_request`. `hello` authenticates a trusted host
with HMAC-SHA256(`nonce|host_id|1`); its secret is stored in the shared
Keychain after first-use pairing. Data frames start with a 4-byte little-endian
sequence. Luna chunks using the negotiated
`maximumWriteValueLength(.withoutResponse)`, waits for
`canSendWriteWithoutResponse`, resumes using `resume_offset` /
`next_sequence` checkpoints, and commits with a SHA-256. GATT write completion
is not a transfer ACK: every control awaits the matching status `op_ack`.
CrossPoint writes to a `.part` file and atomically finalizes only after that
hash matches.

The temporary transport policy is one constant: EPUBs at or below **200 KiB**
go over BLE only. If no rendezvous is active, that is a `SendDeferralError`,
not a retry-consuming failure. Larger EPUBs ask the live reader for Wi-Fi;
the X3 briefly tries remembered STA, then reports its secured AP SSID,
passphrase and host. In the foreground Luna joins that AP with
`NEHotspotConfiguration`, multipart-POSTs to CrossPoint
`POST /upload?path=/Books`, and
removes the temporary configuration afterwards. In the background it posts a
local notification asking the user to open Luna.

The central uses CoreBluetooth state restoration and scans on Reader launch /
foreground. iOS can restore it after normal system termination, but **cannot**
relaunch Luna after the user explicitly force-quits it; Bluetooth-off and
permission denial are similarly unavoidable limitations.

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

## Modules and types

All in **LunaSend** (linked by the central Luna app and LunaReader only):

- `XteinkBLECentral` — state-restorable, background-capable central; it owns
  discovery/reconnect, GATT discovery, paced no-response writes and status
  notifications. Pairing credentials live in the App-Group Keychain through
  `XteinkKeychainPairingStore` (the first-use UI is a subsequent shell task).
- `XteinkCrossPointTransferRouter` — testable BLE/secured-AP decision seam;
  `XteinkCrossPointClient` is the documented CrossPoint HTTP uploader.

- `XteinkDeviceClient` — the HTTP protocol above. Every connection-level
  `URLError` (timeout, cannot connect, DNS, connection lost) maps to
  `UnreachableError`, which conforms to `SendDeferralError`.
- `XteinkDestination: ArticleDestination` — the second conformer beside
  `KindleDestination`. It inherits the coordinator's whole queue/retry/gating
  machinery; `send` funnels through the CrossPoint router.
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
- `NSLocalNetworkUsageDescription`, `NSBluetoothAlwaysUsageDescription`, and
  `bluetooth-central` background mode live in the shared `Luna/Info.plist`.

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
