# Plugin platform hardening — the gap closure and review pass

Status: PLAN (2026-09-02). Branch `plugin-hardening`, worktree
`/Users/hsp/Desktop/Luna-plugin-hardening`, off `main` at `aff524cc6`.
`claudedocs/plugins.md` is the current reference; this plan changes it and
must leave it true. Section numbers below (§5.1, §14 …) refer to that file.

## 0. Ground rules for every implementation agent

1. **Work in your own worktree** taken off the `plugin-hardening` branch, not
   in the shared checkout: `git worktree add -b <wp-branch> ../Luna-<wp> plugin-hardening`.
   Commit small logical chunks as you go. Do not merge yourself; report the
   branch name when done. Resolve nothing with `--force`.
2. **Compile gate per commit**: from your worktree,
   `xcodebuild build-for-testing -scheme Luna -destination 'generic/platform=iOS Simulator' -derivedDataPath <your own DD under the scratchpad> DIAGNOSE_MISSING_TARGET_DEPENDENCIES=NO`.
   A failure naming a type that plainly exists in a file you did not touch is
   a swift-build flake — re-run once before investigating (CLAUDE.md).
3. **Run only your own test classes**, not the suite: create a fresh simulator
   (`xcrun simctl create wp-<name> "iPhone 17" <latest iOS 26 runtime>`), boot it,
   `xcodebuild test -scheme Luna -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath <DD> DIAGNOSE_MISSING_TARGET_DEPENDENCIES=NO -only-testing:LunaTests/<ClassA> -only-testing:LunaTests/<ClassB> …`,
   read the `Executed N tests, with M failures` line, then `simctl shutdown`
   and `simctl delete` it. The orchestrator runs the full suite once at the end.
   Do not leave a simulator booted.
4. **Tests assert behaviour** (CLAUDE.md "test value bar"): no constant echoes,
   no source-text greps of same-build Swift. A cross-artifact parity pin
   (Swift vs `plugin_host.js` vs `tools/plugin-sim`) is the one exception and
   is encouraged where two backings must agree.
5. **Wiring is protocol contracts, never stored closures.** A new seam is a
   `*Providing`/`*Observing`/`*Handling` protocol with a witness installed by a
   composition root or kind pack. Closures only as call arguments.
6. **Comments** follow the CLAUDE.md standard: state what the code does and the
   constraint it serves; never describe the old design or a deleted feature.
7. **Strings**: every user-visible Swift string is an `L10n.string("Key_Luna")`
   entry in `LunaLibraries/Sources/LunaModels/Resources/en.lproj/Localizable.strings`
   (run `python3 scripts/strings_sync.py --write` after adding keys, then hand-
   place the new lines in reading order).
8. **Docs move with the code**: update `claudedocs/plugins.md`,
   `docs/plugins/api.md`, `tools/plugin-sim/luna-plugin.d.ts`,
   `tools/plugin-sim/bridge.mjs`, and `LunaSafari/Resources/plugin_host.js`
   wherever your change alters what a plugin can call or receive. Strike the
   corresponding bullet from `claudedocs/plugins.md` §14 "Known gaps". Do not
   edit `claudedocs/plans/plugin-platform.md` (history).
9. **Never gate on `#if canImport`** for a per-target difference; use the
   membership-exception / per-target-file mechanism (CLAUDE.md).
10. **Report faithfully**: your final message names the branch, every commit,
    the exact test line(s) you observed, and anything you left undone.

## 1. What is wrong today (verified by reading the code)

### 1.1 The five listed gaps (`claudedocs/plugins.md` §14)

| # | Gap | Where |
| --- | --- | --- |
| G1 | `luna.downloads` has no bridge; a declared `downloads` capability gets the `unavailable-here` Proxy. | `PluginCapabilityName.downloads` has no `PluginCapabilityInstalling` |
| G2 | `luna.fetch` multipart parts read only `text`/`base64`; no `file: FileHandle`. `xteink.js` base64-round-trips its EPUB. | `PluginFetchRequestDecoder.encodeMultipart` (`LunaPluginRuntime/Bridges/PluginFetchBridge.swift:175`) |
| G3 | Plugin copy (manifest `name`/`description`/`export.title`/`settings[].label|help|placeholder`/`options[].label`, and text a plugin writes itself) is English-only with no mechanism. `luna.env.locale` exists; nothing helps a plugin pick a string by it. | `PluginManifestParser`, `PluginContext.swift:61`, `plugin_host.js:268`, `bridge.mjs:276` |
| G4 | Dequeue-on-read and remote-delete-on-read have no plugin-visible signal. Specifically: (a) `XteinkReadStateReconciler.startObservingSaveChanges` runs only from `KindWiring+Reader`, so central Luna never dequeues a finished-before-delivery Xteink send; (b) `SavesStore.markFinishedReading` already flips `.delivered` → `.deletePending` for every destination, but `luna.exports` cannot read `sendRemoteStatuses`/`sendRemoteNames`, so `xteink.js` drains its own `pendingDeletes` collection that nothing fills; (c) `xteink.js` records the delivered file name in its own `deliveries` collection instead of `SavesStore.recordRemoteDelivery`, so the store's `remoteName(for: "xteink")` is empty for plugin deliveries; (d) `xteink.js`'s `reconcile` answers a reader read-report with `luna.exports.markSent`, whereas Luna Reader's Swift path marks the delivery `.readOnDevice` and the save finished in Luna (`markRemoteDeliveryReadOnDevice` → `markFinishedReading`). | `LunaSend/XteinkReadStateReconciler.swift`, `LunaPluginExport/Bridges/PluginExportsBridge.swift`, `xteink.js` `reconcile`/`drainPendingDeletes`/`recordDelivery` |
| G5 | Media and product export destinations get manual share rows only: `ArticleSendCoordinator.articleBecameReady` is reached only from the article ingest handler, and `sendBuildingEPUB` refuses `isPlatformItem`. Related: `SourceSendSettings.appIntentsMode(forDestination:)` answers `.off` for any id but `kindle`/`xteink`, so a NEW destination plugin can never auto-send, and central Luna has no screen that reaches `AutoSendBySourceScreen` for the Xteink plugin (the Swift `XteinkSettingsScreen` is excluded from the target). | `LunaSend/ArticleSendCoordinator.swift:384-427,466-481`, `LunaSend/SourceSendSettings.swift:39-52`, `Luna/Settings/AutoSendBySourceScreen.swift` |

