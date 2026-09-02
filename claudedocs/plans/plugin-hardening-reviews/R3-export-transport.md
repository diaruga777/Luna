# R3 review — LunaPluginExport, LunaPluginTransport, bundled plugins, the Swift Xteink path

Read-only review at `main` (aff524cc6). Every claim below was checked against the
code path named. Known items 1–4 from the brief are not re-reported on their own;
extra detail found for them is folded into findings 4 and 5.

Ranked most severe first.

---

## 1. BUG — Pairing the Xteink reader is unreachable in central Luna

`LunaLibraries/Sources/LunaPluginUI/PluginDetailScreen.swift:223-234` renders a
`pairedDevice` field with a Pair/Unpair button whose action is
`invokeAction(for: field)` (`:295-303`), which invokes `onAction` with
`{ "key": field.key }` — for `xteink.js` that key is `"device"`.
`LunaLibraries/Sources/LunaBundledPlugins/Plugins/xteink.js:442-446` handles only
`"pair"` and `"unpair"`, so the hook returns without doing anything.

Consequences chain: the `device` setting is never written →
`PluginExportConfiguration.isConfigured`
(`LunaLibraries/Sources/LunaPluginExport/PluginExportRowProvider.swift:94-101`)
fails on `requiresSettings: ["device"]` → no share row, no configured
destination, and `PluginBluetoothCenter.isPermittedToStart`
(`PluginBluetoothCenter.swift:154-164`) refuses to open the radio. The plugin can
only ever work for a user who paired in Luna Reader first and got the one-time
`PluginTransportComposition.install` migration
(`PluginTransportComposition.swift:85-97`).

Fix: handle `input.key === "device"` in `xteink.js`'s `onAction`, branching on
whether a device is already paired, or make the screen pass a stable
`"pair"`/`"unpair"` key for that field type.

## 2. BUG (parity) — The enqueue-only Xteink send burns a soft failure and dies after five taps

`xteink.js:381-384` answers `{status:"retry"}` when no window is open — the normal
state for a share-row tap. `PluginDestination.deliver`
(`LunaLibraries/Sources/LunaPluginExport/PluginDestination.swift:111-112`) turns
that into `PluginDestinationError.retry`, which does **not** conform to
`SendDeferralError` (`LunaLibraries/Sources/LunaSend/ArticleSendCoordinator.swift:187`).
The Swift destination throws `XteinkRendezvousUnavailableError: SendDeferralError`
for the same condition (`XteinkDestination.swift:72-84`), and
`ArticleSendCoordinator.recordFailure` returns immediately for a deferral
(`ArticleSendCoordinator.swift:537`).

So in central Luna every "Send to Xteink" tap without a live window increments
`sendFailureCounts`, schedules 15 min → 12 h backoff
(`ArticleSendCoordinator.swift:556-560`), and at `maxSoftFailures = 5` (`:276`)
calls `markSendTerminalFailure`. `shouldAttempt` (`:486-494`) then refuses the
item forever — including from the backoff-ignoring rendezvous sweep, which only
skips backoff, not `.failed`. `claudedocs/xteink.md`'s "enqueue-only … no retry
cost" is true of Luna Reader and false of central Luna.

Fix: make the `retry` status produce a deferral — either a
`PluginDestinationError.retry` that conforms to `SendDeferralError`, or a distinct
`defer` status in `PluginExportResult`.

## 3. BUG (parity) — `low_memory` is invisible to the plugin path, so the sweep hammers a refusing reader

`ArticleSendCoordinator.deliverQueuedSends` (`:408-427`) breaks the sweep only on
`XteinkSyncError.protocolError("low_memory")` — a Swift-only error type produced
by `XteinkBLECentral`. On the plugin path the reader's refusal surfaces as
`xteink.js:480`'s `{status:"failed", message:"low_memory"}` →
`PluginDestinationError.soft("low_memory")`, which the `if case` cannot match. The
sweep therefore issues `start_put` for every remaining queued book in a window
the reader has already refused device-wide, and each attempt spends one of the
five soft failures from finding 2.

