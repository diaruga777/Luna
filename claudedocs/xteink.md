# Send to Xteink

Delivery of saved articles to an Xteink X3 pocket e-reader. No account or
email is involved. Luna builds an image-free, compressed Xteink EPUB and
delivers it only while the CrossPoint BLE rendezvous is already active — a
share-row send is **enqueue-only** (below); the reader is what opens the
window. There is no background periodic sync: a window opens only from the
reader's HOME-menu **Luna Sync** row (manual, shows overall progress),
first-time pairing, and a short read-report ping the reader fires on its own
when a Luna-synced book is finished. Over-sized books escalate to CrossPoint
Wi-Fi inside that same window.

Status notifications are size-capped by BLE: one notification carries MTU−3
bytes and NimBLE truncates the rest on air, so the reader keeps every status
message under ~182 bytes (`op_ack`/`ok`/`error` plus either transfer fields,
the `wifi` block, or up to 2 `read_ids`). A parser must never assume every
field is present in every message.

## Enqueue-only send

`AppReaderShareProvider.ereaderRows`' Xteink row never waits and never probes
the LAN: on tap it shows a `LunaToast` ("Queued for Xteink") immediately and
runs `ArticleSendCoordinator.send(_:toDestinationID:)` fire-and-forget, with
no completion alert (Kindle/other destinations keep their await + still-
queued alert, since they have no equivalent "delivered on the reader's own
schedule" story). `XteinkCrossPointTransferRouter.sendNow` and
`XteinkCrossPointLANProber` are deleted — there is no phone-initiated network
sweep. `XteinkDestination.send` calls `router.send` (the in-window transport
below) directly: if no rendezvous is active it throws `.unavailable` →
`XteinkRendezvousUnavailableError` instantly, and the coordinator leaves the
item `.queued` at no retry cost. Delivery happens exclusively when the reader
opens a window and Luna's `.xteinkRendezvousReady` sweep runs (see
"Rendezvous-ready sweep" below). `beginRendezvousScan()` still runs
passively at row-build time and at launch/foreground — the background scan
has to stay warm for a device-initiated rendezvous to have a central to
connect to.

## CrossPoint X3 transport

Luna is the state-restorable CoreBluetooth central and the X3 is the
peripheral. `XteinkSyncProtocol` uses v1 full UUIDs: service
`6f9f0a00-9b1d-4d1f-9f53-5b6b8b3d0f10`, control `...0a01...`, data-in
`...0a02...`, status `...0a03...`, and data-out `...0a04...`. `hello`
authenticates a Keychain-persisted pairing secret using HMAC-SHA256 over
`nonce|host_id|1`; Settings supplies a 32-byte random secret during first-use
pairing.

