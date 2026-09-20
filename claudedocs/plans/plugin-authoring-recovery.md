# Plugin authoring recovery — review findings and implementation plan

## Status

SUPERSEDED by `claudedocs/plans/ai-flows.md` (2026-09-20): the copy/paste
workshop this plan built is deleted, and a plugin now arrives as a Luna file
the user taps.

COMPLETE FOR THE PLUGIN SCOPE (2026-09-04). This plan reviews the
plugin-platform commits from `5003896e3` (Wave 0) through `f6936331a` and adds
the missing nontechnical authoring loop:

```
failed or supplied URL
    -> bounded, sanitized evidence of what Luna tried
    -> self-contained prompt copied to any free LLM chat
    -> pasted draft plugin
    -> isolated validation against the captured case
    -> install, or copy a deterministic correction prompt and iterate
```

No LLM-provider API is part of the baseline. The product must work with an
ordinary free ChatGPT/Claude/Gemini-style text box and the system clipboard or
share sheet.

## 1. Review findings

### P0 — fix before describing generated plugins as safe or supported

1. **Plugin diagnostics are not attached to their save.**
   `LunaPluginRuntime/PluginDiagnostics.swift` has one global `saveRecorder`
   property and says the ingest stage binds it, but no code assigns it.
   `luna.log`, `luna.fetch` and runtime failures execute on the JavaScript
   queue/callback queues where `SaveDiagnostics.recorder` is absent. The failed
   save export therefore omits the most relevant plugin evidence. Merely
   assigning the global property would mix concurrent saves. Correlation must
   be per invocation and must survive asynchronous bridge callbacks.

2. **Import is neither executable-validation-first nor transactional.**
   `PluginImporter.install` commits the new source, calls `reloadAll`, ignores
   every `PluginLoadReport`, and returns success. Syntax errors, missing
   registration and top-level exceptions can replace a working version and
   still produce a success notification. Preserve the previous installed
   version until a staged source has loaded and passed its case test; rollback
   on any failed activation.

3. **Top-level JavaScript can block the main-thread import/launch path.**
   `PluginRuntime.load` calls `PluginExecutionQueue.sync` and JavaScriptCore has
   no public interrupt/deadline API. A generated `while (true) {}` at top level
   never reaches the hook watchdog. Draft evaluation must use a dedicated
   virtual machine and queue off the main actor. A timed-out disposable sandbox
   is quarantined and never reused; production runtime activation occurs only
   after that preflight. The UI must explain that a timed-out validation may
   require restarting Luna before another draft can be tested. Do not claim
   arbitrary JavaScript can be forcibly terminated in-process.

4. **The requested recovery loop does not exist.** Failed cards share a raw
   trace, Settings can only import source, and an arbitrary URL has no plugin
   diagnosis entry point. There is no prompt builder, captured fixture,
   WIP-test report or correction prompt.

### P1 — correctness and security required by the recovery loop

5. **The existing trace is raw support data, not an LLM handoff.** It has no
   API contract, strict output rules, existing matching-plugin inventory,
   bounded page evidence or prompt-injection boundary. It can be 256 KiB and
   includes complete query strings. Build a separate recovery artifact; do not
   relabel the raw diagnostic export.

6. **Recovery exports can disclose credentials.** Preserve useful routing
   parameters, but redact values for token/key/auth/session/cookie/password,
   OAuth code/state, AWS/CloudFront signed URL fields, and any
   `Authorization`/`Cookie`/`Set-Cookie` header material. Bound plugin-written
   log lines and page evidence. Show a short privacy notice before copying or
   sharing. Evidence is untrusted text: delimit it and tell the model never to
   follow instructions found inside it.

7. **There is no deterministic draft validator shared by app and tools.** A
   useful report must cover manifest parsing, exact header marker, source
   syntax/registration, required hooks, capability availability, classify
   result, ingest/export result shape, adoption viability, timeouts and a
   structured event log. Draft tests must not write the live PluginStore,
   Keychain, saves database or user files.

