# Review R1 — LunaPluginKit + LunaPluginRuntime

Read-only review at `main` (aff524cc6). Reference: `claudedocs/plugins.md` §1–6, §10, §14.
Every claim below was checked against the code path named. The three known items
(single `invocationID`/`activeCall`, nothing calls `PluginScratchStore.reap`, no
`FileHandle` in a multipart part) are not repeated except where a finding adds detail.

Ranked most severe first.

---

## 1. BUG — plugin JavaScript is evaluated OFF the execution queue, on the main thread

`LunaLibraries/Sources/LunaPluginRuntime/PluginRuntime.swift:221-274` (`load`),
reached from `LunaLibraries/Sources/LunaPluginIngest/PluginPlatformComposition.swift:84`
(`@MainActor`), `LunaLibraries/Sources/LunaPluginRuntime/PluginCatalog.swift:49,66`
(Settings toggle / delete) and `LunaLibraries/Sources/LunaPluginKit/PluginImporter.swift:70`
(after an import).

`load` calls `context.evaluate(source:)` (`PluginContext.swift:98`), `seal()` (:107),
`grantedNamespaces` (:119) and `strayNamespaces` (:127) **directly on the calling
thread**. Every one of those runs JavaScript. `PluginExecutionQueue`'s own header says
"Runs plugin JavaScript on one dedicated serial queue", `PluginRuntime.swift:106-110`
says "The queue is what serializes entry into a virtual machine", and
`PluginContext.swift:18-19` says "Calls arrive on the runtime's serial queue. This type
does no locking of its own." The load path violates all three.

Three concrete consequences:

- **Main-thread hang.** Contexts share one `JSVirtualMachine`; JSC serialises entry with
  the VM's own lock. A plugin whose `classify` is spinning (the exact case
  `PluginRuntimeTests.testAPluginThatBlocksItsQueueWedgesTheRuntime` builds) holds that
  lock on the plugin queue. Toggling any plugin in Settings then calls `reload` →
  `JSContext(virtualMachine:)` → blocks the main thread until the runaway returns —
  forever for a real `while (true)`. `settle` guards this with
  `guard !executionQueue.isWedged` (`PluginRuntime.swift:405`); `load` has no such guard.
- **Launch cost.** `loadAll()` at composition evaluates every bundled plugin's top level
  on the main thread before the first frame.
- **Data race.** `PluginContext.pendingException` (`PluginContext.swift:33`, written by
  the exception handler at :51-55) is now written from the plugin queue during a call and
  read/written from the main thread during a load, with no lock, in a type documented as
  needing none.

**Fix:** route `evaluate`/`seal`/`grantedNamespaces`/`strayNamespaces` through
`executionQueue` (a `sync` hop is fine — the caller already blocks), and give the load
path the same `isWedged` guard `settle` has so a wedged VM refuses the load instead of
hanging the caller.

---

## 2. BUG — `PluginFetchService` keys in-flight transfers by `taskIdentifier` alone, across three sessions

`LunaLibraries/Sources/LunaPluginKit/PluginFetchService.swift:152` (`sessions`),
`:249` (`transfers[task.taskIdentifier] = …`), `:280`, `:286`.

`sessions` holds up to three distinct `URLSession`s (`.shared`, `.ephemeral`, `.none` —
`:254-275`), and `URLSessionTask.taskIdentifier` is documented as unique **within a
session**, not process-wide. Two concurrent plugin fetches with different `cookies`
policies will both be task 1.

Effects, all silent: the second `start` overwrites the first's `Transfer`, so the first
request's completion never fires — `PluginPromiseBox` never settles, the plugin's
`await luna.fetch(…)` hangs, and the hook is eventually abandoned as a timeout (and
collects a strike, `PluginRuntime.noteTimeout:464`). Meanwhile `didReceive data`
(`:340-361`) appends the first transfer's bytes onto the second transfer's body.
`Promise.all([luna.fetch({url, cookies:"shared"}), luna.fetch({url, cookies:"none"})])`
is enough to reach it, and so is one plugin fetching while another runs.