### 1.2 Runtime defects found while reading (not in §14)

| # | Defect | Evidence |
| --- | --- | --- |
| R1 | **One `invocationID` and one `activeCall` per runtime.** `settle` overwrites both on every call (`PluginRuntime.swift:423-424`); `noteSettled` nils `activeCall` (`:456`). Hooks DO overlap: `onBluetooth` → `luna.exports.deliverQueued()` → `export` runs while `onBluetooth` is in flight; a save walk (`ingest`, idle-budgeted) can overlap a media re-resolve or a second save. Consequences: the inner call's settle stops the outer idle-budgeted `ingest` from being touched, so it times out after 30 s while its fetches are still streaming; a file `luna.files.write`/`as:"file"` creates during the outer hook is filed under the inner call's directory. | `PluginRuntime.swift:128-130, 355-359, 420-460, 486-494` |
| R2 | **Scratch directories are never reaped.** Nothing calls `PluginScratchStore.reap(invocationID:)` or `reapAll()` (grep across `LunaLibraries/Sources` and `Luna/`). §10.2's "reaped after the hook settles" and "at launch to clear what a killed process left" are both unimplemented. Every `as:"file"` fetch, every `luna.files.write`, and every export input file (EPUB/PDF/DOCX, a hard link of a media download) stays under `<AppGroup>/Plugins/scratch/` forever. | `PluginScratchStore.swift:138-171` (unreferenced) |
| R3 | `PluginExportStage.sink(.file)` retains the scratch directory for the share sheet AND hard-links the file into a temporary location (`PluginExportStage.swift:166-181, 256`). Once R2 reaps properly, the retained directory is a leak of its own; the linked temp file is the only thing the share sheet needs, and nothing removes it after the sheet closes. | same |
| R4 | `LiveMediaDownloadJob.encode(to:)` omits `quality` while `CodingKeys` and `init(from:)` carry it (`LunaModels/LiveMediaDownloadJob.swift`). Persistence is SQLite (`MediaDownloadJobRow` writes the column), so verify whether any Codable path (Live Activity payload, sidecar, tests) round-trips a job; if one does, the quality is lost there. | `LiveMediaDownloadJob.swift` encode block |

The four parallel review agents' findings are appended in §8 when they land and
folded into the work packages below where they touch the same files.

## 2. Work packages

Each package is one agent, one branch, file-disjoint from the others it runs
beside (see §3 for the schedule). "Tests" lists the classes the agent must add
or change and run.

### WP-A — Runtime invocation identity, scratch reaping, multipart `file` (opus)

Owns: `LunaPluginRuntime/PluginRuntime.swift`, `PluginContext.swift`,
`PluginCapabilityRegistry.swift`, `Bridges/PluginFetchBridge.swift`,
`Bridges/PluginFilesBridge.swift`, `LunaPluginKit/PluginScratchStore.swift`,
`PluginFetchService.swift` (request carries the plugin id), the scratch parts
of `LunaPluginIngest/PluginPlatformComposition.swift`,
`LunaPluginExport/PluginExportStage.swift` (sink), `xteink.js` `upload()` only,
`tools/plugin-sim/bridge.mjs` (multipart `file`), `luna-plugin.d.ts`, `api.md`,
`plugins.md` §5.1/§6/§10.2/§14.

A1. **Per-plugin in-flight call tracking replaces `invocationID`/`activeCall`.**
- `PluginRuntime` keeps `inFlight: [pluginID: [PluginPendingCall]]` under its
  lock. `settle` appends its call, removes it when settled or abandoned.
- `notePluginActivity()` becomes `notePluginActivity(pluginID:)`; it touches
  EVERY in-flight call of that plugin. Two concurrent calls of one plugin keep
  each other alive while either is active — state that in a comment; it is the
  honest answer when the bridge cannot tell which hook's continuation is
  running. `PluginCallbackScheduling` and `PluginIdleTouching` gain the
  plugin id parameter; `PluginFetchRequest` gains `pluginID` next to
  `invocationID` so `PluginFetchService`'s byte-progress touch names the plugin.
  Every bridge already has `namespace.pluginID`.
