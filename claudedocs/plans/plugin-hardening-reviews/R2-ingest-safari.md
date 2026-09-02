# Review R2 — plugin ingest walk, Models, adopters, Safari bridge

Read-only review against `claudedocs/plugins.md` §1, §3, §4, §6, §7, §12, §14.
Every claim below was traced through the actual code path. Ranked most severe
first. File:line refers to `main` at review time.

---

## 1. BUG — an adopter failure fails a save the Swift floor could still make

`LunaLibraries/Sources/LunaPluginIngest/PluginIngestStage.swift:211-214`

```swift
case let .failed(reason):
    SaveDiagnostics.record("plugin \(plugin.id): adoption failed", category: "plugin")
    return .produced(.failed(reason))
```

`.produced` reaches `IngestPipeline.swift:260-261`, which RETURNS the result;
`Classifier.classify` at line 272 never runs. So the save is failed by the
plugin path.

This is reachable with no plugin misbehaviour at all:
`LunaLibraries/Sources/LunaReaderUI/ArticleModelAdopter.swift:51-54` answers
`.failed(.notReadable)` whenever `ArticleExtractor.convertTrusted` throws — an
empty or unconvertible `html` fragment. The plugin claimed the page, returned a
Model, and Luna's own Swift article path (fetch + extract) is never tried.

It contradicts the class's own header (`PluginIngestStage.swift:20`, "A broken
plugin must never fail a save Swift could have made"), §6 step 3 of the doc, and
the sibling code path: `Luna/PluginModelDrain.swift:116` maps `.failed` to nil
and falls back to a normal ingest. Two implementations of one rule disagree.

**Fix:** return `.continueWalk` (logging `reason`) so the walk falls through to
the next plugin and then to the Swift classifier, matching the drain.

---

## 2. BUG — `LunaError`'s arguments are swapped between the two JS backings

- JSC: `LunaLibraries/Sources/LunaPluginRuntime/PluginBootstrapScript.swift:28`
  `constructor(code, message, details)`
- Safari: `LunaSafari/Resources/plugin_host.js:20`
  `constructor(message, code, details)`

A plugin writing `throw new luna.LunaError("hard", "the reader refused it")`
gets `code === "hard"` in the app and `code === "the reader refused it"` in
Safari. Everything that keys off a code is affected — `PluginExportStage
.isTerminal`'s `"hard:"` prefix (doc §3.3), and `content.js:446`
(`error.code === "browser-deferred"`), which only works today because
`plugin_host.js:384` happens to pass the same string twice.

The two backings are supposed to be pinned to one specification
(`html-subset.spec.js`), but that spec covers `luna.html` only, so nothing
catches this.

**Fix:** make `plugin_host.js`'s constructor `(code, message, details)` and add
an error-shape case to the parity harness.

---

## 3. BUG — Safari's `luna.fetch` drops `userAgent` and every structured body

`LunaSafari/SafariPluginMessages+Luna.swift:193-212` builds the request by hand:

```swift
if let bodyText = requestDict["body"] as? String { body = Data(bodyText.utf8) }
else if let bodyDict = requestDict["body"] as? [String: Any],
        let base64 = bodyDict["base64"] as? String { body = Data(base64Encoded: base64) }
```

`PluginFetchRequestDecoder.decode`
(`LunaLibraries/Sources/LunaPluginRuntime/Bridges/PluginFetchBridge.swift:97-107,
128-151`) additionally honours `userAgent` (mapping a named
`PluginCrawlerIdentity` and its `X-Forwarded-For`), `form`, `json` and
`multipart` bodies with their content types, and strips reserved
`host`/`content-length` headers. None of that exists in the Safari path.