**Fix:** key `transfers` by `ObjectIdentifier(task)` (or a `(session, identifier)` pair)
instead of the raw identifier.

---

## 3. BUG — abandoning a queued-but-never-STARTED item marks the whole runtime wedged

`LunaLibraries/Sources/LunaPluginRuntime/PluginRuntime.swift:443`
(`if !item.hasReturned { executionQueue.abandon(item) }`), with
`PluginExecutionQueue.swift:51-67` and `PluginQueueItem` (:72-101).

`PluginQueueItem` tracks `returned` and `abandoned`; it has no `started`. `abandon`
therefore cannot tell "the body is still running" from "the body has not been dequeued
yet", and counts a wedge either way (`abandonedItems += 1`, `:65`). Once counted, EVERY
later call on that runtime fails `.wedged` at `PluginRuntime.swift:405` until the queued
item finally runs and returns — including calls to unrelated, healthy plugins.

This is reachable whenever a synchronous plugin body holds the shared serial queue longer
than another call's budget: the export hook's 120 s budget and a concurrent media
reresolve's 8 s classify are on ONE queue (`sharedExecutionQueue`, `:111`), shared by
every runtime in the process. `PluginRuntimeTests.testAHookThatNeverSettlesIsAbandonedAtItsBudget:380`
asserts the opposite case (`isWedged == false` when the body DID return); nothing covers
this one.

**Fix:** add a `started` flag set at the top of the queued closure; on abandon of an
unstarted item, mark it cancelled (the closure returns immediately) rather than counting
a wedge.

---

## 4. BUG — a hook's wall-clock budget starts at ENQUEUE, not at the first JS instruction

`LunaLibraries/Sources/LunaPluginRuntime/PluginRuntime.swift:426-431`: the item is
enqueued at :426 and `let deadline = Date().addingTimeInterval(timeout)` is taken at :431,
before the serial queue has necessarily dequeued it.

A hook that never runs can therefore report `.timedOut` (`:449`), and `noteTimeout`
(:464) charges it a strike; three of those disable a plugin that executed nothing
(`disabledReasons[pluginID] = .stopped`, `:469`). Doc §6's budget table describes these
as execution budgets ("8 s wall", "abandoned; plugin passes for this URL"), not queue-wait
budgets. Together with finding 3, one slow plugin can both wedge the process and stop its
neighbours.

**Fix:** start the deadline from the `started` flag of finding 3 (i.e. begin the clock
inside the queued closure) rather than at enqueue.

---

## 5. BUG — a failed `as: "file"` write is reported to the plugin as a SUCCESS with no file

`LunaLibraries/Sources/LunaPluginKit/PluginFetchService.swift:393`
(`file = try? writer.writeFile(…)`), with
`LunaLibraries/Sources/LunaPluginRuntime/Bridges/PluginFetchBridge.swift:223-229`
(`case .file: if let file = response.file { object["file"] = … }`).

The write can throw for the ordinary reasons (no disk space, the App-Group container
unavailable, a directory create failure in `PluginScratchStore.writeFile:75`). `try?`
discards it, the response is fulfilled with `ok: true`, and the `file` key is simply
absent. A plugin sees a 200 with `response.file === undefined` and no error to branch on
— a silent fallback that hides the failure, unlike the sibling path at `:388-391` which
correctly rejects with `unavailable-here` when there is no writer at all.

**Fix:** `do/catch` the write and complete with
`PluginFetchError(…, code: "write-failed")`.

---

## 6. DESIGN — `cookies: "browser"` is unreachable in every shipping process, and its comment says otherwise

`LunaLibraries/Sources/LunaPluginKit/PluginFetchService.swift:141`:
`/// Serves cookies: "browser". Installed by the app; nil everywhere else.`

