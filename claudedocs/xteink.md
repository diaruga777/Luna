# Send to Xteink

**Two implementations, one reader.** Luna Reader runs the Swift path this
document describes. **Central Luna runs it as a bundled PLUGIN**,
`LunaBundledPlugins/Plugins/xteink.js`, over `luna.bluetooth` / `luna.wifi`
(`LunaPluginTransport`, `claudedocs/plans/plugin-platform.md` §10): the
plugin owns the rendezvous sweep, the transfer and its own settings screen,
and `KindWiring+Luna` installs no `XteinkBLECentral`. Both processes take one
`BluetoothServiceLock` keyed by the CrossPoint service UUID, so only one of
them ever talks to a given window. Every wire behaviour below is shared, and
`XteinkPluginTests` pins the plugin against the same protocol — a fix to one
side that is not mirrored is a fix that only half the apps get.

Delivery of saved articles to an Xteink X3 pocket e-reader. No account or
email is involved. Luna builds an image-free, compressed Xteink EPUB and
delivers it only while the CrossPoint BLE rendezvous is already active — a
share-row send is **enqueue-only** (below); the reader is what opens the
window. A window opens from the reader's HOME-menu **Luna Sync** row
(manual, shows overall progress), first-time pairing, or a short read-report
ping the reader fires when a Luna-synced book is finished. The **X3 firmware
fork** also wakes from deep sleep twice a day to open a headless automatic
sync window; the plugin build does not. Over-sized books escalate to
CrossPoint Wi-Fi inside that same window.

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
Settings → Pair Xteink shows an instruction alert naming both reader paths
(File Transfer → Pair Luna on the fork; Settings → Plugins → Pair Luna, or
the unpaired home row, on a plugin build), then presents the system picker
(`ASAccessorySession.showPicker(for:)`) scoped to the sync service UUID via
`ASDiscoveryDescriptor.bluetoothServiceUUID`. **The picker cannot appear while
the process holds any live CBManager** — once the app has the global Bluetooth
permission, `showPicker` fails with ASErrorDomain code 550 ("CBManagers active
with global permissions"), which is exactly what broke every re-pair while the
standing central lived forever. `XteinkBLECentral.releaseForAccessoryPicker()`
therefore tears the manager down (scan, live link, standing connect, then the
manager itself) before `showPicker`, and `rebuildAfterAccessoryPicker()`
recreates it on every exit path; a connect requested while the manager is
still rebuilding parks in `pendingConnectIdentifier` until poweredOn. The X3
initiates BLE bonding once selected, so iOS shows its own native pairing sheet
— Luna has no code UI anywhere. On the session's `.accessoryAdded` event,
`XteinkBLECentral.connect(toPeripheralIdentifier:)` connects directly to the
resolved `ASAccessory.bluetoothIdentifier` (bypassing the scan, since
AccessorySetupKit already found and authorized it), and once the rendezvous is
active the settings screen sends an unauthenticated `hello` carrying `host_id`
and a fresh random `pair_secret` with no `code` key — the bonded, encrypted
link is the proof of physical presence. `Luna/Info.plist`'s
`NSAccessorySetupKitSupports` (`Bluetooth`) and
`NSAccessorySetupBluetoothServices` declare the sync service UUID so the
picker can find advertising readers. The HMAC-authenticated hello for an
already-paired device (below) is unchanged. Settings → Xteink also offers
**Unpair** (shown only once paired): a confirm alert clears the Keychain
pairing, flips the enable switch off, drops the live/standing connections, and
removes the ASK authorization (`ASAccessorySession.removeAccessory`).

**Pair means (re)pair, and it self-heals.** Before showing the picker, the
flow removes every ASK accessory this app already set up: the picker never
lists an accessory it considers already set up (a stale authorization reads
as "iPhone can't find the reader"), and the bond iOS kept alongside it no
longer matches the reader's cleared keys (reads as "pairing failed").
Removal deletes that bond too, so both sides start clean regardless of what
earlier builds left behind. Two traps here:
`ASAccessorySession.accessories` is EMPTY until the session's `.activated`
event lands — enumerate it only after `awaitSessionActivation()` — and the
whole flow logs each step to the `xteink` diagnostics category.

**An unpaired central stays silent.** `scanIfReady` refuses to scan or
connect unless a pairing secret exists or the settings pairing flow raised
`pairingMode`. Without this gate an unpaired Luna kept connecting to every
reader window as a client that could never authenticate — the reader showed
"Luna connected", sent nothing, and the window died on idle.

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
`lock_init_generic`, newlib locks.c:77). The sender stays within one
checkpoint interval plus a 1 KiB margin of the reader's last confirmed
`resume_offset`. The interval is the READER'S to declare: every transfer
status carries `"ckpt"` (2048 on current firmware, sized so the paced window
fits its 16-slot frame pool), and the phone falls back to 8192 — the one
pre-`ckpt` firmware build's stride — when the field is absent. A pause is
released by any status carrying the offset, failed by an error status or a
dropped link, and times out after 10 s. The firmware's matching hardening
(frame pool allocated AFTER the pre-NimBLE heap gate — allocating before it
effectively raised the gate's floor and refused every window with "Bluetooth
init failed" on hardware near the floor — plus the one-shot data-error latch
and the `low_memory` refusal at `start_put`) lives in
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
`BluetoothServiceLock` (LunaStorage, reached through
`XteinkRendezvousSweepLock`) — an App-Group `flock` keyed by the service UUID,
kernel-released if the holder dies — and the losing process stays completely silent (it does not
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
2. Otherwise: `XteinkRemoteDeleteRunner.drainPendingDeletes` runs
   UNCONDITIONALLY — a
   pending delete is not gated behind "is there also a send" — then
   `ArticleSendCoordinator.deliverQueuedSends(toDestinationID:)` delivers
   every still-queued Xteink send one at a time. It reconciles read-driven
   dequeues for that destination on the way in (see "Read-driven queue and
   delete" below), and **ignores backoff dates**: backoff exists to stop unattended sweeps from hammering an
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
- **In central Luna, `xteink.js` does the same two writes** through
  `luna.exports.markReadOnDevice(saveId)`, which is
  `CoordinatorPluginExportQueue.markReadOnDevice` — the same store calls in
  the same order. Its `reconcile` loops until the reader stops handing ids
  back rather than answering one batch, since the reader sends at most two
  per status. `PluginExportsBridgeTests` and `XteinkPluginTests` compare the
  resulting `SavedItem` against the Swift path's; the two apps write one
  store, so a book finished on one reader has to read the same in both.

## Read-driven queue and delete

Two behaviors key off the save's read state, both governed by one
**immunity flag**: whether the save was already `.read` at the moment its
Xteink send was queued. A user who deliberately (re-)sends an already-read
article is exempt from both — read state drives everything else.

- **Dequeue-on-read** (`ReadStateSendReconciler`): a save whose send is still
  `.queued`, whose `readState` is `.read`, and whose immunity flag is false
  gets its queue cleared (`SavesStore.clearSendState`) — sending it would
  spend a BLE window on something the user has already moved past. It serves
  every destination whose `ArticleDestination.dequeuesOnRead` is true, which
  is what makes it work in central Luna: there the Xteink destination is the
  PLUGIN, which declares `export.dequeueOnRead` in its manifest, not
  `XteinkDestination`. Runs on every `.savesChanged` (the reconciler installs
  its own observer via `startObservingSaveChanges()`, called once from
  `ArticleShellWiring.appDidLaunch()`, which both article apps run) and again
  inside `ArticleSendCoordinator.deliverQueuedSends(toDestinationID:)`, so a
  plugin driving its own sweep through `luna.exports.deliverQueued()` gets the
  same pre-pass.
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
- **The plugin path is the same bookkeeping, driven from JavaScript.**
  `xteink.js` answers `{status:"sent", remoteName}` and `PluginDestination`
  records it with `SavesStore.recordRemoteDelivery`, so a book central Luna
  delivered can be deleted later — by either app. Its `drainPendingDeletes`
  reads `luna.exports.pendingDeletes()` (the `.deletePending` deliveries with
  a recorded name) and calls `luna.exports.markRemoteDeleted(saveId)` after a
  successful `delete` op or a missing-file error, exactly as
  `XteinkRemoteDeleteRunner` does.
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

## Reader firmware: fork and plugin

The reader side ships in two packagings that speak the same wire protocol,
so one Luna build talks to both:

- **The firmware fork**, `~/Desktop/CrossPoint-Luna-X3` (branch
  `feature/luna-sync-x3`, protocol doc `docs/luna-x3-sync.md`). Hand-edits a
  handful of shared CrossPoint files: File Transfer rows (Pair Luna / Luna
  Sync), the home-menu row, the reader's end-of-book hook, the HAL's GPIO13
  handling. Built with `pio run -e default` in that checkout.
- **The plugin**, `~/Desktop/xteink-plugins` (branch `lunasync`, directory
  `plugins/lunasync/`), a fork of `JustinOros/xteink-plugins`. That project
  is the community "plugin" mechanism for CrossPoint: source-level patches a
  Python installer applies to a fresh clone of upstream `develop` before
  building and flashing (`python3 install.py`, pick "Luna Sync (Xteink
  X3)"). This is NOT CrossPoint's own plugin system. Upstream's SD plugins
  (branch `feat-sd-plugins`, shipped through the beta channel; the Libby
  "Protected Content" plugin is one) are folders on the card holding a
  browser-side `plugin.js` that runs in the web UI page, a declarative
  `device.json` catalog the firmware renders, and HTTP event templates. No
  plugin code runs natively on the device and the surface has no Bluetooth
  at all (the firmware still builds with the `bt` component dropped), so
  the BLE rendezvous cannot be an SD plugin. `LunaSyncRendezvous.cpp` and `LunaBooksStore.cpp` are copied into the
  plugin VERBATIM from the fork; the two small extra units are
  `LunaSyncPlugin.cpp` (home-row glue) and `LunaPairActivity.cpp` (Settings
  → Plugins → Pair Luna). The rendezvous engine is the one implementation —
  fix it in the fork and copy the file over, or the reverse.

The plugin form differs from the fork in three user-visible ways:

1. **Pairing entry.** There are no File Transfer rows. The home row pairs
   when no host is stored and syncs otherwise; re-pairing is Settings →
   Plugins → Pair Luna. Luna's own pairing alert therefore describes both
   reader paths.
2. **No read-state handback.** "Read-state handback" below is fork-only: the
   plugin does not hook the reader's end-of-book screen, so a plugin-built
   reader never sends `read_ids`. Luna's `read_ack` path is unaffected (it
   only answers what arrives).
3. **No GPIO13 change.** Upstream's boot path is untouched.

Two framework facts matter when touching the plugin. Upstream lists `BLE`
under `lib_ignore`, and pioarduino's custom core rebuild reads that as "drop
the IDF `bt` component", so the plugin's `platformio_lib_unignore=["BLE"]`
is what puts NimBLE back (first build rebuilds the core; minutes, then
cached). And the framework patches by exact text anchor against upstream
`develop` and stops when one is missing — the `lunasync` branch re-anchored
it to develop `7db14a0` (2026-09-06) and added the `HomeMenuEntry`
contribution the home row rides on; upstream moves fast, so an install
failure that names an anchor is drift, not a plugin bug.

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
  router's `send`, and records the delivered remote name. **In central Luna
  this Swift class is never instantiated for delivery**:
  `PluginDestinationLegacyIDs.byPluginID` maps the `xteink.js` plugin id
  (`app.luna.xteink`) onto the exact string `XteinkDestination.id` uses
  (`"xteink"`), and `PluginExportComposition.installDestinations` registers
  a `PluginDestination` under that id through
  `ArticleDestinationRegistry.install(_:replacingBuiltInIDs:)` — so
  `ArticleSendCoordinator.destinations` filters the Swift instance out and
  every `send_states`/`SourceSendSettings`/sent-date row keeps applying to
  the plugin's deliveries unchanged. This mapping landed in a follow-up
  commit after the plugin platform's Wave 3B first merged without it.
- `XteinkRendezvousTransferQueue` (actor, `.shared`) — serializes a coordinator
  sweep because one X3 GATT session accepts one operation/data stream at a time.
- `ReadStateSendReconciler` — dequeue-on-read, for every destination whose
  `dequeuesOnRead` is true.
- `XteinkRemoteDeleteRunner` — drains pending remote deletes.
- `XteinkRendezvousSweepPolicy` — the one rendezvous-ready decision, shared
  by both `KindWiring`s.
- `XteinkRendezvousSweepLock` — the CrossPoint service's
  `BluetoothServiceLock` (LunaStorage), an App-Group `flock` keyed by service
  UUID so only one Luna process sweeps a given window. Central Luna's Xteink
  PLUGIN takes the same file through `luna.bluetooth`.
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

The plugin path answers the same way: `xteink.js` returns `{status:"retry"}`
with no live session and `PluginDestination` throws
`PluginDestinationDeferral`, which conforms to `SendDeferralError`. The
reader's own `low_memory` refusal ends the WINDOW rather than the book on both
paths — `deliverQueuedSends` reads it from the Swift transport's protocol
error and from a plugin's message alike.

The decisive trigger is `.xteinkRendezvousReady`, posted only after the GATT
service, notifications, and current nonce are ready. Existing launch,
foreground, and background sweeps first promote ready items whose source is
configured for `.allSaves` into `.queued`; this also covers articles finalized
by the share/action extensions, which cannot call the app-only readiness hook.
Those sweeps may then retry queued work, but a Xteink send only ever actually
goes out from that trigger — the fork's timer wake opens an ordinary sync
window, which drives the same trigger and queue sweep.

## UI

- **Settings → Xteink** (`Luna/Settings/XteinkSettingsScreen.swift`, reached
  from `KindWiring+Reader` only; central Luna shows the plugin's own settings
  screen under Settings → Plugins instead): enable switch,
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
- **No timer wake in the plugin build.** The X3 firmware fork arms a 12-hour
  deep-sleep timer when Luna Sync is enabled and paired. Its timer boot leaves
  the e-ink display and frontlight untouched, opens the usual authenticated
  BLE window, then returns to deep sleep. A valid X3 clock anchors the first
  check after a user sleep to 00:00/12:00 UTC; later automatic checks are 12
  hours apart. Without a set clock, each sleep arms a 12-hour delay.
  Luna's existing `no_work` response ends an empty-queue window immediately.
  The separately installed plugin does not change CrossPoint's sleep path.
- **Read-driven remote deletion is IN scope now** (above); what remains out
  is a device-initiated deletion policy of its own accord — the X3 never
  deletes a book on its own schedule, only in response to Luna's `delete`.
- **Reader-side pair vs sync are separate actions** (CrossPoint fork,
  2026-08-27): on the fork, "Pair Luna" lives only under File Transfer and
  "Luna Sync" is on the home menu and File Transfer; on the plugin build,
  "Pair Luna" is Settings → Plugins and the home row pairs only while no
  host is stored (see "Reader firmware: fork and plugin"). A sync window never pairs and refuses up
  front with "Not paired" when no trusted host is stored; the pairing window
  clears the reader's NimBLE bond store at start so a re-pair after an iOS
  unpair cannot wedge on a stale device-side bond. Outcome popups report a
  synced-book count, the reader's own `low_memory` refusal, and
  connected-but-unpaired distinctly.

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
`ReadStateSendReconcilerTests` and `XteinkRemoteDeleteRunnerTests` cover the
dequeue and delete-drain decisions directly; `XteinkRendezvousSweepPolicyTests`
pin the read-report-only skip, the drain→deliver→`no_work` order,
that a denied sweep lock runs nothing, and that a failed `no_work` still
releases the lock; `BluetoothServiceLockTests` pin the mutual exclusion
(two instances, one file) and that the Swift sweep and the plugin bridge derive
one path for the CrossPoint service UUID. `ArticleSendCoordinatorTests` pin that
`deliverQueuedSends` ignores backoff and drains everything; the transfer
tests pin `exists`-as-delivered and missing-pairing-as-deferral.
`XteinkTransferSizePolicyTests` cover the inclusive 200 KiB boundary.