This is not hypothetical for the shipped plugins:
`instagram.js:328` (`userAgent: "googlebot"` — per the project's own findings the
only keyless source for a reel's `video_url`), `tiktok.js:34`, `reddit.js:74`,
`facebook.js:61`, and `youtube.js:337/380`, which POSTs `body: { json: {...} }`
to the Android VR player. In Safari the UA is the page's own and the YouTube POST
carries an empty body, so those resolvers behave differently in the one process
whose whole point is running the same plugin.

**Fix:** move the request shaping into a Foundation-only type in `LunaPluginKit`
(which the Safari appex already links) and call it from both, or port the missing
branches with a parity test.

---

## 4. BUG — `PluginIngestScope` is a process-global slot and concurrent saves race

`LunaLibraries/Sources/LunaPluginIngest/PluginIngestScope.swift:19-20`

```swift
private static let lock = NSLock()
private static var scope: (saveID: UUID, reason: PluginIngestReason)?
```

`run` swaps a value in and restores the previous one, which is only correct when
walks never overlap. They do: `LunaLibraries/Sources/LunaSaves/SavesIngestor
.swift:509-511` spawns `Task { await self.ingest(item, …) }` per pending row with
no concurrency limit. With two walks in flight, save B's `run` overwrites save
A's id; A's plugin then calls `luna.browser.open`, `PluginBrowserBridge.swift:92`
reads `currentSaveID` and the deferred request is written against the WRONG save
(`PluginBrowserRequestStore`, `save_id` primary key), so the lock lands on B and
A silently continues.

The same value one tier up is a `@TaskLocal`
(`LunaModels/SaveDiagnostics.swift:139`) for exactly this reason.

**Fix:** key the scope by the runtime's invocation id (which the bridge already
has via `namespace.target.invocationID`) instead of a single global slot, or hold
a dictionary keyed by plugin id.

---

## 5. BUG — the Safari return-to-source lifetime is computed, stored, and never read