Nothing in the product installs it. A repo-wide grep for `browserCookies` /
`PluginBrowserCookieProviding` outside the declaring file hits only
`LunaTests/PluginFetchTests.swift:329,345,350` (a stub). So in the app, the share/action
extensions and Safari alike, `cookies: "browser"` always rejects `unavailable-here`
(`:210-213`) — while `claudedocs/plugins.md` §5.1 lists it as one of four working policies
that "match the plan's FetchRequest shapes exactly", and only §14 (which does not mention
it) is where a gap would be recorded. The lock flow's payoff — fetching with the session
the browser modal earned — does not exist.

A latent hazard rides with it: `resolveBrowserCookies` (`:203-227`) flattens the cookies
into a literal `Cookie` header and then re-issues with `redirect: request.redirect`. With
`.follow`, `willPerformHTTPRedirection` (:313-330) passes `newRequest` through unchanged,
so URLSession carries that header to whatever host the redirect names. A plugin that never
sees the cookie value could exfiltrate it through an open redirect on the trusted host.

**Fix:** either install the witness and strip the synthesized `Cookie` header on any
cross-host redirect, or delete the policy and say so in §14.

---

## 7. BUG (contract) — `luna.fetch` THROWS synchronously on a malformed request instead of rejecting

`LunaLibraries/Sources/LunaPluginRuntime/Bridges/PluginFetchBridge.swift:51-57`:
`PluginBridgeValue.raise(…)` sets `context.exception` and the block returns `nil`.