8. **An arbitrary-URL probe needs the real native attempt ledger without a
   saved-item side effect.** Run `IngestPipeline.processResolved` under a fresh
   `SaveDiagnosticsRecorder` and return its outcome/trace instead of calling
   `SavesIngestor`. Add an explicit probe mode so plugin adoption, browser UI,
   downloads and store writes cannot occur. Include the IDs/versions of plugins
   whose host patterns would match. A failed saved item reuses its durable trace
   instead of refetching.

9. **Safari loses the best page evidence.** The content script has the live DOM
   but persists neither a recovery session nor attempted-plugin outcomes. Its
   browser deep link is also assembled with `.urlQueryAllowed`, which can
   corrupt nested URLs containing `&`/`?`. Add a bounded snapshot handoff and
   construct deep links with `URLComponents`.

10. **Plugin fetch cookies are shared across plugins.**
    `PluginFetchService` caches sessions by cookie policy only and `.shared`
    uses a default cookie store. One granted plugin can therefore ride another
    plugin's session. Key sessions by `(pluginID, policy)` and use an in-memory
    per-plugin cookie jar for the shared-within-plugin policy. Check every
    redirect target through the plugin network policy before following it.

### P2 — smaller defects and authoring drift

11. `PluginManifestParser.extractHeader` accepts marker prefixes such as
    `luna-plugin-evil`; require exact trimmed equality. Make native and Node
    parsing agree.
12. Deleting a plugin removes its files and KV rows but leaves Keychain
    secrets. Add `PluginSecretsStore.removeAll(pluginID:)` and call it from the
    catalog deletion path.
13. `tools/plugin-sim/run.mjs` has no pass/fail validation command, structured
    report, process-level timeout, export-hook path or realistic response
    fixtures. The README openly permits hangs.
14. Authoring documentation is stale: the skill says multipart cannot carry a
    `FileHandle` although it now can; it omits `env.languages`; the simulator
    README says `luna.browser` is absent although it installs an unavailable
    stub; and README `_status` prose is malformed.
15. The import action-sheet anchor may be nil/zero on iPad. Fall back to the
    presenter's view and bounds.
16. Safari page snapshots and `luna.page.html()` are unbounded. Apply the same
    documented byte/character ceiling used by the recovery fixture and expose
    a `truncated` signal.
17. `PluginDatabase` and `SavesDatabase` label SQLite flag `0x0040_0000` as
    `COMPLETEUNTILFIRSTUSERAUTHENTICATION`, but Apple's header defines that
    value as file-protection NONE; the intended constant is `0x0030_0000`.
    Use the SDK constant where importable or correct the value and pin it.
18. Runtime reload is not generation-safe. Old calls can settle after a new
    context with the same plugin id is active; call/promise/timeout/scratch
    bookkeeping keyed only by plugin id can then close or disable the new
    generation. Give each loaded context a generation token and refuse/safely
    drain reload while its predecessor is active.
19. Async bridge work can outlive the hook scratch lease. A timed-out hook
    closes/reaps its generation while a fetch/file callback may still write
    into it. Network/file operations need their own leases or cancellation and
    a generation-validity check before writing.
20. `PluginDownloadsBridge` creates promise boxes without its plugin id. Its
    callbacks touch every plugin call and its promises are not discarded with
    the abandoned owner. Require nonoptional plugin identity for every bridge
    promise/callback.
21. Fetch request decoding silently turns malformed body objects, bad base64
    and bad JSON into an empty body; it accepts non-http schemes, unbounded
    aggregate bodies, and non-finite/nonpositive timeouts. Reject these as
    `bad-argument`, enforce byte limits, and keep Safari/Node parity.
22. Per-value storage limits do not cap aggregate KV/collection/scratch use, so
    a plugin can exhaust the shared App Group disk. Add per-plugin byte/count
    quotas and an explicit `quota-exceeded` error.
23. Plugin storage/database creation, PRAGMAs, schema and state writes swallow
    errors or fall back to temporary storage. Production composition must fail
    closed without the App Group and surface `storage-unavailable` or
    `write-failed`; tests may inject explicit temporary roots.