Fix: recognise the refusal by message as well as by type (or reserve a status the
coordinator reads as "this receiver is out of capacity for this window").

## 4. BUG — The plugin path writes none of the store's remote-delivery bookkeeping

`XteinkDestination.send(…context:)` calls `SavesStore.recordRemoteDelivery`
(`XteinkDestination.swift:56-58`), which is the ONLY writer of
`sendRemoteNames`/`sendRemoteStatuses = .delivered`
(`LunaLibraries/Sources/LunaStorage/SavesStore.swift:644-650`) and therefore the
only thing that lets `markFinishedReading` schedule a `.deletePending`
(`SavesStore.swift:802-806`). `PluginDestination.deliver`
(`PluginDestination.swift:101-123`) records nothing, and `xteink.js:485-489`
writes a private `deliveries` collection that **no code ever reads**.

This is the missing half of known gap 2: not only is `pendingDeletes` unfilled,
the state a filler would read (`.delivered` + a remote name) is never produced in
central Luna either. Remote delete-on-read is inert end to end there, and a book
central Luna delivered can never be deleted by Luna Reader's runner either, since
they share the one store.

Fix: record `recordRemoteDelivery` core-side when a destination plugin answers
`sent` (taking the wire name from the result, e.g. a `remoteName` field), and
delete the dead `deliveries` write.

## 5. BUG (parity) — Read-report handback drains two ids per window and marks nothing read

Two defects beyond known item 1:

- `xteink.js:331-343` calls `reconcile` exactly once, right after `authenticate`.
  The reader sends at most 2 `read_ids` per status and re-sends after each
  `read_ack` until drained (`claudedocs/xteink.md`, "Read-state handback"). Later
  ids do reach `applyStatus` (`xteink.js:152-156`) during `delete`/`start_put`/
  `no_work`, but nothing flushes them and `activeLink = null` (`:438`) throws them
  away. Luna Reader acks in a loop from the status handler
  (`XteinkBLECentral.swift:610-616`). A reader with four pending ids needs two
  windows in central Luna and one in Luna Reader.
- Confirming known item 1 exactly: Swift does
  `SavesStore.markRemoteDeliveryReadOnDevice(for:destination:)` **then**
  `markFinishedReading(_:)` (`XteinkBLECentral.swift:614-615`). The first moves
  `.delivered` → `.readOnDevice` so no redundant remote delete is queued; the
  second sets `readState = .read`, `readingProgress = 1` and `pendingArchiveAt`
  (`SavesStore.swift:780-808`), i.e. the save is marked read and auto-archived.
  The plugin's `luna.exports.markSent` only runs
  `store.setSendState(.sent, …)` (`PluginExportsBridge.swift:156-158`). A book
  finished on the reader stays unread and unarchived in central Luna.

Fix: loop `reconcile` until `link.readIDs` is empty, and add a
`luna.exports.markReadOnDevice(id)` that performs the same two store writes.

## 6. BUG — Nothing reaps the plugin scratch store; it grows without bound

`PluginScratchStore.reap(invocationID:)` and `.reapAll()`
(`LunaLibraries/Sources/LunaPluginKit/PluginScratchStore.swift:141, 152`) have
**zero callers** in the whole tree (`grep -rn "\.reap(\|reapAll"` finds only the
declarations and an unrelated `PendingDeleteReaper`). The type's own doc comment
at `:45` says "A directory is reaped when its hook settles", which is not true of
any code path; doc §14's "nothing reaps a scratch export invocation yet" is
understated — nothing reaps anything, at any time, including at launch.

Every export input EPUB/PDF/DOCX (`PluginExportInputProducer.swift:230-241`),
every adopted media file (`:219-225`) and every `luna.fetch` `as: "file"` response
accumulates under `<AppGroup>/Plugins/scratch/shared/<invocation>/` for the life
of the install. The in-memory `files` id→URL map grows for the life of the
process, and after a relaunch the on-disk files are unreachable but still there.

