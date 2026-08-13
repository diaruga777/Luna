# Plan: raise the URL-rescue success rate (Plan B)

Goal: the Apple Intelligence recovery path (`LunaURLRescue`) actually recovers
failed saves. Observed today: failed saves essentially always stay failed.
This plan gives the model real evidence about what failed, widens what it can
do about it, stops attempts being burned on predictable failures, and adds
measurement so success is visible at all.

Companion: `save-diagnostics-plan.md` (Plan A) is being implemented in
parallel; its per-save trace file is the evidence source here. The shared seam
is already on `main`: `LunaStorage/SaveDiagnosticsStore.swift`
(`contents(for: UUID) -> String?`, `appendLine(_:for:)`). `URLRescueEngine`
already imports LunaStorage (it logs via `SharedDiagnosticLog`), so the engine
may reference the store directly — but every use must degrade gracefully when
`contents` is nil (older failures, extension-side failures not yet flushed).

## Why rescues fail today (verified 2026-08-13)

1. **The model is blind to the failure.** The plan prompt
   (`LunaURLRescue/RescuePrompts.swift:105-119`) carries the URL, ONE canned
   sentence (`failureDescription`, `:124-133` — three fixed strings), and a
   digest of the page HTML. No HTTP status, no subscribe-redirect landing URL,
   no record of the 13 bypass strategies that already ran and failed. The model
   re-discovers, in one shot, what the pipeline already knows.
2. **No HTML ⇒ instant death before the LLM.** `URLRescueEngine.runRescue`
   (`URLRescueEngine.swift:113-123`): `try? fetchHTML` — a 403/timeout leaves
   html empty and the whole rescue returns `.unrescuable` without ever asking
   the model. The pages MOST in need of rescue (bot-walled, paywalled) are
   exactly the ones that die here.
3. **Shipping builds are on-device only.** PCC compiles out under stable
   Xcode 26.2 (`RescueModelSessionFactory.swift:16-28`), so
   `supportsArticlePayload == false`: article-kind plans are salvaged to
   reroute/webjs or rejected. Digest budget is 9,000 chars
   (`RescueDigestBuilder.swift:20-22`). Everything below must work on-device.
4. **Attempts burn on predictable failures.** Guardrail violations are
   documented "permanent for this URL" (`RescueDirective.swift:105-106`) but
   collapse into plain `.unrescuable` — the ledger records an ordinary attempt
   and the card offers a manual retry that will trip the same guardrail.
   `OnDeviceRescueSession.normalize` (`OnDeviceRescueSession.swift:71-78`) maps
   only 3 GenerationError cases; refusal / assetsUnavailable /
   concurrentRequests / decodingFailure all become `.other`, unlogged.
5. **Success is never measured.** No telemetry of any kind; the only durable
   record is per-item ledger rows pruned when items disappear.
6. Known-dead legs: `.rescued` outcomes surface-dropped by `applyRescued`
   count as failures; `FailureKind.mediaNoAssets` unreachable (Plan A fixes
   the writer); media rescue in Reader/PriceTracker doubly dead (by design —
   leave that).

## Work items

### 1. Failure evidence in the prompt (highest leverage)

- New `RescueFailureEvidence` builder in LunaURLRescue: compresses
  `SaveDiagnosticsStore.contents(for:)` + `SaveFailureStore` record into a
  token-budgeted section — the LAST attempt's lines, deduplicated: final HTTP
  statuses per URL tried, `FetchError` kinds, the bypass strategies attempted
  and their outcomes, media ladder steps, redirect landings. Feed it into the
  prompt as a separately fenced, explicitly untrusted section:

  ```
  --- WHAT THE APP ALREADY TRIED (log excerpt, untrusted) ---
  ```

  Budget: carve ~15% out of the digest budget when evidence exists; the
  existing digest-halving overflow retry (`URLRescueEngine.swift:132,152-154`)
  must halve the evidence too.
- Replace the three canned `failureDescription` sentences with
  reason-specific text built from `SaveFailureReason` itself: include the
  actual status code for `.httpStatus`, the landing URL for
  `.subscribeRedirect`, offline/timeout/notReadable as today. (Keep it one or
  two lines; the evidence section carries the detail.)
- Update `RescuePrompts` instructions to tell the model to USE the evidence:
  don't re-propose what already failed; prefer routes the log shows untried.

### 2. Never die before asking the model

Rework `runRescue`'s no-HTML exit: when the refetch fails or yields nothing,
still call the model with URL + failure evidence + an empty-digest marker
(`--- PAGE DIGEST: unavailable (fetch failed: <reason>) ---`). Reroute,
search, and archive-handoff (below) need no page HTML. Only `give_up` should
be the answer to "no HTML and no evidence suggests anything".

### 3. Widen the action space

Extend `RescuePlanDraft.kind` (`RescueGenerableSchemas.swift` — keep the flat
umbrella-struct style, extend the `.anyOf` list) and the validator/applier:

- **`search`** — the model emits a search query (new optional field
  `searchQuery`). The engine runs `DuckDuckGoSearch` (LunaFetch), takes the
  top ~5 results, and makes a SECOND model call listing them (title + URL);
  the model picks one, which is then treated as a reroute. Host policy: the
  candidate set comes exclusively from the live search results — the model
  never invents the URL, it selects. For `product`/`media` hints keep
  same-registrable-domain only (a different seller/post is a different thing);
  for articles allow cross-domain when the result title strongly matches the
  item's `resolvedTitle`/failed-page title (syndicated copies, canonical
  homes). Validator: reroute-host rules relax ONLY for a URL present in the
  engine-supplied candidate list.