24. `PluginContext` shallow-freezes only `luna`/`bytes` and asks mutable
    context-global `Object.keys`/`JSON.stringify` to inspect/serialize host
    values. Plugin code can monkey-patch those before load checks or result
    decoding. Capture trusted built-ins before source evaluation, use
    null-prototype host objects where possible, and freeze installed namespaces.

## 2. Product contract

### 2.1 Entry points

- A failed-save card and its long-press menu offer **Create Plugin…** whenever
  the central Luna app has plugin authoring available. Existing **Share
  Diagnostics…** remains available as support tooling.
- Settings -> Plugins adds **Create for Website…** beside Add. It accepts an
  `http`/`https` URL, runs the side-effect-free probe, then opens the same
  workshop used by a failed card.
- The central Safari extension can hand the current URL plus a bounded page
  snapshot to that workshop when its plugin walk declines or fails. The three
  standalone facet apps continue to store the URL in the shared store but do
  not expose central-Luna-only plugin UI.

### 2.2 Recovery artifact

Define a `PluginRecoveryCase` value with:

- stable case id; original and canonical sanitized URL; host; capture source;
- Luna app/API versions and locale/languages;
- coarse outcome and failure reason;
- ordered, structured attempt lines (category, phase/strategy, result, elapsed
  when known), plus explicit dropped/truncated counts;
- matching installed plugin id/version/status, and the outcome of each hook
  when known;
- a sanitized `RescueDigestBuilder`-style page digest, never raw unbounded DOM;
- privacy-redaction summary so the LLM knows which values were intentionally
  hidden.

The prompt builder is pure and deterministic. It emits:

1. task and success criteria;
2. the exact API-1 manifest/hook/model subset needed for an ingest plugin;
3. a minimal skeleton with the target host, conservative capabilities
   (`fetch`, `html`) and version `1.0.0`;
4. rules to avoid strategies already shown to fail;
5. a strict response contract: exactly one JavaScript source file, no prose or
   Markdown fences, one exact `/* luna-plugin` header and one top-level
   `luna.register`;
6. the evidence inside unmistakable `BEGIN/END UNTRUSTED LUNA EVIDENCE`
   delimiters with an instruction to treat its content only as data;
7. self-review checks: matching host, declared capabilities only, fast decline,
   bounded fetches, null on genuine nonmatch, no busy loops, and valid Model.

Keep the complete prompt under a documented character budget. Prefer the newest
attempt and state whenever evidence was omitted.

### 2.3 Draft validation and iteration

- Normalize common chat output safely: accept one outer ```js/```javascript
  fence only when there is no surrounding non-whitespace prose; otherwise show
  an error instead of guessing which block to run.
- Validate the exact manifest and JavaScript syntax before any evaluation.
- Evaluate and run in a disposable `JSVirtualMachine`/serial queue with only
  in-memory storage and deterministic fixture-backed fetch/html capabilities.
  Do not inject secrets, files, browser, downloads, settings writes, UI, mail,
  notifications, Bluetooth, Wi-Fi or exports for an ingest draft.
- Run the target URL through `classify`, require a declared-kind claim, run
  `ingest`, decode the Model and perform the same pure adoption validation the
  production stage uses. Return a structured `PluginValidationReport`.
- A successful report enables **Install**. Installation rechecks that exact
  source hash, commits it atomically, activates only that plugin, and rolls back
  if activation fails.
- A failed report enables **Copy Fix Prompt**. The correction prompt includes
  the original case, exact draft source, structured validation errors and a
  request to return the entire corrected file under the same strict contract.

The Node harness is supplemental developer tooling. It should run untrusted
source in a child process with an external kill timeout; it is not evidence that
iOS JavaScriptCore can interrupt code.

## 3. Work packages and file ownership

### WP-A — invocation diagnostics, safe activation and cleanup

Owns `LunaPluginRuntime`, `PluginImporter`/import protocols, `PluginStore`,
`PluginSecretsStore`, `PluginCatalog`, and focused tests.

