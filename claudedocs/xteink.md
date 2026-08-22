# Send to Xteink

Delivery of saved articles to an Xteink X3 pocket e-reader. No account or
email is involved. Luna builds an image-free, compressed Xteink EPUB then uses
the CrossPoint BLE rendezvous when the reader advertises after wake; over-sized
books escalate to CrossPoint Wi-Fi.

## CrossPoint X3 transport

Luna is the state-restorable CoreBluetooth central and the X3 is the
peripheral. `XteinkSyncProtocol` uses v1 full UUIDs: service
`6f9f0a00-9b1d-4d1f-9f53-5b6b8b3d0f10`, control `...0a01...`, data-in
`...0a02...`, status `...0a03...`, and data-out `...0a04...`. `hello`
authenticates a Keychain-persisted pairing secret using HMAC-SHA256 over
`nonce|host_id|1`; Settings supplies a 32-byte random secret during first-use
code pairing.

Control operations await status `op_ack` rather than treating a successful
GATT write as success. `start_put` supplies `chunk_size` and `resume: true`;
status `resume_offset`/`next_sequence` checkpoints permit an interrupted
transfer to resume. Data frames have a 4-byte LE sequence header and commit
with SHA-256. Reader wiring retries the queued send sweep exactly when the
GATT service becomes ready. iOS can restore this after normal termination but
cannot relaunch Luna after an explicit user force-quit.

When a rendezvous finds no queued Xteink saves, Reader authenticates then sends
`no_work`, which lets the X3 leave its connected wake window immediately.

`XteinkTransferSizePolicy` owns the inclusive 200 KiB ceiling. Small final
Xteink EPUBs are BLE-only and defer while no rendezvous exists. Larger EPUBs
ask `wifi_request` with `prefer_ap: true`; the custom X3 fork treats its own
secured AP as the default so a remembered but unreachable home LAN cannot
strand a travelling phone. STA offers remain protocol-compatible and upload
directly, while an AP offer is joined immediately with `NEHotspotConfiguration`
in the foreground and removed after transfer. Background AP offers cause a
local open-Luna notification.
CrossPoint upload is multipart `POST /upload?path=/Books`; Luna treats a 2xx
response as authoritative and the custom X3 firmware rejects zero-byte files.

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

`XteinkTransferSizePolicy` is the shared route-decision API for both transports.
It evaluates the **final Xteink-profile EPUB bytes** after
image removal and compression: files at or below 200 KiB use
`.bluetoothLowEnergy`; larger files use `.wifi`. The active CrossPoint router
consumes this decision after EPUB generation, so the limit applies to the bytes
actually sent rather than an estimate of the source article.

## Modules and types

All in **LunaSend** (linked by the article-capable Reader app):

- `XteinkBLECentral` — state-restorable BLE central, pairing/authentication,
  resumable streaming, delete control, and AP/STA offer negotiation.
- `XteinkCrossPointTransferRouter` — applies the final-byte size policy, sends
  small EPUBs over BLE, and joins/uploads over the X3 AP for larger EPUBs.
- `XteinkDestination: ArticleDestination` — participates in the coordinator's
  queue/retry/source-gating machinery and funnels sends through the CrossPoint
  router.
- `XteinkRendezvousTransferQueue` (actor, `.shared`) — serializes a coordinator
  sweep because one X3 GATT session accepts one operation/data stream at a time.
- `XteinkSendSettings` — App-Group enable and per-source auto-send settings.
- `XteinkTransferSizePolicy` — pure, transport-independent 200 KiB decision
  based on finalized Xteink EPUB bytes; consumed by the BLE/AP router.

`XteinkDeviceClient` and `XteinkTransferQueue` document and test the stock
firmware protocol, but the active destination no longer calls them.

## Deferral vs failure

`SendDeferralError` (declared next to `ArticleDestination`) is the contract for
"the reader is asleep and no rendezvous exists yet." On a deferral the
coordinator leaves the item `.queued` with no failure count or backoff date;
the next authenticated X3 advertisement retries it at full strength. Real
protocol failures still use the ordinary soft-failure and terminal-failure
path.

The decisive trigger is `.xteinkRendezvousReady`, posted only after the GATT
service, notifications, and current nonce are ready. Existing launch,
foreground, background, and mail-fetch sweeps may prepare or retry queued work,
but they defer without penalty until the X3 advertises after a button or timer
wake.

## UI

- **Settings → Xteink** (`Luna/Settings/XteinkSettingsScreen.swift`, compiled
  into Luna and LunaReader; membership-excluded from Downloader and Price
  Tracker like the other article settings screens): enable switch, code pairing,
  Auto-Send by Source
  (`AutoSendBySourceScreen`, already destination-generic), Send Test
  Document, Transfer Pending Saves.
- There is deliberately NO per-article "Send to Xteink" share-menu row
  (owner decision, 2026-08-22): auto-send plus the Settings screen's manual
  sweep cover delivery; the share menu stays link/export-only.
- `NSBluetoothAlwaysUsageDescription`, `bluetooth-central`, and the Hotspot
  Configuration entitlement are enabled only for the article-capable apps.

## What this deliberately does not do

- **No Xteink cloud sync.** The official cloud path requires patching the
  device firmware to point at a custom server. If direct Wi-Fi upload proves
  too fiddly, that is the revisit.
- **No finished-reading deletion automation yet.** The authenticated BLE
  protocol and router expose `delete`, but Luna does not yet persist a remote
  filename/deletion queue and CrossPoint does not yet delete a Luna book when
  its reading state reaches the end.

## Tests

`XteinkCrossPointTransferTests` cover final-size routing, BLE-only deferral,
foreground AP joining/removal, background notification, STA offers, multipart
shape/nonempty payload, and non-2xx rejection. `XteinkTransferSizePolicyTests`
cover the inclusive 200 KiB boundary. The legacy stock client retains its
URLProtocol and queue tests.