- **`inspect_url`** — one bounded intermediate round: the model names a URL it
  wants digested before committing (same host policy as reroute). The engine
  fetches, digests at half budget, and asks for the final plan. Hard bounds:
  max 1 inspect round + the existing overflow retry, everything still inside
  `totalBudget` 90s / `llmCallTimeout` 30s. Structure it as an engine loop
  over the existing session (multi-turn), not a free tool loop — bounds live
  in code, not in the prompt. (If the FoundationModels `Tool` protocol turns
  out cleaner under @Generable, fine, but the round cap must remain
  structural.)
- **`open_in_browser`** — a terminal directive that converts the failure into
  the interactive archive-unlock tier instead of a dead card:
  `SavesStore.markNeedsCaptcha(_:title:)` (which already clears the
  failure sidecar — `SavesStore.swift:809-822`). The model chooses it
  when evidence shows a bot-wall/paywall (401/403/429, subscribeRedirect) and
  no automated route worked. ALSO add the deterministic fast-path: when
  `SaveFailureReason.browserMayRecover` (`SaveFailureReason.swift:182`) and
  the archive tier has never been tried for the item, prefer routing there —
  before or instead of burning an LLM attempt (pick the ordering that keeps
  `URLRescueCoordinatorTests`' budget semantics coherent; document the
  choice). This changes what the failed card does, so update
  `claudedocs/failed-saves.md` and any card copy via the strings mechanism
  (`Localizable.strings`, `_Luna` suffix keys).

Applier/validator anchors: `RescueDirectiveValidator.swift:53` (add the new
kinds; keep every existing evidence rule — `.auto` must not relax them),
`RescueDirectiveApplier.swift:23-47` (new legs; `runPipeline` stays the RAW
`IngestPipeline.processResolved` — the no-recursion invariant is structural
and `KindCompositionRootTests`-adjacent suites pin it).

### 4. Stop burning attempts on predictable failures

- Map every `LanguageModelSession.GenerationError` case in
  `OnDeviceRescueSession.normalize`, each with its own log line.
- Guardrail: new `RescueLedgerStore` field marking the item permanently
  guardrailed; the coordinator never re-attempts it (auto or manual) and
  `FailedSaveCardFactory.rescueState` returns a terminal state so the card
  stops offering a retry that cannot work.
- Transient model errors (concurrent requests, assets downloading/unavailable)
  must NOT spend the per-version manual attempt (`recordAIAttempt`) — the
  model never saw the page. Same for `.rescued`-but-surface-dropped outcomes:
  log distinctly (`apply outcome=surface-dropped`).

### 5. Measure it

- Small aggregate counters sidecar (e.g. `rescueStats.json` in the App Group,
  LunaStorage, same lock+atomic-write shape as `SaveFailureStore`): attempts,
  outcomes by kind (rescued / unrescuable / guardrail / model-error /
  surface-dropped), successes by method (reroute / webjs / product / media /
  search / browser-handoff), cached-rule hits.
- Surface the totals as a line in the Diagnostics screen
  (`Luna/Diagnostics/DiagnosticsViewController.swift`) and a `[rescue]`
  summary log line per sweep. This is how "I've yet to see it accomplish
  anything" becomes checkable.

### 6. Rescue attempts join the per-save trace

Every rescue writes its lines BOTH to the general stream (existing
`SharedDiagnosticLog` category `"rescue"`, `URLRescueEngine.swift:336-338`)
and to `SaveDiagnosticsStore.appendLine(_:for:)` for the item being rescued —
plan kind chosen, validator verdict (with rejection reason), applier outcome,
per-round timing. Keep model OUTPUT summarized (kinds, hosts, lengths — not
verbatim generated text); full URLs are fine (the trace already carries them
and export is user-initiated). The existing hosts-only stance for the general
`"rescue"` category can stay as-is for untagged lines.

### 7. Tests (behavior bar; extend the existing fakes)

`URLRescueTests` / `URLRescueDirectiveTests` / `URLRescueCoordinatorTests` /
`URLRescueStorageTests`, using `FakeRescueModelSession` (records prompts —
assert the evidence section is present, fenced, and absent when the store has
nothing):

- evidence in prompt + halved with digest on overflow
- no-HTML path still calls the model; give_up only when warranted
- search: candidate-list-only reroute, cross-domain gated to article+title
  match, second-round prompt shape
- inspect_url: exactly one bounded round, timeout still enforced
- open_in_browser: marks needsCaptcha, clears failure sidecar, deterministic
  browserMayRecover fast-path
- guardrail permanence: ledger flag, no re-attempt, terminal card state
- transient errors don't spend the version attempt
- stats counters increment per outcome
- the no-recursion invariant tests stay green untouched

## Constraints

- Everything must work on-device (iOS 26 FoundationModels, 4096-token window);
  PCC-only code stays behind `#if compiler(>=6.4)`.
- `LunaURLRescue` remains main-app-only; the coordinator (`LunaSaves`)
  still never links it — new capabilities reach it through the injected
  `Engine` struct or `URLRescueWiring`.
- Sidecars only; never new `SavedItem` fields.
- Prompt-injection defense stays: page-derived content (digest, evidence,
  search results) goes in the PROMPT, never the instructions, always fenced
  and labeled untrusted.
- The 90s/30s budget shape (`raceAgainstTimeout`, not a task group) is
  load-bearing — a hung `respond` once wedged the card forever. Extend the
  loop inside it; don't restructure it.