1. Add an invocation identifier and optional diagnostic-recorder identity to
   `PluginRuntime.invoke`; bind it while the initial hook and each scheduled
   bridge callback re-enter JavaScript. Replace the unused global recorder with
   a concurrency-safe per-invocation sink. Late callbacks after timeout must go
   only to the global plugin log, not a completed save. Prove two overlapping
   saves do not cross-write.
2. Add source syntax checking and a disposable-runtime preflight contract.
   Never execute draft code on `MainActor`. Quarantine a sandbox whose top
   level times out. Keep production runtime/load behavior explicit about its
   unavoidable non-interruptibility.
3. Stage activation so `install` reports validation/load failure, restores the
   previous version/state, and only notifies the UI after the new context is
   loaded. Do not call `reloadAll` when one plugin changed.
4. Require exact `luna-plugin` marker text.
5. Delete all per-plugin Keychain secrets when an imported plugin is deleted.
6. Add tests: correlated sync/async logs, overlap, late callback, syntax error,
   top-level exception, missing register/hook, failed update rollback, exact
   marker, and secret cleanup.

### WP-B — recovery case, sanitization, prompt builder and native probe

Owns new Foundation types in `LunaPluginKit`/`LunaPluginIngest`, the explicit
probe parameter in `IngestPipeline`, and focused tests. It does not edit UIKit.

1. Implement `PluginRecoveryCase`, bounded attempt/page evidence and stable
   JSON/text serialization.
2. Implement contextual redaction without destroying ordinary route/query
   structure; test bearer tokens, cookies, signed URLs, percent encoding,
   multiline injection and truncation.
3. Implement deterministic initial and correction prompt builders with the
   contract in section 2.2. Unit tests assert required sections, exact fences,
   character budget and absence of secrets.
4. Implement a side-effect-free native URL probe that binds a recorder, runs
   the real classifier/fetch/bypass paths, reports matched plugins separately,
   and cannot adopt plugin Models, present browser UI, persist saves or start
   downloads.
5. Reuse `RescueDigestBuilder`; do not invent a second HTML summarizer.

### WP-C — process-bounded developer harness and doc parity

Owns `tools/plugin-sim`, author docs/skill and its Node tests/fixtures.

1. Add `validate` and `test` commands with JSON output and nonzero exit status.
   A parent process launches the evaluator child and kills it at the deadline.
2. Support classify/ingest and export test inputs. Fixture metadata can express
   status, headers, final URL/redirect, body and transport error. Enforce native
   source/body/storage limits where the harness claims parity.
3. Use the exact header marker and share validation error codes/shapes with the
   app contract where feasible.
4. Correct multipart `file`, `env.languages`, `_status`, browser-stub and hang
   documentation. Document the clipboard workshop and correction loop.

### WP-D — workshop UI and failed-card/manual-URL integration

Starts after WP-A and WP-B merge. Owns `LunaPluginUI`,
`PluginsSettingsCategory`, `FailedSaveCardFactory`, `FailedSaveCardActions`,
localized strings, staging screens and UI tests.

1. Build one workshop screen/state machine: URL/evidence -> Copy/Share Prompt ->
   paste draft -> Validate -> Install or Copy Fix Prompt. Preserve text and
   report across backgrounding and failed validation.
2. Wire failed saves to their stored trace and Settings to the native URL probe.
   Copy uses `UIPasteboard`; share writes a real `.txt` file and uses an
   iPad-safe popover anchor. Present the privacy notice before either action.
3. Keep the raw diagnostic export as a separately named support action.
4. Normalize a single code fence and show actionable line/field errors.
5. Fix the import coordinator's fallback popover anchor.
6. Add behavior tests for entry points, state transitions, copy/share, invalid
   URLs, no-trace cases, validation failure, correction prompt and successful
   transactional install. Add Stage variants for each meaningful state.

### WP-E — Safari recovery handoff and bounded snapshots

Starts after WP-B. Owns central `LunaSafari` plugin messages/resources, deep-link
handling, recovery-session persistence and Safari tests.

1. Cap the snapshot once and carry `{html/digest, truncated}` consistently to
   `page` hooks and the recovery case.