Fix: reap the invocation directory when `PluginRuntime` finishes a hook (the
`retain` flag already exists to exempt a share-sheet file), and call `reapAll` on
plugin deletion and at launch.

## 7. BUG — `luna.mail`'s recipient picker is always nil in production

`PluginPlatformComposition.install` evaluates `additionalBridges(runtime)`
eagerly (`LunaLibraries/Sources/LunaPluginIngest/PluginPlatformComposition.swift:74`).
`PluginExportComposition.bridges` reads `PluginMailRecipients.picker` at that
moment (`PluginExportComposition.swift:56-59`), but that static is only assigned
inside `PluginExportComposition.install` (`:40`), which `Luna/KindWiring+Luna.swift:71`
runs AFTER the platform install at `:59`. `PluginMailBridge` captures the value in
`init` (`Bridges/PluginMailBridge.swift:99, 146`), so it is permanently nil: a
`luna.mail.send` that names no `to` always rejects with `unavailable-here`, and
`KindWiring+Luna`'s `PluginMailRecipientPrompt` is dead code. A second `install`
cannot fix it. `PluginMailBridgeTests` passes because it injects the picker
directly.

Fix: read `PluginMailRecipients.picker` at call time inside the `send` block, the
way the bridge already resolves `activeScratch` (`:109-111`).

## 8. BUG — A reconnect during a sweep closes the new session and blames another process

`PluginBluetoothCenter.dispatch(_:holdingLock: true)`
(`LunaLibraries/Sources/LunaPluginTransport/PluginBluetoothCenter.swift:340-347`)
reads a failed `serviceLock.acquire()` as "another Luna app owns this rendezvous"
and calls `closeSession`. But `BluetoothServiceLock.acquire`
(`LunaLibraries/Sources/LunaStorage/BluetoothServiceLock.swift:80-96`) also
returns false for a second acquire **inside this process** (`guard !held`). A
disconnect + reconnect while an `onBluetooth` invocation is still in flight
therefore tears down the session just built at `PluginBluetoothCenter.swift:284-287`,
logs a false diagnostic, and leaves the reader hanging to its idle cap.

Fix: distinguish "already held by this center" from "held by another process" and
either serialise the second event behind the first (see finding 15) or skip it
without closing the new session.

## 9. BUG — A stale `next` timeout cancels the following waiter

`PluginBluetoothSession.next`'s timeout closure
(`LunaLibraries/Sources/LunaPluginTransport/PluginBluetoothSession.swift:135-143`)
removes `notificationWaiters[characteristicUUID]` unconditionally, then settles
its own (already-latched, so no-op) operation. Sequence: `next` A is satisfied by
a notification at t=1; `next` B registers a waiter at t=1.1; A's 10 s timer fires
at t=10 and deletes B's waiter. B's value is then only buffered
(`deliver`, `:157-162`) and B stalls until its own timeout. Inside `xteink.js`'s
`control()` loop (`:173-186`, 15 s budget) that is one wasted 10 s in a window the
reader will not hold open much longer.

Fix: key the waiter by a token and have the timeout remove/settle only when the
registered waiter is still its own.

## 10. BUG — `whenReadyToWrite` has no deadline and can wedge the session