First-use pairing goes through AccessorySetupKit rather than a typed-in code.
Settings → Pair Xteink shows an instruction alert ("Open File Transfer → Luna
Sync on the reader, then continue"), then presents the system picker
(`ASAccessorySession.showPicker(for:)`) scoped to the sync service UUID via
`ASDiscoveryDescriptor.bluetoothServiceUUID`. The X3 initiates BLE bonding
once selected, so iOS shows its own native pairing sheet — Luna has no code UI
anywhere. On the session's `.accessoryAdded` event, `XteinkBLECentral
.connect(toPeripheralIdentifier:)` connects directly to the resolved
`ASAccessory.bluetoothIdentifier` (bypassing the scan, since AccessorySetupKit
already found and authorized it), and once the rendezvous is active the
settings screen sends an unauthenticated `hello` carrying `host_id` and a
fresh random `pair_secret` with no `code` key — the bonded, encrypted link is
the proof of physical presence. `Luna/Info.plist`'s `NSAccessorySetupKitSupports`
(`Bluetooth`) and `NSAccessorySetupBluetoothServices` declare the sync service
UUID so the picker can find advertising readers. The HMAC-authenticated hello
for an already-paired device (below) is unchanged. Settings → Xteink also
offers **Unpair** (shown only once paired): a confirm alert clears the
Keychain pairing and flips the enable switch off.

Control operations await status `op_ack` rather than treating a successful
GATT write as success. The one in-flight `op_ack` slot refuses a second
concurrent control op ("control channel busy") rather than orphaning the
first continuation — callers are serialized through
`XteinkRendezvousTransferQueue` (sends, deletes, and the sweep's `no_work`
alike), so the refusal is a backstop that turns a residual race into a
visible failure instead of a task hung forever. A `start_put` answered with
`exists` counts as DELIVERED: the reader refuses to overwrite a file already
in /Books, so the book is on the device and a retry could only fail the same
way. A missing pairing secret defers (item stays queued, no retry cost) the
same way a missing rendezvous does — pairing is setup, not a failed send. `start_put` supplies `chunk_size`, `resume: true`, and
— new — optional `article_id` (the save's lowercase UUID string) and
`queue_remaining` (how many OTHER items are still queued for this destination,
computed by `ArticleSendCoordinator.deliver` and carried through
`ArticleSendContext`); an older reader tolerates their absence. Status
`resume_offset`/`next_sequence` checkpoints permit an interrupted transfer to
resume. Data frames have a 4-byte LE sequence header and commit with SHA-256.
**The data stream is paced to the reader's durable-receipt checkpoints**
(`XteinkTransferFlowControl`): iOS's `canSendWriteWithoutResponse` is local
backpressure only, and an unpaced stream outran the X3's SD writes, overflowed
its frame pool, and starved its allocator into an OOM `abort()` (measured:
`lock_init_generic`, newlib locks.c:77). The sender stays within one 8 KiB
checkpoint interval plus a 1 KiB margin of the reader's last confirmed
`resume_offset`; a pause is released by any status carrying the offset,
failed by an error status or a dropped link, and times out after 10 s. The
firmware's matching hardening (frame pool, one-shot data-error latch,
`low_memory` refusal at `start_put`) lives in
`CrossPoint-Luna-X3/src/LunaSyncRendezvous.cpp`.

When a rendezvous finds no queued Xteink saves (and no pending remote
deletes — below), Luna authenticates then sends `no_work`, which lets the X3
leave its connected wake window immediately.

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

## Rendezvous-ready sweep

`XteinkRendezvousSweepPolicy.rendezvousBecameReady` is the ONE copy of the
decision both `KindWiring+Luna` and `KindWiring+Reader` used to duplicate
inline, registered on `.xteinkRendezvousReady`. `.xteinkRendezvousReady`
posts ONCE per connection — on the first status carrying the nonce, not on
the later transfer statuses that repeat it — so exactly one sweep task runs
per window.

**One process sweeps a window.** The central Luna app and the Reader both run
a live `XteinkBLECentral` against the one shared store, and iOS shares the
one physical BLE link, so BOTH processes can see the same window become
ready. Two concurrent sweeps interleave duplicate control ops and data
frames on the one GATT session and the reader kills the transfer
(`resume_mismatch`/`sequence`). The whole sweep therefore runs under
`XteinkRendezvousSweepLock` — an App-Group `flock`, kernel-released if the
holder dies — and the losing process stays completely silent (it does not
even answer `no_work`; the owner concludes the window). For the same reason,
`scanIfReady` asks `retrieveConnectedPeripherals(withServices:)` before
scanning: a peripheral another process (or the system) already holds has
stopped advertising and a scan can never find it. It also keeps a
**standing connect** to the known reader
(`XteinkSendSettings.pairedPeripheralID`, persisted on every successful
connection): CoreBluetooth holds a pending connect open indefinitely and
completes it the instant the reader advertises, so a short wake window is
never lost to a scan-discovery race — and state restoration re-issues the
pending connect after an ordinary app termination (TN3115). The scan still
runs alongside it, for a reader whose address changed or that this install
has never seen. Unpair clears the stored identifier and cancels the
standing connect.

The winning sweep is a single sequential task:

1. A **read-report-only window** (`XteinkBLECentral.isReadReportOnlyWindow`,
   sticky for the session once any status carries `"win":"rr"`) never
   reconciles, drains, or sweeps — the device opened it purely to hand back
   finished-reading ids (already drained by the status handler, below), and
   Luna just answers `reportNoWork()`.
2. Otherwise: `XteinkReadStateReconciler.dequeueSendsFinishedBeforeDelivery`
   runs first (see "Read-driven queue and delete" below), then
   `XteinkRemoteDeleteRunner.drainPendingDeletes` runs UNCONDITIONALLY — a
   pending delete is not gated behind "is there also a send" — then
   `ArticleSendCoordinator.deliverQueuedSends(toDestinationID:)` delivers
   every still-queued Xteink send one at a time and **ignores backoff
   dates**: backoff exists to stop unattended sweeps from hammering an
   unreachable receiver, and this sweep only runs while the reader holds a
   live window open. (A backoff-respecting sweep was the silent wedge: one
   transient failure scheduled a 15-minute backoff, after which every window
   found "work" but attempted nothing and told the reader nothing, hanging
   it at "Connected" until its 30 s idle cap.) Finally the sweep ALWAYS
   sends `reportNoWork()` — even after failures — so the reader closes its
   window instead of idling; the firmware latches `no_work` and finishes
   once its own pending reads drain.

Every step records to the shared diagnostic log under the `xteink` category
(Settings → Diagnostics): rendezvous ready, sweep skips, per-send delivery /
deferral / failure, delete drains, and an undeliverable `no_work`.

## Read-state handback

The reader marks a Luna-synced book read when the user reaches its end,
reports the article id back to Luna over a very short BLE ping, and
re-reports any still-pending ids at the start of every later window (give up
fast: a heap gate failure or no phone connecting within ~8 s just leaves the
id pending for next time).

- **Wire**: every status the device publishes during a read-report window
  carries `"win":"rr"` (including the hello ack with the nonce);
  `"read_ids":["<uuid>",…]` (at most 2 per message) is sent right after an
  authenticated `hello` ack when pending ids exist, and again after each
  `read_ack` until drained. `{"op":"read_ack","version":1,"ids":[…]}` is the
  phone's reply — a **fire-and-forget GATT write**, deliberately outside
  `sendControl`'s `pendingControl` await slot (that slot may be occupied by a
  sweep operation already in flight).
- **Parsing**: `XteinkStatusMessage.parse` is the one pure decode point (in
  LunaSend, replacing inline JSON reads in
  `XteinkBLECentral.peripheral(_:didUpdateValueFor:)`) — it carries the
  existing fields plus `readIDs: [UUID]` and `isReadReportWindow`. `win` is
  applied BEFORE `nonce`, so the rendezvous-ready sweep gate is set before
  `.xteinkRendezvousReady` posts.
- **On `readIDs`**: for each id, `XteinkBLECentral` calls
  `SavesStore.shared.markRemoteDeliveryReadOnDevice(for:destination:)` (the
  device-report exemption, below) and then `markFinishedReading(_:)`
  (monotonic — a duplicate report is harmless), then fires the `read_ack`.

## Read-driven queue and delete

Two behaviors key off the save's read state, both governed by one
**immunity flag**: whether the save was already `.read` at the moment its
Xteink send was queued. A user who deliberately (re-)sends an already-read
article is exempt from both — read state drives everything else.

- **Dequeue-on-read** (`XteinkReadStateReconciler`): a save whose Xteink send
  is still `.queued`, whose `readState` is `.read`, and whose immunity flag
  is false gets its queue cleared (`SavesStore.clearSendState`) — sending it
  would spend a BLE window on something the user has already moved past. Runs
  on every `.savesChanged` (the reconciler self-installs its own observer via
  `startObservingSaveChanges()`, called once from each `KindWiring
  .appDidLaunch()`) and again immediately before every rendezvous sweep.
- **Remote delete-on-read** (`XteinkRemoteDeleteRunner`, `delete` — the
  existing control op, no new wire surface): on a successful delivery,
  `XteinkDestination` records the exact sanitized remote basename
  (`SavesStore.recordRemoteDelivery`) and the immunity flag persists from
  enqueue. `SavesStore.markFinishedReading` schedules a remote delete
  (`remoteStatus = .deletePending`) for any `.delivered`, non-immune send —
  **except** one already flagged `.readOnDevice`: the device-report path
  above marks that BEFORE calling `markFinishedReading`, so a book the reader
  already filed away itself never gets queued for a delete too. A normal
  (non read-report) rendezvous drains every `.deletePending` delivery through
  the authenticated `delete` control op, one at a time; the device treats a
  missing file as success (it may already live in /Read or be user-deleted),
  and Luna additionally treats any "no such file"-shaped protocol error as
  done defensively. Anything else left pending just waits for the next
  window.
- **Storage**: `send_states` (`LunaStorage/SavesSchema.swift`) gained
  `queued_while_read INTEGER`, `remote_name TEXT`, `remote_status TEXT` —
  independently absent, no CHECK constraint (an unrecognised `remote_status`
  reads as absent in Swift). Surfaced on `SavedItem` as
  `sendQueuedWhileRead`/`sendRemoteNames`/`sendRemoteStatuses` dictionaries
  and `queuedWhileRead(for:)`/`remoteName(for:)`/`remoteDeleteStatus(for:)`
  accessors, alongside the existing send dictionaries.

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
stored-entry profile. The coordinator also computes `ArticleSendContext`
(the item id, and `queuedRemaining` = the count of OTHER items still
`.queued` for that destination — its sweep is serial, so this decrements
naturally) and calls `ArticleDestination.send(epubData:fileName:title:context:)`;
a default protocol-extension implementation forwards to the plain 3-arg
`send` so Kindle/export destinations are unaffected. `XteinkDestination`
overrides the context form to thread `article_id`/`queue_remaining` through.

`XteinkTransferSizePolicy` is the shared route-decision API for both transports.
It evaluates the **final Xteink-profile EPUB bytes** after
image removal and compression: files at or below 200 KiB use
`.bluetoothLowEnergy`; larger files use `.wifi`. The active CrossPoint router
consumes this decision after EPUB generation, so the limit applies to the bytes
actually sent rather than an estimate of the source article.

## Modules and types

All in **LunaSend** (linked by the article-capable Reader app):

- `XteinkBLECentral` — state-restorable BLE central, pairing/authentication,
  resumable streaming, delete control, read-report receive
  (`isReadReportOnlyWindow`), and AP/STA offer negotiation.
- `XteinkStatusMessage` — the pure status-notification decode (`parse(_:)`),
  including `readIDs`/`isReadReportWindow`.
- `XteinkCrossPointTransferRouter` — applies the final-byte size policy, sends
  small EPUBs over BLE, joins/uploads over the X3 AP for larger EPUBs.
  `sendNow`/LAN-probe routing is deleted (enqueue-only, above).
- `XteinkDestination: ArticleDestination` — participates in the coordinator's
  queue/retry/source-gating machinery, funnels sends through the CrossPoint
  router's `send`, and records the delivered remote name.
- `XteinkRendezvousTransferQueue` (actor, `.shared`) — serializes a coordinator
  sweep because one X3 GATT session accepts one operation/data stream at a time.
- `XteinkReadStateReconciler` — dequeue-on-read.
- `XteinkRemoteDeleteRunner` — drains pending remote deletes.
- `XteinkRendezvousSweepPolicy` — the one rendezvous-ready decision, shared
  by both `KindWiring`s.
- `XteinkRendezvousSweepLock` — App-Group `flock` so only one Luna process
  sweeps a given window.
- `XteinkSendSettings` — App-Group enable and per-source auto-send settings.
- `XteinkTransferSizePolicy` — pure, transport-independent 200 KiB decision
  based on finalized Xteink EPUB bytes; consumed by the BLE/AP router.

## Deferral vs failure

`SendDeferralError` (declared next to `ArticleDestination`) is the contract for
"the reader is asleep and no rendezvous exists yet." On a deferral the
coordinator leaves the item `.queued` with no failure count or backoff date;
the next `.xteinkRendezvousReady` sweep retries it at full strength. Real
protocol failures still use the ordinary soft-failure and terminal-failure
path.

The decisive trigger is `.xteinkRendezvousReady`, posted only after the GATT
service, notifications, and current nonce are ready. Existing launch,
foreground, and background sweeps may prepare or retry queued work, but a
Xteink send only ever actually goes out from that trigger — there is no
periodic background wake to piggyback on.

## UI

- **Settings → Xteink** (`Luna/Settings/XteinkSettingsScreen.swift`, compiled
  into Luna and LunaReader; membership-excluded from Downloader and Price
  Tracker like the other article settings screens): enable switch,
  AccessorySetupKit pairing (above), Auto-Send by Source
  (`AutoSendBySourceScreen`, already destination-generic), and Unpair (shown
  once paired). There is no phone-side "transfer now" row — it contradicted
  the device-initiated model and was removed.
- **Share menu row**: `AppReaderShareProvider.ereaderRows` adds a "Send to
  Xteink" row (`books.vertical`) between the email row and the export
  submenu, gated on `XteinkSendSettings.isEnabled` and the article being
  `.ready`. Its `ReaderShareSheet.Row.statusDotColor` shows a small green dot
  while `XteinkBLECentral.isRendezvousActive` and an unlit (`.tertiaryLabel`)
  dot otherwise — `beginRendezvousScan()` runs at row-build time so the state
  has a chance to be current. The native `UIMenu` presentation of the same
  rows has no dot; only the sheet fallback draws it. A tap shows the "Queued
  for Xteink" toast and fires the send with no completion alert (enqueue-only,
  above); Kindle/other destinations still await and show a still-queued alert.
- `NSBluetoothAlwaysUsageDescription`, `bluetooth-central`, and the Hotspot
  Configuration entitlement are enabled only for the article-capable apps.

## What this deliberately does not do

- **No Xteink cloud sync.** The official cloud path requires patching the
  device firmware to point at a custom server. If direct Wi-Fi upload proves
  too fiddly, that is the revisit.
- **No background periodic sync.** A window opens only from the reader's Luna
  Sync row, pairing, or a read-report ping — never a timer wake.
- **Read-driven remote deletion is IN scope now** (above); what remains out
  is a device-initiated deletion policy of its own accord — the X3 never
  deletes a book on its own schedule, only in response to Luna's `delete`.
- **No ASAccessorySession accessory removal on unpair.** Unpair clears
  Luna's own Keychain pairing and disables the switch; it does not call
  `ASAccessorySession.removeAccessory`.

## Tests

`XteinkCrossPointTransferTests` cover final-size routing, BLE-only deferral,
foreground AP join→upload→leave ordering and removal, background notification,
STA offers, multipart shape/nonempty payload, non-2xx rejection, instant
destination-level deferral with no rendezvous, and `article_id`/
`queue_remaining` reaching the BLE fake through both the router and the
destination's context form. `XteinkStatusMessageTests` cover `read_ids`
parsing (0/1/2 ids, a malformed entry skipped), the `win` flag, and existing
fields/`ok`-`error` precedence. `SavesStoreRemoteDeliveryTests` cover the
immunity flag (stamped only on a fresh enqueue, not a retry), delivery
recording, in-app-finish delete-pending, and the device-reported exemption.
`XteinkReadStateReconcilerTests` and `XteinkRemoteDeleteRunnerTests` cover the
dequeue and delete-drain decisions directly; `XteinkRendezvousSweepPolicyTests`
pin the read-report-only skip, the reconcile→drain→deliver→`no_work` order,
that a denied sweep lock runs nothing, and that a failed `no_work` still
releases the lock; `XteinkRendezvousSweepLockTests` pin the mutual exclusion
(two instances, one file). `ArticleSendCoordinatorTests` pin that
`deliverQueuedSends` ignores backoff and drains everything; the transfer
tests pin `exists`-as-delivered and missing-pairing-as-deferral.
`XteinkTransferSizePolicyTests` cover the inclusive 200 KiB boundary.