2. Persist a bounded recovery handoff containing current URL, page digest and
   ordered plugin outcomes when the walk exhausts.
3. Build every nested deep link with `URLComponents`; test URLs containing
   `?`, `&`, `+`, fragments and Unicode.
4. Open the central Luna workshop for the handoff. If the app is unavailable,
   keep ordinary save behavior intact.

### WP-F — cookie isolation and redirect policy

May run beside WP-D/E after WP-A. Owns `PluginFetchService` and fetch tests/docs.

1. Key sessions by plugin id and cookie policy. A plugin's default cookie jar
   is reusable by that plugin for the process but invisible to other plugins.
2. Recheck every redirect URL before following it. Preserve manual redirect
   semantics and return a stable `network-refused` error for a denied target.
3. Add tests proving no cross-plugin cookie flow and no redirect-policy bypass.

Also make request shaping strict: only `http`/`https`, finite positive bounded
timeouts, valid JSON/base64/multipart shapes and an aggregate body limit. Keep
native, Safari and Node error codes aligned.

### WP-G — database protection, quotas and fail-closed persistence

Starts after WP-A. Owns plugin database/KV/scratch persistence and the matching
`SavesDatabase` flag correction.

1. Correct the SQLite file-protection flag to the SDK's
   `COMPLETEUNTILFIRSTUSERAUTHENTICATION` value and add a regression pin.
2. Make production initialization and state writes report failures instead of
   silently using temporary storage or interpreting errors as missing values.
3. Add transactional per-plugin aggregate quotas for KV keys/bytes, collection
   rows/bytes and scratch bytes/files. Return `quota-exceeded` consistently and
   document the numbers.
4. Test read-only/unavailable roots, schema/PRAGMA failure and fill-to-quota
   boundaries without allocating unbounded test data.

### WP-H — runtime generations, async leases and host hardening

Starts after the diagnostic-correlation core of WP-A. Owns remaining runtime
lifecycle and `PluginContext` hardening.

1. Key in-flight calls, promises, timeout strikes and scratch ownership by a
   loaded-context generation, not only plugin id. Define reload behavior while
   calls are live and test old completions arriving after replacement.
2. Give asynchronous fetch/file/download bridge work a cancellable operation
   lease. A hook ending does not reap its scratch while a valid operation owns
   it; an abandoned generation cannot recreate files later.
3. Pass a nonoptional plugin/generation identity through every bridge promise,
   including `luna.downloads`; remove the touch-every-plugin fallback.
4. Capture trusted serialization/introspection functions before evaluating
   source and deep-freeze host namespaces. Add prototype/serializer tampering
   tests.

## 4. Merge and verification order

1. Commit this plan on the integration branch.
2. Run WP-A, WP-B and WP-C in parallel in worktrees based on the plan commit.
3. Merge A -> B -> C; resolve shared protocol/doc conflicts centrally.
4. Run WP-D, WP-E, WP-F, WP-G and WP-H against the merged branch in
   file-disjoint waves; merge persistence/runtime foundations before UI.
5. Run `npm ci && npm run spec` plus the new simulator tests.
6. Run targeted Xcode tests for every new class, then
   `xcodebuild build-for-testing -scheme Luna -destination
   'generic/platform=iOS Simulator'`.
7. Run the full `LunaTests` suite on an iOS 26.2 simulator. The expected result
   before this work is 904 tests, 2 intentional skips, 0 failures; document any
   intentional count change.
8. Update `claudedocs/plugins.md`, `claudedocs/save-diagnostics.md`,
   `docs/plugins/README.md`, `docs/plugins/api.md`, the author skill and
   `tools/plugin-sim/luna-plugin.d.ts` so every shipped contract agrees.
9. Mark this status COMPLETE only after all packages are merged and verified,
   then merge the integration branch into `main` and delete every task worktree
   and branch.

## 5. Implementation outcome and verification

All eight work packages were implemented and merged into the integration
history:

- WP-A now correlates diagnostics per invocation across asynchronous bridge
  callbacks, preflights source in a disposable off-main runtime, activates an
  install transactionally with rollback, requires the exact header marker and
  removes a deleted plugin's Keychain secrets.