`LunaSafari/SafariPluginMessages+Luna.swift:41-46,371` sets
`returnToSourceUntil: now + 60`, with a comment explaining precisely the failure
it prevents ("cannot bounce a manual app launch back to an old Safari page
tomorrow"). `PendingPluginModelStore` writes and reads the column
(`LunaLibraries/Sources/LunaStorage/PendingPluginModelStore.swift:69,99`).

Nothing consumes it. `Luna/PluginModelDrain.swift:57-60` bounces on the
deep-link's `ret=safari` flag alone. Rows survive an hour
(`PendingPluginModelStore.lifetime`, line 47), so a cold manual launch up to an
hour later still throws the user into Safari.

The sibling media hand-off does enforce it:
`LunaLibraries/Sources/LunaMediaDownload/PendingResolvedMediaDownloads.swift:26`
filters `($0.returnToSourceUntil ?? .distantPast) > now`.

**Fix:** in `PluginModelDrain.run`, gate the bounce on
`rows[0].returnToSourceUntil > Date()`, mirroring `PendingResolvedMediaDownloads`.

---

## 6. BUG — `LiveMediaDownloadJob.encode(to:)` omits `quality`

`LunaLibraries/Sources/LunaModels/LiveMediaDownloadJob.swift:239-269` encodes 25
fields and never writes `.quality`, though it is in `CodingKeys` (line 192) and
`init(from:)` reads it (line 236). The Codable round trip is lossy in one
direction.

Persistence itself is safe — the SQLite row binds and reads the column
(`LunaLibraries/Sources/LunaStorage/MediaDownloadJobRow.swift:105,145`) — and a
grep shows the only `JSONEncoder`/`JSONDecoder` users of this type are in
`LunaTests/LiveMediaDownloadJobTests.swift`. That makes it worse rather than
better: the Codable conformance is a test-only surface with a hole in it, and
`testRedditCompanionURLsSurviveJobPersistence` (line 199-216) is *named* for
persistence while exercising the path that is not persistence — it would pass
while `quality`, the field §6.1 says schema 13 exists for, silently vanished.

**Fix:** encode `quality` and re-point that test at `MediaDownloadJobRow`, or
delete the hand-written Codable pair since nothing in production uses it.

---

## 7. BUG — a persistently 403ing plugin URL re-resolves forever

`LunaLibraries/Sources/LunaMediaDownload/LiveMediaDownloadManager.swift:1496-1500`

```swift
// A plugin-owned job answers a stale-URL status by asking its
// plugin for a fresh URL, once, before the retry ladder runs.
if Self.statusInvitesReresolve(http.statusCode),
   await self.reresolvePluginJob(job) { return }
```

The comment says "once"; nothing enforces it. `reresolvePluginJob`
(lines 656-693) rewrites the job, resets `progress`/`receivedByteCount`/
`errorMessage`, sets `phase = .downloading` and starts a new task — and never
touches `mediaAttempts` or records that a re-resolution already happened. If the
plugin keeps answering with a URL that 403s (an IP-bound CDN, a broken
signature), `finish` → 403 → re-resolve → `finish` → 403 loops with no ceiling
and no path into `retryOrFail`.

**Fix:** bump `mediaAttempts` (or add a `reresolveAttempts` guard) inside
`reresolvePluginJob` and fall through to `retryOrFail` past one attempt.

---

## 8. BUG — Safari's `settings.get` never returns a field's declared default

`LunaSafari/SafariPluginMessages+Luna.swift:341` — `guard let stored else { return [:] }`.

The app's bridge answers the manifest default:
`LunaLibraries/Sources/LunaPluginUI/PluginSettingsBridge.swift:118` —
`return stored ?? field.defaultJSON`.

A plugin whose manifest declares `quality` defaulting to `"1080p"` reads
`undefined` in Safari until the user opens Settings and touches the field. Every
`luna.settings.get` call site in a plugin has to be written twice or it behaves
differently on the two surfaces.

Two smaller members of the same gap: `plugin_host.js:359-366` installs only
`get`, so `luna.settings.set`/`all` are a `TypeError` in Safari rather than the
`unavailable-here` rejection the extensions give
(`PluginSettingsBridge.swift:55-58`).

**Fix:** read the manifest field's `defaultJSON` in `pluginSettingsGet`, and add
`set`/`all` stubs that reject `unavailable-here`.

---

## 9. BUG — `luna.storage` semantics differ in three ways between the backings

`LunaLibraries/Sources/LunaPluginRuntime/Bridges/PluginStorageBridge.swift` vs
`LunaSafari/Resources/plugin_host.js` + `SafariPluginMessages+Luna.swift`:

| case | JSC | Safari |
| --- | --- | --- |
| `get` on a missing key | `box.fulfill(NSNull())` → JS `null` (line 47-52) | native `[:]` → `r.value` is `undefined` (plugin_host.js:309) |
| `set(k, undefined)` | rejects `bad-argument` (line 65-68; `jsonText(nil)` → nil, `PluginBridgeSupport.swift:71`) | `jsonString(fromNativeValue: nil)` returns `"null"` (line 383) → stores JSON null, `{ok:true}` |
| value/document over the row cap | rejects `too-large` (lines 71-74, 150) | native returns `{ok:false}`, which plugin_host.js:313/329 discards → the promise RESOLVES |

The first row also makes `PluginStorageBridge.swift:48-49`'s own comment wrong
about its own code: it says "`undefined` is the answer for a key that holds
nothing; `null` is a value a plugin may have stored on purpose", but both cases
produce `null` on this backing, so the distinction it describes exists only in
Safari. A plugin using `null` as a sentinel gets opposite answers per process,
and a plugin whose write silently failed in Safari keeps going.

**Fix:** make JSC fulfil `undefined` for a missing key, reject `bad-argument` for
`undefined` in the Safari handler, and have `plugin_host.js` reject when the
native reply carries `ok: false` or `error`.

---

## 10. BUG — Safari abandons the whole walk when a plugin declines in `ingest`

`LunaSafari/Resources/content.js:490-500` — the pill's tap runs
`runPluginIngestForWalk`, and a null outcome navigates to the plain
`save?url=` hand-off. `pluginVideoOverlayTargetFor`'s `resolveMedia`
(lines 518-531) likewise returns `{ assets: [] }`.

`PluginIngestStage.swift:151-154` handles the same answer by continuing to the
NEXT matched plugin. §6 step 3 of the doc calls that "the 'claimed, then
declined' case the prior module platform could not express" — the central fix of
this walk. It does not exist in Safari.

It fails safe (the plain save still happens), but a second matched plugin never
gets its turn on a page in Safari.

**Fix:** iterate the remaining `matched` list on a null ingest, the way
`walkClassify` already recurses.

---

## 11. BUG — Safari honours a claim of a kind the plugin does not declare

`content.js:408` — `if (claim && claim.kind) { return { plugin: meta, claim: claim }; }`.

`PluginIngestStage.swift:93-99` refuses exactly this and logs it: a claim whose
`kind` is not in `produces` is "treated as a failure to claim". Safari builds the
pill from the bogus kind (a `product` claim from a media-only plugin gets the
"Track in Luna" pill, `content.js:478-481`) and the mismatch is only caught at
`pluginQueueModel` (`SafariPluginMessages+Luna.swift:367`), by which point the
user has already tapped.

**Fix:** add `meta.produces.indexOf(claim.kind) >= 0` to the `walkClassify` test.

---

## 12. DESIGN — re-resolution hands the plugin a download job id as `saveId`

`LiveMediaDownloadManager.swift:662-663` calls
`reresolver.reresolve(sourceURL:pluginID:saveID: persistedJob.id)`, and
`PluginMediaResolver.walk` puts that straight into
`PluginIngestHookInput.saveID` (`PluginMediaResolver.swift:75`).

`job.id` is a fresh `UUID().uuidString` minted by the download engine
(`LiveMediaDownloadManager.swift:523`, `:567`), unrelated to any `saves.id`. So
the `saveId` a plugin sees under `reason: "reresolve"` names no save, and cannot
be correlated with the `saveId` the same plugin saw under `reason: "save"` — a
plugin keying `luna.storage` per save (which the field invites) is broken across
the two calls.

**Fix:** either pass the real save id (the job would have to carry it) or pass
nil and rename the `MediaReresolving` parameter to `jobID`, so the wire field is
honest.

---

## 13. DESIGN — a plugin-owned tracker routes ALTERNATIVE sellers back to that plugin

`LunaLibraries/Sources/LunaStorage/SavesStore.swift:862` calls
`tracker.adoptPluginOwner(pluginID)`, which stamps **every** store that has no
owner (`LunaLibraries/Sources/LunaModels/PriceTracker.swift:421-425`), not just
the canonical one. `PluginPriceFetcher.price(forStoreURL:pluginID:)`
(`PluginPriceFetcher.swift:27-42`) then invokes that plugin's `ingest` for each
such store URL, with **no host check at all** — it never consults
`matchedPlugins(forHost:)` and never verifies the plugin still declares
`product` in `produces`.

So a refresh of an eBay comparison store is sent to, say, an Amazon plugin whose
manifest matches only `amazon.com`. In the good case it declines and the Swift
refresher takes over (a wasted JS invocation per store per refresh); in the bad
case a lax plugin ignores the URL and reports the canonical product's price into
the seller store's price history, which is what the alert threshold and the graph
read.

**Fix:** in `PluginPriceFetcher.price`, return nil unless the plugin matches the
store URL's host and declares `product`; or stamp only the canonical store in
`adoptPluginOwner`.

---

## 14. DESIGN — no page snapshot ever reaches a hook in Safari, and a comment says otherwise

`PluginIngestStage.swift:243-249`:

```swift
/// The page the surface already has, as the hooks see it. […]
/// only the Safari world names itself, and it builds its own snapshot.
```

`content.js` builds none. `classify` is called with `{ url, context: "safari" }`
(line 404) and `ingest` with `{ url, claim, context, reason }` (line 438-440) —
no `page`, ever, and no `saveId`. Doc §3.1's `PageSnapshot` with
`source: "safari"` is unreachable, so a plugin standing on the rendered page has
to declare `page` or refetch what the browser already has.

**Fix:** pass `{ url: location.href, html: document.documentElement.outerHTML,
title: document.title, source: "safari" }`, and correct the stage's comment
either way. (Note the message size ceiling only applies to native messages, and
this snapshot never leaves the content-script world.)

---

## 15. OWNER STANDARD — `PluginModelDrain.opener` is a stored closure seam

`Luna/PluginModelDrain.swift:32-34`

```swift
/// Where a completed drain sends the user back to. A test substitutes a
/// no-op so the suite never actually opens Safari.
static var opener: (URL) async -> Void = { url in _ = await UIApplication.shared.open(url) }
```

CLAUDE.md: "Wiring is protocol contracts, never stored closures … a stored
closure property … is not an acceptable seam." Its own doc comment says its
purpose is test substitution, which is the case the standard names.

**Fix:** a one-method `PluginModelReturnOpening` witness installed from
`KindWiring+Luna`, like `SavesIngestor.unsupportedSavePresenter`.

---

## 16. SIMPLIFICATION — the adopted-outcome → `Outcome` mapping exists twice

`PluginIngestStage.swift:215-238` and `Luna/PluginModelDrain.swift:112-128`
compute the same thing, including the `hasTimeline` video/social split and the
`platform ?? .web` default. The drain's header (lines 109-111) acknowledges the
copy and blames the tier split, but both files import `LunaIngest` (where
`Outcome` lives) and `LunaModels` (where `PluginAdoptedOutcome` lives).

They have already drifted: the stage maps `.failed` to a failed save, the drain
maps it to nil (finding 1).

**Fix:** one `func outcome(from: PluginAdoptedOutcome, productInfo:) -> Outcome?`
in LunaIngest, called by both.

---

## 17. BUG (small) — `plugins.log` serves an unvalidated plugin id

`SafariPluginMessages+Luna.swift:323-327`

```swift
private func pluginLog(message: [String: Any]?) {
    guard let id = message?["id"] as? String, let text = message?["message"] as? String
    else { return }
    DiagnosticLog.shared.record(text, category: "plugin.\(id)")
}
```

Every other branch calls `pluginDeclares` or `enabledPlugin(id:)`; this one takes
the id straight from the message and writes it into the shared diagnostic log's
category. Doc §12.1 states the invariant plainly ("Native re-checks the plugin's
id is installed, enabled…"), and logging needing no *capability* is not the same
as needing no *plugin*.

**Fix:** `guard enabledPlugin(id: id) != nil` before recording.

---

## 18. SIMPLIFICATION — every `plugins.*` message rescans the plugin store from disk

`SafariPluginMessages+Luna.swift:121-131`

```swift
private func enabledPlugins() -> [InstalledPlugin] {
    let installed = PluginStore.shared.installedPlugins()
    let bundledCatalog = BundledPluginCatalog(bundle: bundledPluginsResourceBundle, subdirectory: "Plugins")
    return (bundledCatalog.plugins(shadowedBy: installed) + installed).filter(\.state.isEnabled)
}
```

`pluginDeclares` → `enabledPlugin(id:)` → `enabledPlugins()` on **every** storage
get/set/delete/keys, every collection op, every fetch and every settings read. A
plugin doing twenty storage reads while classifying pays twenty full directory
scans plus twenty manifest re-parses, inside an appex with an ~80 MB ceiling and
a page-blocking message chain (`plugin_host.js:215-222` serialises them).

**Fix:** cache the enabled set on the handler for the life of the extension
process (it is already a `static let`), invalidated by the same descriptor the
catalog stamp is built from.

---

## 19. BUG (small) — malformed requests are reported as permission denials

`SafariPluginMessages+Luna.swift:179-186` (missing/unparseable `url`),
`:244-248` (missing `key`), `:267-272` (missing `docId`) all answer
`["error": "capability-not-declared"]`. A plugin author debugging a typo'd URL is
told their manifest lacks the capability.

The shapes disagree too: on the JSC side a bad `luna.fetch` argument raises a
synchronous JS exception (`PluginFetchBridge.swift:51-57`) rather than rejecting
the promise, so the same mistake is a `throw` in one process and a rejected
promise with a misleading code in the other.

**Fix:** answer `"bad-argument"` for shape failures on both sides and reserve
`capability-not-declared` for the grant check.

---

## 20. DESIGN — the Model caps leave the document fetch and header values unbounded

`LunaLibraries/Sources/LunaModels/Plugin/PluginModel.swift:334-351` caps strings,
URLs, html, asset and seller counts — but a header VALUE has no cap
(`pluginHeaders`, lines 419-428, checks only the name) and `estimatedBytes` has
no bound or sign check (line 109).

The consequence that bites is downstream:
`LunaLibraries/Sources/LunaReaderUI/ArticleModelAdopter.swift:70-85` fetches
`document.url` with `URLSession.shared`, no byte ceiling and no explicit timeout,
then writes the whole body to a temp file. `PluginFetchService` — the path §5.1
says is "the one way plugin code reaches the network" — enforces
`WebFetchConstants.maxBytes`; this second, adopter-owned fetch does not. A plugin
pointing `document.url` at a multi-gigabyte PDF fills the container.

**Fix:** cap the document fetch (a `maxBytes` on a delegate, or a HEAD
pre-check), give header values a length cap, and reject a negative
`estimatedBytes`.

---

## 21. SIMPLIFICATION — the article adopter re-filters headers the decoder already rejected

`ArticleModelAdopter.swift:26-28,71-73`

```swift
static let allowedHeaderNames = PluginModelCaps.allowedHeaderNames
…
for (name, value) in spec.headers where Self.allowedHeaderNames.contains(name.lowercased()) {
```

`ArticleDocumentSpec`'s decoder already **throws** `disallowedHeader` for any
name outside that set (`PluginModel.swift:180` → `:419-428`), on both entry
points into the adopter (`PluginIngestStage.adopt` and
`PluginModelDrain.adopt`, both of which decode `PluginModel` first). The filter
can never drop anything, and the static alias exists for one call site.

**Fix:** iterate `spec.headers` directly and delete the alias and its comment;
the invariant belongs in the decoder, which is where it already is.

---

## 22. DEAD CODE — a stored-but-unread `reason`, and an unused catalog stamp

- `PluginIngestScope.swift:20` stores `(saveID, reason)`; only `currentSaveID` is
  exposed and a repo-wide grep finds no reader of `reason`. The tuple can be a
  `UUID?`.
- `content.js:299` writes `{ stamp: resp.stamp || "", plugins: … }` into the
  cache, and nothing ever compares a stamp. `loadPluginCatalog` (lines 296-310)
  returns the cached value whenever one exists and unconditionally overwrites it
  from the round trip. Doc §12.1's "cached by a stamp hash, refreshed on
  mismatch" describes behaviour that is not in the file — the native side pays
  for building the stamp (`SafariPluginMessages+Luna.swift:147-150`) for nothing.

**Fix:** drop `reason` from the scope tuple; either compare stamps in
`loadPluginCatalog` or stop sending one.

---

## 23. TEST-GAP — the invariant in finding 1 has a test whose name claims it and whose body misses it

`LunaTests/PluginIngestStageTests.swift:98-113`,
`testABrokenPluginDoesNotFailTheSave`, iterates
`[.timedOut, .wedged, .exception, .runtime]` — the `PluginInvocationFailure`
cases only. The adopter answering `.failed` is never exercised anywhere in the
suite (`PluginModelAdopterTests` asserts `.declined` for a priceless product and
an assetless media Model, and `testAnEmptyFragmentFails` at line 120 asserts the
adopter's own `.failed` answer but never runs it through the stage).

**Fix:** add a stage test with a media/article adopter answering `.failed` and
assert `.passed`.

---

## 24. TEST-GAP / value bar — two tests restate production constants

- `LunaTests/MediaReresolveTests.swift:88-95`,
  `testOnlyTheStaleURLStatusesInviteAReresolve`, lists `401/403/410` against
  `statusInvitesReresolve`, whose whole body is
  `status == 401 || status == 403 || status == 410`
  (`LiveMediaDownloadManager+PluginReresolve.swift:47-49`). It is a literal copy
  of the predicate, the "constant echo" shape the Aug-2026 sweep deleted.
- `LunaTests/PluginHTMLParityTests.swift:77-79`,
  `testTheSubsetSpecHasEnoughCasesToBeASpecification`, asserts a case count in
  the spec file rather than any behaviour.

**Fix:** delete the first; fold the second into the parity run (a spec that lost
its cases already fails to prove anything, and the per-case assertions catch it).

---

## 25. TEST-GAP — the resolver port and the whole Safari bridge surface are untested

- `PluginMediaResolver.resolveAssets(for:)` — the `SocialMediaResolving` half
  that every media save in central Luna now goes through — has no test.
  `MediaReresolveTests:113` covers `reresolve` only.
- `LiveMediaDownloadManager.reresolvePluginJob`'s job rewrite (which fields it
  copies, that the resume blob is dropped) is untested; only the pure
  `MediaReresolveMatching.pick` helper is.
- `SafariPluginHostTests` has four tests (register/classify, `Object.keys`,
  `luna.html`, `browser.open`). Nothing covers storage, collections, settings or
  fetch — which is where findings 3, 8 and 9 live. `PluginJSFixtureRunner`
  registers fetch/html/storage/crypto/files/secrets
  (`PluginJSFixtureRunner.swift:66-73`) but **not** `PluginSettingsBridge`, so no
  suite can compare the two settings backings even if one wanted to.

**Fix:** one parity suite that drives the same script through
`PluginJSFixtureRunner` and `SafariJSTestHarness` and asserts the same answers —
the shape `PluginHTMLParityTests` already proves works, extended past `luna.html`
to error codes, storage semantics and settings defaults.

---

### Verified as correct (no finding)

Recorded so a later reader does not re-check them:

- Host matching agrees between `PluginSummary.matches(host:)`
  (`PluginPlatformSeams.swift:79-92`) and `content.js:313-325`, including the
  `*.` suffix rule.
- Walk ORDER agrees: `PluginRuntime.sortLoaded:306-316` (any-host last, priority
  descending, then id) and `content.js:329-345`.
- `PluginModel`'s URL rule is sound: the decoder refuses any absolute non-http(s)
  scheme (`PluginModel.swift:408-417`), and `pluginAbsoluteURL`
  (`PluginModelResolution.swift:33-37`) can only resolve against an http(s) base,
  so resolution cannot introduce a `javascript:`/`file:` URL.
- The media adopter carries headers, quality, expiry and pluginID intact into
  `MediaAsset` (`MediaModelAdopter.swift:39-52`), and the stage's `identified`
  rebuild (`PluginIngestStage.swift:189-194`) passes every `MediaModel` field.
- The pending-model drain cannot double-save: `takeAll` deletes in the same
  sidecar call (`PendingPluginModelStore.swift:76-80`).