- Also keep touching `processContext.idle` (the pipeline's idle watchdog) as
  today.

A2. **Scratch generations replace per-call invocation ids.**
- A plugin's scratch directory is `<root>/<pluginID>/<generation>/`. A
  generation opens when the plugin's in-flight count goes 0 → 1 and closes
  (reaped) when it returns to 0, unless a file in it was handed on (A3). The
  `PluginBridgeTarget.invocationID` closure answers the CURRENT generation id
  (rename it `scratchGeneration` if that reads better; keep the type).
- Nested calls (`onBluetooth` → `export`) share the outer generation, so the
  export input file written while `onBluetooth` is in flight is reaped when
  `onBluetooth` settles, not before.
- There is ONE `PluginScratchStore` per process, built with
  `pluginID: "shared"` in `PluginPlatformComposition.install` and handed to the
  fetch service, `PluginFilesBridge`, `PluginPlatformServices.scratch` and so
  the export stage. Its directory today is `<root>/shared/<invocationID>/`.
  Re-key it by `(pluginID, generation)` — `directoryURL(pluginID:generation:)`
  — so a reap is scoped to one plugin's generation and `reapAll(pluginID:)`
  can clear one plugin at delete time (`PluginStore.swift:211` removes
  `<root>/<pluginID>` on delete already; make the two agree on the path).
  Keep the id-to-file map in that one instance; every `PluginFileDescriptor`
  handed to JS stays resolvable through it as today.
- `PluginRuntime.loadAll`/`reloadAll` call `reapAll(pluginID:)` for every
  plugin they load (a killed process's leftovers), and a runtime that is
  replaced by a second `install` does not reap the files the new one is about
  to serve.

A3. **Export sink hands on a file without retaining a directory.**
- `PluginExportStage.sink(.file)` copies/hard-links into a per-share temp
  directory (as `linkTemporaryFile` does) and removes that directory in the
  `UIActivityViewController.completionWithItemsHandler` of
  `SystemPluginExportSharePresenter` (add the handler; the presenter protocol
  gains a completion parameter, protocol not closure-stored). Delete
  `PluginScratchStore.retain`/`retention`/`PluginScratchRetention` if nothing
  else uses them after this.
- Same for `.text` results (`writeTemporaryFile`).

A4. **Multipart `file` parts.**
- `MultipartPart` gains `file?: FileHandle` (id trusted only, as
  `PluginFilesBridge.descriptor(from:)` does). `PluginFetchRequestDecoder`
  resolves it through the scratch store (`PluginFetchBridge` gets the store
  injected at init) and appends the bytes. Cap the part at
  `PluginFilesBridge.maxFileBytes`; a missing/reaped file rejects the whole
  fetch with `code: "not-found"` BEFORE any network call. `filename` defaults
  to the handle's `name`, `mime` to the handle's `mime`.
- `xteink.js` `upload()` sends `{ name: "file", file: input.file }` and its
  `export` no longer reads the EPUB to base64 for the Wi-Fi leg (the BLE leg
  still needs the bytes — keep `luna.files.read` there only).
- `tools/plugin-sim/bridge.mjs`: implement `file` for multipart from its
  in-memory files map; Safari `plugin_host.js` has no `files` capability, so
  document that multipart `file` is app/share/action only (§5 table).

Tests (add/adjust; behaviour, not echoes):
- `PluginRuntimeTests`: two overlapping calls of one plugin — the outer
  idle-budgeted `ingest` survives while only the inner call's bridge is active
  (drive via a fake bridge touching activity); nested export inside another
  hook keeps the outer generation; a settled call reaps its generation only
  when the plugin's in-flight count is zero; `reloadAll` clears leftovers.
- `PluginBridgeRuntimeTests`: `luna.files.write` in a hook is gone after the
  hook settles; an export `{file}` result's shared temp file exists during
  presentation and is removed by the completion handler.
- `PluginFetchTests`/`PluginFetchParityTests`: multipart `file` body bytes and
  headers; oversized/missing handle error codes; sim parity where it exists.
- `XteinkPluginTests`: the Wi-Fi upload leg posts the multipart `file` part.

### WP-B — `luna.downloads` read bridge (sonnet)

Owns: new `LunaPluginRuntime/Bridges/PluginDownloadsBridge.swift`, the
`downloads` registration in `LunaPluginIngest/PluginPlatformComposition.swift`
(bridge list only — coordinate: WP-A edits the scratch lines of that file, so
keep your edit to the one `register(...)` line), `LunaLibraries/Package.swift`
(add `LunaStorage` as an explicit dependency of `LunaPluginRuntime` if it is
not already one — `SavesStore.mediaDownloadJobs()` lives there),
`LunaPluginUI/PluginCapabilityCopy.swift` (consent copy for `downloads`) and
the strings file, `bridge.mjs`, `luna-plugin.d.ts`, `api.md`, `plugins.md`
§5/§14/§15.

Design:
- `luna.downloads.jobs(): Promise<DownloadJob[]>` and
  `luna.downloads.job(saveId): Promise<DownloadJob|null>` (return `null`, not
  `undefined`, to match every other bridge's absent answer; update the `.d.ts`).
- `DownloadJob { saveId: string|null; sourceUrl: string; title: string; phase: "resolving"|"downloading"|"waiting"|"suspended"|"saving"|"finished"|"failed"; progress: number; receivedBytes: number|null; expectedBytes: number|null; failure: string|null; pluginId: string|null; quality: string|null }`.
  Phases are the engine's own `LiveMediaDownloadJob.Phase` raw values — do
  NOT invent the plan's `queued`/`deferredUntilWiFi` mapping; record the
  departure in `plugins.md` §15. `saveId` comes from
  `SavesStore.item(forURLString: job.sourceURLString)?.id` (null when the
  save is gone). `job(saveId)` resolves the save's URL then the newest job.
- Read-only: reads `SavesStore.mediaDownloadJobs()` (SQLite in the App
  Group) — no `LiveMediaDownloadManager` dependency, so the bridge serves
  `app`, `share` and `action` alike. Not in Safari (`plugin_host.js` leaves it
  absent; native has no relay for it — say so in §5).
- The bridge takes a `SavesStore` at init (default `.shared`) so tests use a
  scratch database.
- Consent copy: one `Plugins_capability_downloads_Luna` line.

Tests: `PluginDownloadsBridgeTests` — jobs written to a scratch `SavesStore`
appear with the right fields; `job(saveId)` for a save with no job is `null`;
a job whose save was deleted has `saveId: null`; rejects with
`bad-argument` on a non-UUID. `PluginRuntimeTests` grant check: a plugin
declaring `downloads` now loads with `luna.downloads` present in every process
kind.

### WP-C — Localized plugin copy (sonnet)

Owns: `LunaPluginKit/PluginManifestParser.swift`, `PluginManifest.swift`,
a new `LunaPluginKit/PluginLocalizedText.swift`, the `env` block in
`LunaPluginRuntime/PluginContext.swift:61-69` and a `localize` helper in
`PluginBootstrapScript.swift`, `plugin_host.js` (`env` + `localize`),
`bridge.mjs` (same), `luna-plugin.d.ts`, `api.md`, `docs/plugins/README.md`,
`plugins.md` §2.2/§5/§14.

Design:
- **One value shape, one rule.** A manifest field that is user-visible
  (`name`, `description`, `export.title`, `settings[].label`, `settings[].help`,
  `settings[].placeholder`, `settings[].options[].label`) accepts either a
  string or an object `{ "<language tag>": "<text>", … }` that MUST contain
  `"en"` (parse error naming the field otherwise; every value obeys the field's
  existing length cap).
- Resolution: `PluginLocalizedText.resolve(table, preferring languages: [String])`
  walks the preferred list, matching an exact tag first, then the language
  prefix (`pt-BR` → `pt`), then `en`. `PluginManifestParser.parse` takes
  `languages: [String]` (default `Locale.preferredLanguages`) and resolves at
  parse time, so `PluginSettingField.label` etc. stay `String` and no UI file
  changes. The Safari native handler parses through the same entry point.
- JS: `luna.env.languages: string[]` (the same preferred list; keep `locale`)
  and `luna.localize(table: string | Record<string,string>): string` applying
  the identical rule (a string passes through). Implemented three times — the
  bootstrap script, `plugin_host.js`, `bridge.mjs` — from one written rule.
- Bundled plugins keep their English literals (a bare string is still valid);
  add one localized-table example to `docs/plugins/README.md` and
  `export-webhook.js`'s `settings[0].label`.

Tests: `PluginManifestParserTests` — table with `en`+`de` resolves for
`["de-AT"]`, `["fr"]` (falls to `en`), missing `en` fails naming the field,
caps apply to every variant, string form unchanged. `PluginBridgeRuntimeTests`
+ `SafariPluginHostTests` — `luna.localize` answers the same string for the
same table and language list on both backings; `luna.env.languages` present.

### WP-D — Read state, remote delete, and destination bookkeeping through `luna.exports` (opus)

Owns: `LunaSend/XteinkReadStateReconciler.swift` (rename),
`LunaSend/ArticleSendCoordinator.swift` (`ArticleDestination` protocol
additions + `deliverQueuedSends` pre-reconcile only — WP-E edits the readiness
paths later, sequentially), `LunaSend/SourceSendSettings.swift`,
`LunaSend/XteinkDestination.swift`, `LunaPluginKit/PluginManifestParser.swift`
export block + `PluginPlatformSeams.swift` `PluginExportSummary` (coordinate
with WP-C: you add `dequeueOnRead`, WP-C changes string fields — both touch
the parser; keep your diff to the `export` object), `LunaPluginExport/
PluginDestination.swift`, `PluginExportContract.swift` (`status.remoteName`),
`Bridges/PluginExportsBridge.swift`, `LunaPluginUI/PluginDetailScreen.swift`
(one new row) + a new seam, `Luna/ArticleShellWiring.swift`,
`Luna/KindWiring+Reader.swift`, `Luna/KindWiring+Luna.swift`, `xteink.js`
(everything except `upload()`), `claudedocs/xteink.md`, `plugins.md` §5/§8/§9/§14.

D1. **Generalize dequeue-on-read.** Rename `XteinkReadStateReconciler` →
`ReadStateSendReconciler`. It iterates every destination the coordinator
serves whose `dequeuesOnRead` is true (new `ArticleDestination` requirement,
default `false`; `XteinkDestination` → `true`; `PluginDestination` reads a new
manifest field `export.dequeueOnRead: Bool` default false, which `xteink.js`
declares). `startObservingSaveChanges()` moves to `ArticleShellWiring
.appDidLaunch()` (compiled into both Luna and Luna Reader, excluded from the
two apps that link no LunaSend) and is removed from `KindWiring+Reader`.
`ArticleSendCoordinator.deliverQueuedSends(toDestinationID:)` runs the
reconcile for that destination before reading the queue, so a plugin's
`luna.exports.deliverQueued()` gets the same pre-sweep behaviour the Swift
sweep has (`KindWiring+Reader` passes `reconcileReadState:` today — keep it
or drop it once the coordinator does it; do not do it twice).

D2. **Record remote names for plugin deliveries.** `{status:"sent"}` may carry
`remoteName?: string`. `PluginExportResult.status` decodes it;
`PluginDestination.deliver` calls `context.savesStore.recordRemoteDelivery(for:destination:remoteName:)`
when present (verify `ArticleSendContext` exposes the store; §8.3 says it
does). `xteink.js` returns `{ status: "sent", remoteName: fileName }` and
deletes `recordDelivery` and the `deliveries` collection.

D3. **`luna.exports` grows the read-state surface.**
- `pendingDeletes(): Promise<{ saveId, title, remoteName }[]>` — sends for
  this destination with `remoteDeleteStatus == .deletePending` and a recorded
  remote name.
- `markRemoteDeleted(saveId): Promise<void>` → `SavesStore.markRemoteDeliveryDeleted`.
- `markReadOnDevice(saveId): Promise<void>` → exactly what Luna Reader's Swift
  read-report path does (read `XteinkSyncProtocol`/the reader wiring in
  `KindWiring+Reader` and mirror the store calls in the same order:
  `markRemoteDeliveryReadOnDevice` then `markFinishedReading`). Keep
  `markSent` for the "already on the reader" reconciliation it was meant for.
- App-only like the rest of the bridge (`unavailable-here` elsewhere).
- `xteink.js`: `drainPendingDeletes` reads `pendingDeletes()` and calls
  `markRemoteDeleted` after a successful `delete` control op or a
  missing-file error; `reconcile` calls `markReadOnDevice` for each reported
  id. Delete the `pendingDeletes` collection and its constant.

D4. **Per-destination App Intents mode and a way to reach it.**
- `SourceSendSettings.appIntentsMode/setAppIntentsMode` keep the two legacy
  keys for `kindle`/`xteink` and read/write `send.<id>.appIntentsMode` for any
  other id (default `.off` for an unknown id — a new destination must be
  turned on deliberately).
- `PluginDetailScreen` shows an "Auto-send" row for a destination plugin that
  pushes the per-source screen. `AutoSendBySourceScreen` is app-shell code
  (`Luna/Settings/`), so add a seam in LunaPluginUI —
  `protocol PluginDestinationAutoSendPresenting { func presentAutoSend(destinationID: String, displayName: String, from: UIViewController) }`
  — installed by `KindWiring+Luna` (protocol witness, not a closure). Absent
  witness → no row.

Tests: `ReadStateSendReconcilerTests` (rename `LunaTests/XteinkReadStateReconcilerTests.swift`;
`XteinkRendezvousSweepPolicyTests` and `XteinkRemoteDeleteRunnerTests` stay
and must keep passing) —
dequeue applies to every `dequeuesOnRead` destination and to none other;
immune sends stay. `PluginExportsBridgeTests` (new or extend
`PluginExportStageTests`) — `pendingDeletes` lists only `.deletePending` sends
with names; `markRemoteDeleted`/`markReadOnDevice` produce the same store
transitions as the Swift path (write the Swift expectation from
`XteinkRemoteDeleteRunner`/the read-report handler, run both, compare the
`SavedItem` fields). `XteinkPluginTests` — a read-report window marks the save
finished in Luna and the delivery `.readOnDevice`; a normal window drains
`.deletePending` sends via `delete` and clears them; delivery records the
remote name in the store. `SourceSendSettingsTests` — a new id round-trips its
mode and defaults `.off`; the two legacy ids still read their legacy keys.
`PluginDetailScreenTests` — the row appears only for a destination plugin with
a witness installed.

### WP-E — Kind-neutral auto-send for media and product destinations (opus, after WP-D merges)

Owns: `LunaSend/ArticleSendCoordinator.swift`, `LunaSaves/IngestorKindHandlers.swift`
(or a new seam file in LunaSaves), `Luna/ArticleShellWiring.swift`,
`Luna/MediaShellWiring.swift`, `Luna/ProductShellWiring.swift`, the point in
`LunaMediaDownload` where a finished download becomes a saved file (find it:
`LiveMediaDownloadManager.finish(job:downloadedTo:)` → `finishDownloaderStorage`
→ `SavedMediaStore.addDownloadedFile`), `LunaPriceUI/ProductTrackerIngestor.swift`
(end of `ingestProductTracker`), `LunaPluginExport/PluginDestination.swift`
(`accepts`), `plugins.md` §8/§14, `claudedocs/send-to-kindle.md` if it
describes auto-send scope.

Design:
- `ArticleDestination` gains `func accepts(_ item: SavedItem) -> Bool`
  (default: an article — not `isPlatformItem`, not a product tracker; use the
  same kind derivation `PluginExportInputProducer.kind(of:)` uses, moved down
  to LunaModels or LunaSend as `SavedItem.exportKind` if it is not already
  there). `PluginDestination.accepts` = `export.kinds.contains(kind(of: item))`.
- `articleBecameReady(_:)` → `saveBecameReady(_:)` (keep the old name as a
  one-line forwarding method only if a foreign-kind caller cannot be changed
  in this wave; otherwise rename the callers). The `!isPlatformItem` guards in
  `articleBecameReady` and `sendBuildingEPUB` become `destination.accepts(fresh)`.
  `retryPendingSends` filters by `accepts` too.
- Trigger seam: a protocol in LunaSaves, `SaveReadinessObserving
  { func saveBecameReady(_ item: SavedItem) }`, at `IngestorKindHandlers
  .readiness` (nil where no LunaSend is linked — Downloader, Price Tracker).
  `ArticleShellWiring.install()` installs the coordinator adapter (the article
  path already routes through `IngestorArticleHandling.articleBecameReady`;
  route it through the same witness so there is ONE readiness path). The media
  kind calls it when the downloaded FILE is on disk and the save is `.ready`
  (a media destination's input is the file — `PluginExportInputProducer
  .mediaFile` — so "metadata ready" is too early). The product kind calls it
  when the tracker is created.
- What a media/product save's `state`, `effectiveCaptureSource` and
  `SendState` look like must be verified before coding: read `SavedItem`,
  `SavedMediaStore`, `ProductTrackerIngestor`. If a media save is never
  `.ready` in the `saves` table (its file lives in the media store), decide
  the readiness predicate with the store's real fields and document it.
- Double-save press (`doubleSaveDestinationIDs`) stays article-only; say so
  in `plugins.md` §8.
- `sendTestDocument` is article-shaped and unreachable for plugin
  destinations; leave it, but make `PluginDestination.send(epubData:…)` throw
  a message that names the reason (it does).

Tests: `ArticleSendCoordinatorTests` (exists? check) — a media destination
auto-sends a finished media save when its mode is `.allSaves`, never an
article; an article destination never receives a media save; retry sweep
honours `accepts`. `PluginExportStageTests` — media destination delivery
receives `format: "file"` with the downloaded file handle. A test that the
Downloader-shared `MediaShellWiring` path is a no-op when the readiness seam
is nil (no LunaSend symbol named).

### WP-F — Review findings (assigned after §8 is filled)

Grouped by file ownership so they can run beside A–E or after; see §8.

## 3. Schedule and merge order

```
main ── plugin-hardening (integration; the plan commit)
          ├── wp-a-runtime        (opus)   ─┐
          ├── wp-b-downloads      (sonnet)  ├─ parallel, file-disjoint
          ├── wp-c-localized-copy (sonnet)  │
          └── wp-d-read-state     (opus)   ─┘
   merge A → B → C → D into plugin-hardening (orchestrator; small conflicts
   expected only in PluginPlatformComposition.swift and PluginManifestParser.swift)
          └── wp-e-kind-neutral-send (opus)  — after D is merged
          └── wp-f-* review fixes            — beside or after E per §8
   full suite once: scripts/run_tests.sh --fresh from the integration worktree
   merge plugin-hardening → main, delete worktrees and branches
```

Rules for the orchestrator (me): merge in a scratch worktree, never in the
Xcode-open checkout (memory: Xcode rewrites `project.pbxproj` after a merge);
verify every branch's base is `plugin-hardening`, not stale `main`.

## 4. Definition of done

- Every §1 row is closed or explicitly re-listed in `plugins.md` §14 with the
  reason it stays.
- `claudedocs/plugins.md`, `docs/plugins/api.md`, `luna-plugin.d.ts`,
  `bridge.mjs`, `plugin_host.js` agree on every namespace, method, argument
  and error code (WP-A/B/C/D each update their part; the R4 review agent's
  drift list is the checklist).
- `scripts/run_tests.sh --fresh` on the integration worktree: 0 failures.
- `CLAUDE.md` "Plugins" section: known-gaps sentence updated.

## 5. Review findings — where each one is fixed

Four read-only review agents covered the platform on 2026-09-02. Their full
reports, with file:line evidence and a proposed fix per item, are committed at
`claudedocs/plans/plugin-hardening-reviews/R1-kit-runtime.md`,
`R2-ingest-safari.md`, `R3-export-transport.md`, `R4-ui-docs.md`. An
implementation agent reads the items assigned to it there; this section only
assigns them. "R1#3" means finding 3 of report R1.

### 5.1 Added to WP-A (runtime / kit / fetch / export sink)

| Item | One line |
| --- | --- |
| R1#1 | `load` evaluates plugin JS on the calling thread; route `evaluate`/`seal`/`grantedNamespaces`/`strayNamespaces` through the execution queue and add the `isWedged` guard `settle` has |
| R1#2 | `PluginFetchService.transfers` keyed by `taskIdentifier` across three sessions; key by `ObjectIdentifier(task)` |
| R1#3, R1#4 | `PluginQueueItem` needs a `started` flag: abandoning an unstarted item must not count a wedge, and the wall-clock budget starts when the body starts |
| R1#5 | `as:"file"` write failure must reject `write-failed`, not fulfil with no file |
| R1#6 | **Decision: delete the `cookies:"browser"` policy** (and `PluginBrowserCookieProviding`) rather than wire it. The browser result already hands the plugin `cookieHeader` (`PluginBrowserResult.jsObject`), so a plugin sets the header itself; a decoded `"browser"` value rejects `bad-argument`. Update §5.1, `api.md`, `.d.ts`, `bridge.mjs` |
| R1#7, R4#12 (storage half) | `luna.fetch` and `luna.storage.collection` bad arguments must reject with `bad-argument`, never throw synchronously (`PluginBridgeValue.raise` stays only for the synchronous `luna.html` API) |
| R1#8 | `PluginStore.install` must move the new version in before removing old ones |
| R1#9, R1#10, R1#12, R1#13, R1#14 | Dead seams and code: `exceptionReporter`, `PluginVirtualMachineScope.isolated`, `installedCapabilities`/`isRegistered`, the identical-arm ternary, the double `unload` in `PluginCatalog.delete` |
| R1#15 | `PluginHTMLNodeHandle.value` must never fall back to `JSContext()` (a new VM) |
| R1#16 | `PluginCapabilityRegistry` frozen into the runtime at construction (or locked) |
| R1#17 | `luna.files.read` without `"base64"` rejects `not-text` on non-UTF-8 bytes |
| R1#22 | `PluginFetchService` invalidates its sessions on replacement/deinit |
| R1#23 | An abandoned call drops its pending `PluginPromiseBox` values so an unsettled bridge cannot pin the `JSContext` |
| R2#4, R2#22 | `PluginIngestScope` is one global slot and races across concurrent saves. Replace with a per-plugin set of in-flight ingest save ids kept by the runtime's in-flight tracking (A1): `luna.browser.open` uses the one in-flight save when there is exactly one, honours an explicit `saveId` in the request otherwise, and rejects `bad-argument` naming `saveId` when several are in flight and none was given. Drop the unread `reason`. Touches `PluginBrowserBridge.open` (LunaPluginUI) — WP-F2 must not edit that method |
| R2#9 (JSC half) | `luna.storage.get` on a missing key fulfils `undefined`, matching the bridge's own comment and the `.d.ts`; Safari half is WP-F1 |
| R3#17 | `linkTemporaryFile`/`writeTemporaryFile` directories are removed when the share sheet completes (A3) |
| R1#24, R1#25 | One concurrency suite (two plugins, two hooks, `Promise.all` fetches); delete the spec-count echo test |

### 5.2 Added to WP-B (downloads + media re-resolve)

| Item | One line |
| --- | --- |
| R2#6 | `LiveMediaDownloadJob.encode(to:)` omits `quality`; the Codable pair is test-only — encode it and re-point `testRedditCompanionURLsSurviveJobPersistence` at `MediaDownloadJobRow`, or delete the hand-written Codable if nothing needs it |
| R2#7 | `reresolvePluginJob` never bumps an attempt counter; a plugin returning a dead URL loops on every 403. Add the guard and fall into `retryOrFail` |
| R2#12 | Re-resolution passes a download-job id as `saveId`. Pass the real save id if the job can carry it, else pass nil and rename the `MediaReresolving` parameter `jobID` so the wire field is honest; document in §6.1 |
| R2#24 (first bullet) | Delete the `statusInvitesReresolve` constant-echo test |

### 5.3 Added to WP-C (manifest parser + localization)

| Item | One line |
| --- | --- |
| R1#18 | Every boolean manifest field goes through the one `flag` helper; an unencodable `settings[].default` is an error |
| R1#19 | `settings[].key` is ASCII `[A-Za-z0-9_]`, as documented |
| R1#20 | A host pattern with `*` anywhere but a leading `*.` refuses import with a hint to use `any: true`; also escape quotes/CRLF in multipart part headers (`encodeMultipart` is WP-A's file — hand WP-A the one-line note instead of editing it) |
| R1#21 | Every `export.requiresSettings` entry must name a declared settings key |
| R4 "also noticed" | `luna.env.locale` is `en_US` in Swift and `en` in both JS backings; make all three the BCP-47 form of the first preferred language and add `languages` (C's own item) |

### 5.4 Added to WP-D (export/send bookkeeping, detail screen, xteink.js)

WP-D owns `PluginDetailScreen.swift` and `PluginChoiceScreen.swift` outright, so
the UI items that touch them land here rather than in WP-F2.

| Item | One line |
| --- | --- |
| R3#1 | Pairing is unreachable: the `pairedDevice` row invokes `onAction` with `{key: "device"}` and `xteink.js` handles only `pair`/`unpair`. Contract fix: the screen sends `{ key: field.key, action: "pair" \| "unpair" }` for a `pairedDevice` field; `xteink.js` branches on `input.action`; `.d.ts`/`api.md` updated; a test drives the row |
| R3#2, R3#23 | `{status:"retry"}` must be a deferral: `PluginDestinationError.retry` conforms to `SendDeferralError` (no failure count, no backoff); fix the test that pins the backoff |
| R3#3 | The reader's `low_memory` refusal must stop the sweep on the plugin path too — add `{status:"failed", reason:"receiver-busy"}` (or read the message) and have `deliverQueuedSends` break on it |
| R3#4 | = D2 (record remote delivery core-side from `remoteName`) |
| R3#5 | = D3, plus: `reconcile` loops until `link.readIDs` is empty (the reader hands back at most two ids per status) |
| R3#7 | `PluginMailBridge` reads `PluginMailRecipients.picker` at call time, not in `init` |
| R3#11 | `sendOverWiFi` retries the upload once after a 2 s pause, mirroring `XteinkCrossPointTransferRouter.uploadRetryPause` |
| R3#12 | Central Luna still pushes the Swift `KindleSettingsScreen` from the double-save setup; re-run `migrateKindleAddress` when it commits, or point that presenter at the plugin detail screen in central Luna |
| R3#13 = R4#1 | `onSettingsChanged` receives `{ "<key>": value }`, the documented map |
| R3#16 | Implement `userNotificationCenter(_:didReceive:)` in `Luna/AppDelegate.swift` to open a plugin notification's `lunaPluginDeepLink`, or drop the parameter from the bridge and docs |
| R3#18 | A `file`/`text`/`url` result from an `auto: true` export is a hard failure, never "sent" |
| R3#19 | `x3FileName` iterates `Array.from(name)` so astral characters map like Swift's per-scalar rule; add the emoji case to `XteinkPluginTests` |
| R3#21 | `PluginMailMIME` nests `multipart/alternative` when both bodies and an attachment exist; escape quotes in the attachment filename parameter |
| R3#22 | Add `SavesStore.items(sendState:forDestination:)` (one query) and use it in `CoordinatorPluginExportQueue` and `deliverQueuedSends` |
| R3#24, R3#25 (first bullet) | Re-point the remote-delete tests at the store's real fields; delete the Kindle manifest echo test; test `PluginNotificationsBridge.clear`'s prefix path |
| R4#4 | `commitValue` reloads the row after a `choice`/`toggle` |
| R4#7 | `help` renders for every field type, not only `info` |
| R4#24 | `PluginFieldEditCell.onCommit` and `PluginChoiceScreen.onSelect` become weak delegates |
| R4 "also noticed" | `luna.exports.queued()` — make `queuedAt` nullable in the `.d.ts` or always present |

### 5.5 WP-E — unchanged

### 5.6 WP-F1 — Safari parity and the ingest walk (opus; after WP-A merges)

Owns `LunaSafari/Resources/plugin_host.js`, `LunaSafari/Resources/content.js`
(plugin parts), `LunaSafari/SafariPluginMessages+Luna.swift`,
`LunaPluginIngest/PluginIngestStage.swift`, `PluginPriceFetcher.swift`,
`LunaModels/Plugin/PluginModel.swift`, `LunaReaderUI/ArticleModelAdopter.swift`,
`Luna/PluginModelDrain.swift`, `LunaStorage/PendingPluginModelStore.swift`,
`tools/plugin-sim/bridge.mjs` (`LunaError`, settings schema), the fetch
request shaping (moved into `LunaPluginKit`), and the tests named.

| Item | One line |
| --- | --- |
| R2#1, R2#23 | An adopter answering `.failed` returns `.continueWalk`; test it through the stage |
| R2#2 = R4#6 | `LunaError(code, message, details)` in `plugin_host.js` and `bridge.mjs`; add the error-shape case to the parity harness |
| R2#3 | Move `PluginFetchRequestDecoder`'s shaping (userAgent identity, `form`/`json`/`multipart`, reserved headers) into a Foundation-only type in `LunaPluginKit` and call it from `SafariPluginMessages+Luna.pluginFetch`, with a parity test |
| R2#5 | `PluginModelDrain` honours `returnToSourceUntil` like `PendingResolvedMediaDownloads` |
| R2#8 | Safari `settings.get` returns the manifest default; `set`/`all` stubs reject `unavailable-here` |
| R2#9 (Safari half), R2#19 | Storage: `set(k, undefined)` rejects `bad-argument`; native `ok:false`/`error` becomes a rejection in `plugin_host.js`; shape failures answer `bad-argument`, not `capability-not-declared` |
| R2#10, R2#11 | Safari walk continues to the next matched plugin on a `null` ingest; a claim whose kind is not in `produces` is refused |
| R2#13 | `PluginPriceFetcher.price` returns nil unless the plugin matches the store URL's host and declares `product` |
| R2#14 | Safari passes a `PageSnapshot` (`source: "safari"`) to `classify`/`ingest`; fix the stage's comment |
| R2#15 | `PluginModelDrain.opener` becomes a `PluginModelReturnOpening` witness installed by `KindWiring+Luna` |
| R2#16, R2#21 | One `outcome(from:)` mapping in LunaIngest used by the stage and the drain; drop the adopter's redundant header filter |
| R2#17, R2#18 | `plugins.log` checks the plugin is enabled; the handler caches the enabled set for the process |
| R2#20 | Cap the article adopter's `document.url` fetch at `WebFetchConstants.maxBytes`, cap header values, reject negative `estimatedBytes` |
| R2#22 (second bullet) | Compare the catalog stamp in `loadPluginCatalog` or stop sending one |
| R4#10 | `plugin_host.js` installs the `unavailable-here` stand-in for every declared capability it cannot serve |
| R4#15 (settings) | `bridge.mjs` settings honour the manifest schema (defaults, secret masking, undeclared-key check) |
| R2#25 | One parity suite driving the same script through `PluginJSFixtureRunner` and `SafariJSTestHarness` for error codes, storage and settings; register `PluginSettingsBridge` in the fixture runner |

### 5.7 WP-F2 — plugin UI, docs, tests (sonnet; after WP-A and WP-D merge)

Owns every LunaPluginUI file EXCEPT `PluginDetailScreen.swift`,
`PluginChoiceScreen.swift` and `PluginBrowserBridge.open` (WP-D / WP-A),
`Luna/Stage/StageCatalog+Plugins.swift`, the plugin strings, `docs/plugins/*`,
`tools/plugin-sim/README.md` and the `bridge.mjs` header comment, and the
tests named.

| Item | One line |
| --- | --- |
| R4#2 | `luna.ui.choose`/`shareSheet` set a popover source (iPad crash) |
| R4#3 | `shareSheet` resolves a `FileHandle` through the scratch store and DROPS the `{path}` branch |
| R4#5 | Paste-import's Import button follows `keyboardLayoutGuide` |
| R4#8 | `StageCatalog+Plugins.swift`'s `#endif` moves to the end of the file |
| R4#9 | Consent copy for `browser` and `wifi` names the real reach |
| R4#11, R4#13, R4#14, R4#25 | Docs: README's per-hook restriction softened; `api.md` error-code table completed (`not-configured`, `join-failed`, `runtime`, `capability-not-declared`, `too-large` on `set`); `bridge.mjs` header lists what it implements; README cross-references fixed; a "Settings schema" section added; the two wrong doc comments corrected |
| R4#16 | `PluginPlatformBootTests.tearDown` reinstalls the app's full composition — extract `KindWiring+Luna`'s bridge assembly into one function both call |
| R4#17 | `KindCompositionRootTests` pins export/transport/`installAppWitnesses` composition to the app root |
| R4#18 | `PluginUIBridge` and `PluginSettingsBridge` get behaviour tests (unavailable-here, share items, undeclared key, `_` key, secret masking, defaults) |
| R4#19 | Replace the fixed 0.2 s pumps with polled conditions; delete the false comment |
| R4#20 | Article rows in `PluginLockedSaveRoutingTests` |
| R4#21 | A same-capability update shows the consent screen in review form (or a version-naming confirmation) |
| R4#22 | One browser-modal presentation shared by `ModalPluginBrowserPresenter` and `PluginUnlockFlowRunner` |
| R4#23 | Delete `LunaPluginUIPlaceholder.swift` and the uncalled `PluginImporter.preview(fileAt:)` (or route the coordinator through it) |

### 5.8 WP-F3 — Bluetooth transport (opus; parallel with phase 1)

Owns `LunaPluginTransport/` and its tests only.

| Item | One line |
| --- | --- |
| R3#8 | `dispatch(holdingLock:)` distinguishes "held by this center" from "held by another process"; a reconnect mid-sweep does not close the new session |
| R3#9 | `PluginBluetoothSession.next`'s timeout removes only its own waiter (token-keyed) |
| R3#10 | `whenReadyToWrite` has a deadline and fails `timed-out` instead of wedging the session |
| R3#14 | Characteristic UUIDs normalised through one `key(_:)` on both the delivery side and the session's tables |
| R3#15 | `onBluetooth` events dispatch one at a time per center, as §9 states |
| R3#20 | A second `luna.bluetooth.connect` for a device with a waiter rejects with its own code |
| R3#25 | Tests for `connect`'s timeout and `SystemPluginWiFiJoiner`'s 3 s re-apply |

## 6. Revised schedule

```
Phase 1 (parallel, file-disjoint):  WP-A  WP-B  WP-C  WP-D  WP-F3
   merge into plugin-hardening in that order
Phase 2 (parallel):                  WP-E  WP-F1  WP-F2
   merge E → F1 → F2
Full suite once (scripts/run_tests.sh --fresh), then plugin-hardening → main
```

Shared-file etiquette: `claudedocs/plugins.md`, `docs/plugins/api.md`,
`tools/plugin-sim/luna-plugin.d.ts` and `bridge.mjs` are edited by several
packages. Each agent edits only the lines its own change makes true and never
reflows or reorders the rest, so the merges stay textual.

## 7. (reserved)

## 8. Review reports

See §5; the reports themselves are in `claudedocs/plans/plugin-hardening-reviews/`.