- WP-B adds a bounded `PluginRecoveryCase`, contextual credential redaction,
  deterministic initial/correction prompts and a native probe that exercises
  Luna's real attempt ledger without saving or adopting content.
- WP-C adds child-process `validate`/`test` commands with an external kill
  deadline, structured reports and native-compatible fixtures and limits.
- WP-D adds the copy/paste workshop from both failed saves and an arbitrary URL:
  Copy/Share Prompt -> paste draft -> Validate -> Install or Copy Fix Prompt.
  It intentionally has no LLM API dependency, so free provider web apps remain
  the baseline path.
- WP-E bounds Safari page input, sends a sanitized structural digest and
  ordered plugin outcomes only after an explicit failed Save attempt, stores
  the large handoff in the App Group and opens the workshop by a short case id.
- WP-F isolates cookies per plugin, rechecks redirect destinations and applies
  strict request/body shaping across native and Safari paths.
- WP-G corrects SQLite protection flags, fails closed on persistence errors and
  enforces transactional per-plugin KV, collection and scratch quotas.
- WP-H keys runtime state by loaded-context generation, retains asynchronous
  work with cancellable leases, prevents a retired generation from recreating
  scratch files, and protects host builtins/namespaces from plugin tampering.

Verification performed on Xcode 26.2 with the iOS 26.2 simulator:

- `tools/plugin-sim`: `npm test` passed; `npm run spec` passed 60/60.
- Post-sync Safari source/fixture/bridge-parity selection: 45/45 passed.
- Post-sync export-input, mail, Kindle and Xteink selection: 52/52 passed after
  their direct scratch-store fixtures were updated to open the explicit
  generations required by the hardened runtime.
- Earlier focused persistence, runtime-generation, validator/fetch and handoff
  groups also passed. `build-for-testing` succeeded.
- The full current tree executed 4,814 tests with 24 skips. It exposed the
  explicit-generation fixture drift fixed above, plus eight deterministic,
  non-plugin baseline test failures introduced by other work merged into
  `main` during this review: `ArticleCardsChromeTests`,
  `ArticleCoverThumbnailTests`, `CardPlaybackSpeedTests`,
  `LinkImportPreviewLoaderTests`, `ProductHistoryPillRenderTests`,
  `ScrollDirectionImmersionTrackerTests`, `UtilCardTests` and
  `WeeklySaveTests`. Each of those eight still fails when run alone; none
  exercises the plugin loader or recovery loop. They are recorded here rather
  than being silently folded into this plugin change.

The full-suite run was made from `/tmp` because iOS Simulator test processes
cannot read source fixtures from the macOS-protected Desktop folder. This is a
test-location constraint, not an app behavior change.

After that verification, `main` advanced again with Writer portability commit
`bde0a3881`. The required final sync currently prevents a fresh build because
`LunaGaze/ReadingTracker.swift` cannot resolve the newly moved
`SentenceLayout` type and the target reports a missing `LunaWriterModels`
dependency. That blocker is present in the synced `main` work itself and does
not touch the plugin platform; the last post-plugin/pre-Writer-sync focused
result remains the 97/97 tests above.

## 6. Definition of done

- A nontechnical user can start with either a failed save or an arbitrary URL,
  copy one prompt into a free LLM chat, paste its reply back, and reach a clear
  pass/fail result without reading developer docs.
- Failure evidence says what Luna and matching plugins already tried, is
  bounded, is invocation-correct under concurrency, and does not contain known
  credential material.
- A draft cannot replace a working plugin until validation and explicit consent
  succeed. A failed activation restores the prior version.
- A bad or nonterminating draft does not block the main actor or production
  plugin runtime. The unavoidable JavaScriptCore limitation is stated honestly.
- A failed draft yields a correction prompt sufficient for a blind copy/paste
  iteration; no paid API or in-app LLM account is required.
- App, Safari and Node contracts agree, all plugin-scope verification is green,
  and failures elsewhere in the concurrently advanced full suite are explicitly
  identified above rather than attributed to this work.