`luna.fetch` is documented (§5.1, and the whole bridge's header comment at :12-17) as
answering a Promise; every other failure of the same call — a refused network
(`network-refused`), a transport error, `unavailable-here` — arrives as a rejected
`LunaError` with a `code`. A missing/unparseable `url` alone escapes as a synchronous JS
throw, so `luna.fetch(req).catch(e => …)` never sees it and an author must wrap the call
in `try` as well. The same asymmetry exists in `PluginStorageBridge.swift:108` and
`PluginHTMLBridge.swift:183,188`, but those two are synchronous APIs where a throw is the
right answer.

**Fix:** in the fetch bridge, build the promise first and `box.fail(…, code:
"bad-argument")`, as `PluginFilesBridge.write:50` already does.

---

## 8. BUG — `PluginStore.install` deletes the installed versions BEFORE the new one lands

`LunaLibraries/Sources/LunaPluginKit/PluginStore.swift:176-189`.

Order is: write the new file into a `.installing-<uuid>` scratch dir (:177-179), create the
id folder (:180), **remove every existing version** (:181-184), then
`moveItem(scratch → destination)` (:185). If that move throws — a full disk, a container
that went away mid-operation — the catch removes the scratch dir and rethrows, and the
plugin now has NO version installed at all. The method's own doc comment at :164-167 claims
"The replace happens through a scratch folder, so a failed write cannot leave the plugin
half-installed."

`PluginStoreTests` covers replacement (`:72`, `:80`) but no failing-move case.

**Fix:** move the new version into place first, then remove the stale version
directories; on a move failure nothing has been destroyed.

---

## 9. DEAD — `PluginRuntime.exceptionReporter` is a public seam nothing ever sets

`LunaLibraries/Sources/LunaPluginRuntime/PluginRuntime.swift:103`, read only at `:477`.
A repo-wide grep finds no assignment in `LunaLibraries`, `Luna/`, the extensions or
`LunaTests`. Its doc comment ("Receives every failure … Held strongly — a reporter is a
launch seam") describes a wiring that does not exist. Per CLAUDE.md ("A production seam
may exist ONLY while a behavior-asserting test uses it"), it should go — every failure
already reaches `diagnostics.record` on the line above.

**Fix:** delete the property and the `exceptionReporter?.pluginDidFail` call, or wire it
from a composition root with a test.

---

## 10. DEAD — `PluginVirtualMachineScope.isolated`, whose comment contradicts the fixture runner's

`LunaLibraries/Sources/LunaPluginRuntime/PluginRuntime.swift:16-18` says of `.isolated`:
"A caller that must not be wedged by another runtime's plugins uses it; **the fixture
runner does**." It does not: `LunaTests/PluginJSFixtureRunner.swift:47` defaults to
`.processWide`, no call site passes anything else, and the runner's own comment (:22-30)
explains at length why an isolated machine per fixture kills the test host. So the case,
its second `PluginExecutionQueue` (:151) and the second `JSVirtualMachine` (:150) are
unreachable, and the comment is actively misleading.

**Fix:** delete the enum and the `scope` parameter, or fix the comment to say nothing
selects it.

---

## 11. DEAD + wrong comment — `PluginKVStore.settingsKeyPrefix` and the type's header

`LunaLibraries/Sources/LunaPluginKit/PluginKVStore.swift:39`
(`public static let settingsKeyPrefix = "settings."`) has exactly one occurrence in the
whole repo: its own declaration.

Worse, the type's header at `:30-31` states "Plugin SETTINGS live in the same table under
`settings.<key>`" — the precise bug `claudedocs/plugins.md` §5.4 and §15.3 record as
already fixed, and which `isConfigured`'s own comment 200 lines below (`:234-236`)
contradicts. A reader who trusts the header will reintroduce the prefix.

**Fix:** delete the constant and rewrite the header sentence to say a settings value is a
row under the field's own bare key.

---

## 12. DEAD — `PluginContext.installedCapabilities` and `isRegistered`

`LunaLibraries/Sources/LunaPluginRuntime/PluginContext.swift:27` (written at :89, never
read) and `:136` (`isRegistered`, no caller — `registrationFailure` at :138 is what
`load` uses). The doc comment at :115-118 even describes `installedCapabilities` as one
half of the grant comparison, but `PluginRuntime.load:252-255` compares
`grantedNamespaces` against `manifest.capabilities`, never against this property.

**Fix:** delete both; adjust the `grantedNamespaces` comment to name what is actually
compared.

---

## 13. SIMPLIFICATION — a ternary whose two branches are identical

`LunaLibraries/Sources/LunaPluginRuntime/PluginContext.swift:321-323`:

```swift
var line = message?.isString == true
    ? (message?.toString() ?? "")
    : (message?.toString() ?? "")
```

Both arms are the same expression, so the `isString` test does nothing.

**Fix:** `var line = message?.toString() ?? ""`.

---

## 14. SIMPLIFICATION — `PluginCatalog.delete` unloads twice

`LunaLibraries/Sources/LunaPluginRuntime/PluginCatalog.swift:63-66` calls
`runtime.unload(pluginID:)` and then `runtime.reload(pluginID:)`; `reload`
(`PluginRuntime.swift:189-190`) begins with `unload(pluginID:)`. The first call is
redundant, and it makes the sequence read as if reload needed a pre-clean.

**Fix:** drop the explicit `unload`.

---

## 15. BUG (latent) — `PluginHTMLNodeHandle.value` mints a whole new `JSVirtualMachine` as a fallback

`LunaLibraries/Sources/LunaPluginRuntime/Bridges/PluginHTMLBridge.swift:157-161`:
`let context = JSContext.current() ?? JSContext()!`. `JSContext()` with no argument
creates a **new virtual machine** as well as a new context. If it were ever taken, the
returned `JSValue` belongs to a foreign VM — passing it back to the plugin's context is
undefined behaviour — and the VM leaks for the life of the process. The runner's own
comment (`PluginJSFixtureRunner.swift:22-30`) records that accumulating VMs faults inside
JSC's heap.

Reachable only if a `JSExport` member is read outside a JS call; the correct fallback is
the node's owning context.

**Fix:** capture the installing context (as every other bridge does with `outerContext`)
and use it as the fallback, or return `JSValue(nullIn:)` for the impossible case.

---

## 16. DESIGN — `PluginCapabilityRegistry` is an unsynchronised mutable dictionary read across threads

`LunaLibraries/Sources/LunaPluginRuntime/PluginCapabilityRegistry.swift:72-86`. `register`
mutates `installers`; `installer(for:)` is read from `PluginContext.init:82` and
`PluginRuntime.load:270`. With finding 1 those reads happen on the main thread while a
hook may be running on the plugin queue, and `PluginPlatformComposition.install` is
documented as re-runnable ("Idempotent: calling it twice replaces the same witnesses"),
so a second install can register while an earlier runtime loads.

**Fix:** either guard with the same `NSLock` pattern the rest of the tier uses, or freeze
the table into a `let` dictionary handed to the runtime at construction.

---

## 17. BUG-lite — `luna.files.read` with no `form` silently corrupts binary content

`LunaLibraries/Sources/LunaPluginRuntime/Bridges/PluginFilesBridge.swift:92`:
`box.fulfill(String(decoding: data, as: UTF8.self))`. Invalid UTF-8 becomes U+FFFD, so a
plugin that reads a downloaded MP4 or EPUB without `"base64"` gets a plausible-looking
string with silently mangled bytes and no error. `xteink.js`'s documented workaround
(§5.1) is exactly this call, and a caller who forgets the second argument gets corruption
rather than a refusal.

**Fix:** refuse a non-UTF-8 read with `code: "not-text"` (`String(data:encoding:.utf8)`
returning nil is the test), pointing the author at `"base64"`.

---

## 18. VALIDATION — manifest flags are checked three different ways

`LunaLibraries/Sources/LunaPluginKit/PluginManifestParser.swift`. `background`
(:140 → `flag`, :501-510), `match.any` (:226) and `priority` (:262) all reject a
non-boolean/non-integer with a named error. But `export.destination` (:362,
`as? NSNumber` — `"destination": 1` passes as true), `settings[].required` and
`settings[].secret` (:441-442, same), and `inputOptions.epub.images` (:349 — a non-boolean
is silently ignored and the default kept) do not. `settings[].default` (:432-435) uses
`try?` and silently drops a value it cannot encode.

Doc §2.2 presents all of these as validated fields. The inconsistency means a typo in a
manifest is a hard import error in three places and a silent wrong default in four.

**Fix:** route every boolean through the existing `flag` helper and error on an
unencodable `default`.

---

## 19. VALIDATION — `settings[].key` accepts any Unicode letter or digit, not `[A-Za-z0-9_]`

`LunaLibraries/Sources/LunaPluginKit/PluginManifestParser.swift:382`:
`key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })`. `Character.isLetter` and
`.isNumber` are Unicode-wide, so `"ключ"`, `"clé"` and `"½"` all parse. `claudedocs/plugins.md`
§2.2 documents the rule as `[A-Za-z0-9_]`, and the key becomes a `plugin_kv` primary-key
component and a `luna.settings.get(key)` argument that must match byte-for-byte across the
JS side, the Settings screen and the Safari relay — Unicode normalisation differences are
a real way to lose a value.

**Fix:** test against an explicit ASCII set, as `PluginManifestParser.idCharacters:20`
already does for the id.

---

## 20. VALIDATION — a `match.hosts` entry of `"*"` parses and then matches nothing

`PluginManifestParser.match` (`:240-249`) accepts any non-empty string without `/`, so
`"hosts": ["*"]` satisfies the "list the hosts or set any:true" guard at :251.
`PluginSummary.matches(host:)`
(`LunaLibraries/Sources/LunaPluginKit/PluginPlatformSeams.swift:79-92`) then tests
`p.hasPrefix("*.")` (false) and `lower == "*"` (never true for a real host), so the plugin
is silently never asked. That is the most likely spelling an author reaches for before
finding `any: true`, and there is no error and no diagnostic line to explain it.

**Fix:** refuse a host pattern containing `*` anywhere other than a leading `*.`, and say
"use `\"any\": true`" in the detail.

Related, lower severity: `PluginFetchRequestDecoder.encodeMultipart`
(`Bridges/PluginFetchBridge.swift:175-199`) interpolates `name`, `filename` and `mime`
into part headers with no quote/CRLF escaping, so a part name can forge additional
headers or parts. It is not an escalation — the plugin can already send arbitrary bytes
via `{base64}` — but it makes a malformed upload look like a server bug.

---

## 21. VALIDATION — `export.requiresSettings` is never checked against the declared settings

`LunaLibraries/Sources/LunaPluginKit/PluginManifestParser.swift:353-361` accepts any list
of strings. A key that no `settings[]` field declares can never be satisfied, so
`PluginKVStore.isConfigured`-style gating on the export row is permanently unmet, with no
import-time error — the same class of mistake the parser catches eagerly for
`export.input`/`kinds` (:322-331).

**Fix:** require every `requiresSettings` entry to name a declared settings key.

---

## 22. LEAK — `PluginFetchService` never invalidates its sessions

`LunaLibraries/Sources/LunaPluginKit/PluginFetchService.swift:271-273` builds each
`URLSession` with `delegate: self`. `URLSession` retains its delegate strongly until
`invalidateAndCancel()`/`finishTasksAndInvalidate()`, and the service holds the sessions in
`sessions` (:152) — a permanent cycle. `PluginPlatformComposition.install` is documented
idempotent and creates a fresh `PluginFetchService()` (`:60`) each time, so every re-install
strands the previous service, its up-to-three sessions and their delegate queue for the
life of the process.

**Fix:** hold the sessions weakly through a delegate proxy, or invalidate them in `deinit`
and on replacement.

---

## 23. LEAK — an unsettled `PluginPromiseBox` pins the plugin's `JSContext`

`LunaLibraries/Sources/LunaPluginRuntime/PluginBridgeSupport.swift:120-137`: the box holds
the promise's `resolve`/`reject` `JSValue`s until `settle` nils them (:152-154). A bridge
whose completion never fires — which finding 2 produces on every task-id collision — keeps
both values, and therefore the plugin's whole `JSContext`, alive forever. There is no
timeout or cancellation path on the box.

**Fix:** have the runtime hand the box the current invocation and drop the values when
that invocation is abandoned (this also gives finding 2 a safety net).

---

## 24. TEST-GAP — no plugin test anywhere exercises two overlapping hook calls

`grep -n "async let\|withTaskGroup\|Task.detached\|concurrent" LunaTests/Plugin*.swift`
returns nothing. Every suite drives one call at a time, awaited to completion. That is
precisely the shape of the known `invocationID`/`activeCall` clobber, of finding 2's
task-id collision, and of finding 3's spurious wedge — none of which a serial test can
show. The wedge test (`PluginRuntimeTests:435-462`) is the closest, and it still issues
its two calls sequentially.

**Fix:** add one suite that runs two hooks concurrently (`async let` over two plugins on
one runtime, and a hook that calls `luna.fetch` twice through `Promise.all`), asserting
both settle with their own answers, that files land in the right invocation, and that no
wedge is reported.

---

## 25. TEST-VALUE — `testTheSubsetSpecHasEnoughCasesToBeASpecification` asserts nothing about behaviour

`LunaTests/PluginHTMLSubsetTests.swift:109-111`:
`XCTAssertGreaterThanOrEqual(specCases().count, 40)`. It restates a property of a fixture
file, not of production code, and the threshold has already drifted from the documented
60 (`claudedocs/plugins.md` §5.2). The suite's real pin is the next method
(`testEverySpecCaseAgreesWithTheSwiftSoupBacking`), which already asserts
`XCTAssertFalse(cases.isEmpty)`.

**Fix:** delete it, per CLAUDE.md's test-value bar.
