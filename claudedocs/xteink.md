# Send to Xteink

Delivery of saved articles to an Xteink X3 pocket e-reader. No account or
email is involved. Luna builds an image-free, compressed Xteink EPUB then uses
the CrossPoint BLE rendezvous when the reader advertises — during a sleeping
reader's hourly timer window, or the on-device **File Transfer → Luna Sync**
menu entry (a power-button wake opens no window; a pre-UI window cost ~8 s of
wake latency and was removed 2026-08-23). Over-sized books escalate to
CrossPoint Wi-Fi.

Status notifications are size-capped by BLE: one notification carries MTU−3
bytes and NimBLE truncates the rest on air, so the reader keeps every status
message under ~180 bytes (`op_ack`/`ok`/`error` plus either transfer fields or
the `wifi` block). A parser must never assume every field is present in every
message.

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

### WiFi-first "send now" routing

An explicit send (the share-menu row below, and the ambient auto-send sweep)
goes through `XteinkCrossPointTransferRouter.sendNow`, not straight to `send`:
it tries the local network first, since a phone already on the reader's LAN
can deliver immediately without waiting for a BLE rendezvous.

1. `XteinkCrossPointLANProber` concurrently probes `GET http://<host>/api/status`
   on `192.168.4.1` (the ESP32 softAP gateway — covers both a BLE-issued
   `Luna-X3-*` hotspot and CrossPoint's own) and `crosspoint.local` (mDNS, for
   when both devices already share a LAN), ~2 s timeout per host. A host wins
   only on a 200 with JSON whose `device` is `X3`/`X4` or that carries a
   `version` key — an arbitrary router login page can't win the race. First
   confirmed host wins.
2. On a hit (and `XteinkSendSettings.isEnabled`), the upload goes straight to
   that host over HTTP — no BLE involved.
3. On a miss, `sendNow` kicks `beginRendezvousScan()` and waits up to ~12 s
   for `isRendezvousActive` before running the normal size-policy `send`
   (BLE for ≤200 KiB, `wifi_request` escalation above).
4. If neither path reaches the device, it throws `.unavailable`, which
   `XteinkDestination` converts to `XteinkRendezvousUnavailableError` so the
   coordinator queues the item for the next sweep.

## The device protocol (stock firmware) — removed

Luna no longer talks to the Xteink stock firmware's `/edit` Wi-Fi file
manager. `XteinkDeviceClient` and the legacy `XteinkTransferQueue` actor were
deleted 2026-08-22; the CrossPoint BLE/HTTP transport above is the only path.

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
  small EPUBs over BLE, joins/uploads over the X3 AP for larger EPUBs, and
  exposes `sendNow` (LAN-probe-first routing, above).
- `XteinkCrossPointLANProber` — the `sendNow` reachability probe.
- `XteinkDestination: ArticleDestination` — participates in the coordinator's
  queue/retry/source-gating machinery and funnels sends through the CrossPoint
  router's `sendNow`.
- `XteinkRendezvousTransferQueue` (actor, `.shared`) — serializes a coordinator
  sweep because one X3 GATT session accepts one operation/data stream at a time.
- `XteinkSendSettings` — App-Group enable and per-source auto-send settings.
- `XteinkTransferSizePolicy` — pure, transport-independent 200 KiB decision
  based on finalized Xteink EPUB bytes; consumed by the BLE/AP router.

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
but they defer without penalty until the X3 advertises from a timer window or
the reader's Luna Sync menu entry.

## UI

- **Settings → Xteink** (`Luna/Settings/XteinkSettingsScreen.swift`, compiled
  into Luna and LunaReader; membership-excluded from Downloader and Price
  Tracker like the other article settings screens): enable switch, code
  pairing, Auto-Send by Source (`AutoSendBySourceScreen`, already
  destination-generic), Transfer Pending Saves. The old "Send Test Document"
  row (and its stock-firmware-flavored copy) was removed 2026-08-22 along with
  the stock client it exercised.
- **Share menu row** (as of 2026-08-22): `AppReaderShareProvider.ereaderRows`
  adds a "Send to Xteink" row (`books.vertical`) between the email row and the
  export submenu, gated on `XteinkSendSettings.isEnabled` and the article
  being `.ready`. It calls `ArticleSendCoordinator.send(_:toDestinationID:)`,
  which routes through the WiFi-first `sendNow` above; if the item is still
  `.queued` after the await (receiver unreachable on both paths), an alert
  explains it will go out on the next BLE wake or Wi-Fi window.
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
foreground AP join→upload→leave ordering and removal, background notification,
STA offers, multipart shape/nonempty payload, non-2xx rejection, and `sendNow`
routing (LAN-probe hit skips BLE, probe miss falls back to rendezvous-wait
then BLE, and a total miss throws `.unavailable`). `XteinkTransferSizePolicyTests`
cover the inclusive 200 KiB boundary.