`PluginBluetoothSession.whenReadyToWrite` (`:195-200`) parks the write in
`readyToWriteWaiter` with no timeout when the controller has no room. `isBusy`
stays true, so every later operation queues behind it and the only escape is a
disconnect calling `close` (`:176-191`). Every other wait in the file
(`next`, the center's `connect`) has a deadline.

Fix: give the ready-to-write wait the same timeout treatment, failing the
operation with `timed-out` rather than holding the queue.

## 11. BUG (parity) — The plugin's Wi-Fi upload does not retry the X3's server-bind gap

`XteinkCrossPointTransferRouter.send`
(`LunaLibraries/Sources/LunaSend/XteinkCrossPointTransfer.swift:161-168`) uploads,
and on failure waits `uploadRetryPause` (2 s) and uploads once more, with the
comment "The reader binds its HTTP server moments after its AP accepts the phone;
one early connect can land in that gap." `xteink.js:301-306` uploads once and
turns that same gap into `{status:"failed"}` — a soft failure plus backoff
(finding 2's machinery), for a book that would have gone through two seconds
later.

Fix: mirror the single retry in `sendOverWiFi`, and pin it in `XteinkPluginTests`.

## 12. BUG — Central Luna still pushes the Swift Kindle screen, whose address reaches the plugin only next launch

`Luna/ArticleShellWiring.swift:76` installs `KindleSetupPresenter` (`:145-155`) in
every article-capable app, central Luna included, and it pushes
`KindleSettingsScreen`, which writes `KindleSendSettings.kindleAddress`. The
Kindle plugin reads its own `kindleAddress` setting, seeded only by
`PluginExportComposition.migrateKindleAddress`
(`PluginExportComposition.swift:44, 92-112`), which runs once at launch. So a user
who completes the double-save Kindle setup inside central Luna has an
unconfigured destination — no share row, no auto-send — until the app is
relaunched. `claudedocs/plugins.md` §8.5 states central Luna has no
`KindleSettingsScreen` push; the code contradicts it.

Fix: re-run `migrateKindleAddress` when that screen commits an address, or route
central Luna's Kindle setup at the plugin detail screen instead.

## 13. BUG — `onSettingsChanged` gets `{key, value}`, not the documented changes map

`PluginDetailScreen.notifySettingsChanged` (`:284-294`) encodes
`{ "key": …, "value": … }`. `claudedocs/plugins.md` §3.6,
`docs/plugins/api.md:95` and `tools/plugin-sim/luna-plugin.d.ts:154` all specify
`onSettingsChanged(changes: Record<string, unknown>)`, and `xteink.js:448-452`
reads `changes.enabled` accordingly — so the "enabled turned off → stand the
status dot down" leg never runs. This is the same class of `.d.ts`-vs-bridge
mismatch §16 fixed for `onAction`/`onBluetooth`, still open for this hook.

Fix: send `{ "<key>": <value> }` from the screen (keeping the documented shape),
and add a test that drives the hook through the screen's encoder.

## 14. BUG (latent) — Notification characteristic UUIDs are keyed by two spellings

`CoreBluetoothPluginTransport` normalises its own tables through `Self.key(_:)`
(`CoreBluetoothPluginTransport.swift:270-272`) but delivers a notification with
CoreBluetooth's raw `characteristic.uuid.uuidString` (`:427-429`).
`PluginBluetoothSession` keys `buffers` and `notificationWaiters` by the exact
string the plugin handed to `subscribe`/`next` (`:110, 133`). `xteink.js` happens
to use upper-case 128-bit UUIDs, so it matches today; a plugin using lower case —
or any 16-bit UUID, which CoreBluetooth prints short (`180F`) — receives no
notifications at all, silently. `discover` also hands back CoreBluetooth's
spelling (`:390`), inviting the mismatch. No test can catch it: the fake publishes
with its own upper-case constant (`LunaTests/XteinkPluginFakes.swift:182`).

Fix: normalise both the delivery side and the session's keys through
`CoreBluetoothPluginTransport.key(_:)`.

## 15. DESIGN — `onBluetooth` events are not serialised, contrary to plugins.md §9

`PluginBluetoothCenter.dispatch` (`:340-358`) starts a detached `Task` per event
with no ordering or mutual exclusion. Only the SESSION's GATT operations serialise
(`PluginBluetoothSession.enqueue`). §9 states "onBluetooth events serialize per
session; a session's queued/in-flight calls settle (not merely start) before
another may run on the same GATT link" — the second clause is implemented, the
first is not. A `disconnected` or `stateChanged` event can run in JavaScript
concurrently with a `connected` sweep and clobber `xteink.js`'s module-level
`activeLink` (`:76, 426, 438`).

Fix: give the center a one-at-a-time dispatch queue (or actor), and correct the
doc if per-event serialisation is deliberately not wanted.

## 16. BUG — `luna.notifications`' `deepLink` has no consumer

`SystemPluginNotificationCenter` writes the link into `userInfo` under
`lunaPluginDeepLink` (`Bridges/PluginNotificationsBridge.swift:115, 132), and
nothing reads that key anywhere. `Luna/AppDelegate.swift:36` is the only
`UNUserNotificationCenterDelegate` in the tree and it implements `willPresent`
(`:443-447`) but no `userNotificationCenter(_:didReceive:)`. Tapping
`xteink.js`'s "Open Luna to send …" notification (`:291-295`) therefore just
opens the app wherever it was.

The authorization rule itself is correctly honoured: the bridge never requests
(`:24-30, 74-77`), matching CLAUDE.md's "only at explicit opt-in moments", and
`PluginMailBridgeTests.testAnUnauthorizedNotificationAnswersPostedFalse` pins it.
Identifier namespacing (`:71, 106-108`) is also correct, and `clear` cannot reach
another plugin's or Luna's own notifications.

Fix: implement the response delegate and route the key, or drop the parameter
from the bridge and the docs.

## 17. BUG — Export share files leak a temp directory each

`PluginExportStage.linkTemporaryFile` and `.writeTemporaryFile`
(`PluginExportStage.swift:258-288`) each create
`NSTemporaryDirectory()/plugin-export-<uuid>/` and nothing ever removes them. With
finding 6 the same bytes are then kept twice — once in the retained scratch
directory (`:173-174`), once here.

Fix: sweep `plugin-export-*` at launch, or hand the share sheet the retained
scratch URL directly and drop the copy.

## 18. DESIGN — A share-shaped result from an auto send silently counts as delivered

`PluginExportStage.sink` presents through `presenter?.presentExportShare`
(`:187-190`), which is a no-op when nothing is on screen — exactly the background
case. `PluginDestination.deliver` maps `.presented` to success (`:107-108`). A
destination plugin that answers `{file}` or `{url}` from an `auto: true` run
therefore reports "sent" for a delivery that reached nobody, and the coordinator
stamps `.sent`.

Fix: treat a `file`/`text`/`url` result as a hard failure when `auto` is true (or
when no presenter resolved), so the send stays visible.

## 19. BUG (parity, minor) — `x3FileName` differs on astral characters

Swift maps per unicode SCALAR (`XteinkCrossPointTransfer.swift:181-185`);
`xteink.js:117-120` runs `/[^A-Za-z0-9._-]/g` over UTF-16 code units. A title
containing an emoji becomes one `-` in Luna Reader and two in central Luna. That
string is the remote basename and the delete key, so the two apps disagree about
the same file on the same reader.

Fix: iterate `Array.from(name)` in the plugin, and add the emoji case to
`XteinkPluginTests`' filename coverage.

## 20. BUG (minor) — An overlapping `luna.bluetooth.connect` drops the first promise

`PluginBluetoothCenter.connect` assigns `connectWaiters[deviceID]` (`:255-258`)
without checking for an existing entry. A second `connect` for the same device
replaces the first waiter, whose `OperationLatch` is then never taken, so the
first JavaScript promise never settles — the hook waits out its whole 25 s budget.

Fix: refuse the second connect with a distinct code rather than replacing the
waiter.

## 21. DESIGN — `PluginMailMIME` drops the plain-text part when a message has both bodies and an attachment

`Bridges/PluginMailMIME.swift:36-45` emits exactly ONE body part inside the
`multipart/mixed`, preferring `html`. The no-attachment path
(`:19-23`) builds a proper `multipart/alternative` through `EmailMIMEBuilder`, so
the same message loses its text alternative purely because a file was attached.
The attachment filename is also interpolated into a quoted `name=`/`filename=`
parameter without escaping an embedded `"` (`:49-53`) — reachable, since the
plugin chooses the name.

Fix: nest a `multipart/alternative` as the first `multipart/mixed` part, and
escape or strip quotes in the filename parameter.

## 22. DESIGN — `luna.exports` scans the whole saves table repeatedly inside a BLE window

`CoordinatorPluginExportQueue.queuedSends` calls `store.items()` and filters in
Swift (`Bridges/PluginExportsBridge.swift:135-145`); `deliverQueuedSends` calls it
twice more (`:150, 152`), `ArticleSendCoordinator.deliverQueuedSends` once (`:409`)
and `deliver` once per item to compute `queuedRemaining` (`:509-512`). That is a
full-table row decode several times per delivered book, inside the short wake
window the whole design is built around.

Fix: add a store query for send states by destination and use it in both places.

## 23. TEST-GAP — Two tests pin the two halves of finding 2 as correct

`LunaTests/PluginExportStageTests.swift:331-342`
(`testARetryStatusKeepsTheSendQueuedWithBackoff`) asserts
`sendNextAttemptDates[destination.id]` is non-nil after a `retry` — i.e. it pins
the backoff that finding 2 says must not exist for a deferral.
`LunaTests/XteinkPluginTests.swift:284-300` asserts the plugin's half in
isolation against `FakePluginExportsBridge`. Both pass; the composed behaviour
loses the send. Nothing in the suite drives `xteink.js`'s `export` through the
real `PluginDestination` + `ArticleSendCoordinator`.

Fix: after finding 2 lands, assert the composed path — a `retry` from a
destination leaves no failure count and no next-attempt date.

## 24. TEST-GAP — The remote-delete tests exercise state production never creates

`LunaTests/XteinkPluginTests.swift:333-347` seeds the `pendingDeletes` collection
by hand with `runner.kv.putDocument(...)`; `:352-361` asserts the `deliveries`
document that nothing reads (finding 4). Together they make an end-to-end-inert
feature look covered.

Fix: assert what production would have to write — `sendRemoteStatuses`/
`sendRemoteNames` on the shared store — and let the test fail until a writer
exists.

## 25. TEST-GAP — A constant-echo manifest test, and three untested behaviours

`LunaTests/KindlePluginTests.swift:151-165`
(`testTheManifestDeclaresAnArticleEpubDestination`) re-states the `kindle.js`
manifest literal for literal — the constant-echo shape CLAUDE.md's test-value bar
rules out (it asserts the parser round-trips a JSON blob that lives two files
away, not a behaviour).

Untested behaviour in the same area: `PluginNotificationsBridge.clear`'s
prefix-scoped bulk removal (`:85-98`, only the single-identifier path is
exercised), `PluginBluetoothCenter.connect`'s timeout path (`:261-266`), and
`SystemPluginWiFiJoiner`'s 3 s re-apply after a failed join
(`SystemPluginWiFiJoiner.swift:43-48`) — the last is the mechanism the whole
AP-join leg depends on and it has no test at all.

---

## Checked and found correct

Worth recording so a later pass does not re-derive them:

- Wire parity for the BLE transfer: service/characteristic UUIDs, the
  `hello` HMAC input (`nonce|host_id|1`), `start_put`'s field set including
  `chunk_size = mtu - 4`, the 4-byte little-endian frame header, `commit`, and the
  `delete` op's `name` field all agree between `xteink.js` and
  `XteinkSyncProtocol`/`XteinkBLECentral`.
- Checkpoint pacing is identical: `xteink.js:225-228` and
  `XteinkTransferFlowControl.shouldPause` use the same `>=`, the same 1024-byte
  margin, the same 8192 fallback and the same "never pause at the tail" guard.
- `exists`-as-delivered matches (`xteink.js:470-475` vs
  `XteinkDestination.swift:85-91`), as does the read-report window's
  "reconcile then only `no_work`" shape.
- The bundled resolvers are uniform on error handling: every one wraps
  `luna.fetch` in a try/catch that returns `null` (decline) rather than throwing,
  and every URL they emit is absolute. No relative-URL or
  throw-instead-of-decline defect found across the seven.
- `luna.notifications` never requests authorization, in either bridge or
  system conformer, matching CLAUDE.md's rule.
- Wiring in both modules uses protocol witnesses, not stored closures; the
  closures that exist (`connectWaiters`, `pending`, `readyToWriteWaiter`) are all
  per-operation callbacks for one in-flight call, which the standard allows.
