# AI flows — automatic Apple Intelligence, LLM hand-off by deep link, the Luna file

## Status

LANDED on `main` (2026-09-20). All four work packages merged through the
`ai-flows` integration branch. Final full suite from empty derived data on a
fresh iOS 26.2 simulator: `Executed 2098 tests, with 8 tests skipped and 7
failures` — the seven (`ArticleCoverThumbnailTests.testBackfillReusesDownloadedLeadImage`,
`PluginDetailScreenTests.testTheSettingsHookReceivesAMapKeyedByTheSettingThatChanged`
(load-flaky), `ProductHistoryPillRenderTests.testATrackedPageGetsTheSellerPillAloneInTheLowerSlot`,
`SafariVideoOverlayContractTests.testTheOverlayIsOfferedFromExactlyOnePillDecision`,
`ScrollDirectionImmersionTrackerTests.testUpwardTravelPastThresholdFiresImmersedFalse`,
`UtilCardTests.testAnExpiredEntryIsNoEntry`, `WeeklySaveTests.testAnExpiredRecordClearsTheRow`)
all fail identically on the `main` this work started from and none touches
this work. The three sibling schemes build. The hosted API page is live at
`https://luna-site-bm6.pages.dev/p1`. Owner decisions in §1 are final; the
rest of this document is the contract the code now implements — the
present-tense references are `claudedocs/luna-file.md`,
`claudedocs/llm-handoff.md`, `claudedocs/url-rescue.md`,
`claudedocs/failed-saves.md`, `claudedocs/plugins.md` §10.

Both small gaps the packages left are CLOSED (2026-09-20): a recovery file's
refusal reason now rides the hand-off record in the App Group and survives a
relaunch, and the Downloader's no-media card reads its hint from that record on
every apply instead of only on the tap. The same wave added the chat hand-off to
a READY save's long-press menu — a save can succeed and still hold the wrong
content — and made each kind's handler replace that content in place
(`claudedocs/llm-handoff.md`).

## 0. What changes, in one paragraph

Apple Intelligence (URL Rescue) becomes a silent, one-shot, automatic
recovery step: it runs once per failed save and never again, and no surface
offers it as a button. The user-facing recovery route is instead a hand-off
to ChatGPT or Claude: a button on the failed card opens the provider's app
with a prompt already filled in; the model replies with a **Luna file**
(`{title}.luna`, `.lunar`, `.lunad`, `.lunas`); the user taps the file and
Luna imports it — as a completed save (recovery) or as a plugin draft shown
on a nutrition label (plugin creation). The same file can arrive through the
share sheet or through Open In, in the app or in an extension, and the flow
finishes wherever the file lands. The copy/paste plugin "workshop" is
deleted. The JavaScript API a generated plugin sees gains the few helpers an
LLM-written extractor most often gets wrong by hand, and every prewritten
prompt in the codebase is rewritten.

## 1. Owner decisions (2026-09-20)

| # | Decision |
| --- | --- |
| D1 | Claude button opens ordinary chat first: `https://claude.ai/new?q=…`. Claude Code (`https://claude.ai/code/new?q=…`) is the fallback the user can pick from the button's long-press menu; once picked it is remembered (`LLMProviderPreferences.claudeTarget`). |
| D2 | A recovery file carries a **replayable recipe** (alternate URL, headers, optional page script) that Luna replays through its own pipeline first, plus the **full content** Luna adopts directly when the recipe is absent or fails. |
| D3 | The plugin API reference is hosted on the existing Cloudflare Pages site (`site/`, project `luna-site`) at a short path, `https://luna-site-bm6.pages.dev/p1`, and the plugin prompt links to it. I generate the page and deploy it (`npx wrangler pages deploy`, needs `wrangler login`); if the deploy is blocked the owner publishes later. |
| D4 | All four apps get the LLM recovery route. Extensions: `.luna` (central Luna), `.lunar` (Reader), `.lunad` (Downloader / "Luna Video"), `.lunas` (Price Tracker). Central Luna opens all four. |
| D5 | Every user-triggered Apple Intelligence entry point is removed: the failed card's Retry with AI, the extension failure card's Retry with AI, the Downloader failed-download card's retry, the price editor's no-price alert retry, and the bulk link import's per-item rescue. |
| D6 | ChatGPT and Claude icons are monochrome vector approximations drawn in code (one asset/glyph type each), swappable later for official artwork. |
| D7 | "Create a plugin" lives in Settings → Plugins (replacing the wand's workshop) AND on the failed card's menu ("Create Plugin…"), which opens the same screen with the URL and the failure prefilled. |

## 2. Facts the design rests on (verified 2026-09-20)

- **Deep links.** ChatGPT: `chatgpt://new-chat?prompt=<encoded>` (owner-supplied; undocumented by OpenAI) with the documented web form `https://chatgpt.com/?q=<encoded>` (auto-submits) as fallback when the scheme cannot be opened. Claude: `https://claude.ai/new?q=` (chat; a universal link, opens the Claude app when installed), `https://claude.ai/code/new?q=` / `claude://code/new?q=` (Claude Code; documented, composer prefilled, not auto-sent, needs Claude Code access). Claude Code caps `q` at 5,000 characters; third-party generators cap ChatGPT links at 2,000–4,000. **Budget: a prompt is ≤ 3,600 characters raw and the built URL ≤ 8,000 characters; both are pinned by tests.**
- **The four content apps share ONE `Luna/Info.plist`**, differentiated by per-target build settings (`LUNA_URL_SCHEME` at `project.pbxproj:2960,3021,3558,4197` and the extension twins). Only string VALUES interpolate. No app has `CFBundleDocumentTypes`, `UTExportedTypeDeclarations`, or a `file://` branch in `SceneDelegate.route` today. `NSExtensionActivationSupportsFileWithMaxCount = 1` already lets any file reach the share/action extensions; `ShareAttachmentRouter.documentTypes` (`ShareAttachmentRouter.swift:52`) decides what happens to it.
- **The rescue machinery to reuse.** `PluginModel` (LunaModels, hand-decoded with caps) + `PluginModelAdopters` + `PluginOutcomeMapping` + `SavesIngestor.applyRescued(_:forItemID:interactive:)` is exactly the "Model JSON → persisted save" chain (`Luna/PluginModelDrain.swift:84-129` is the template). The recipe vocabulary is `RescueReroute`/`RescueScript` validated by `RescueDirectiveValidator` and applied by `RescueDirectiveApplier` (LunaURLRescue, **app only**, never linked into extensions).
- **The workshop to delete** is `PluginRecoveryWorkshopViewController` (+ `copyPrompt/sharePrompt/copyFix`, the privacy alert, the paste box, `Plugins_recovery*` strings). `PluginRecoveryCase`, `PluginRecoveryProbe`, `PluginDraftValidator`, `PluginDraftSource`, `PluginImporter` (transactional) and `PluginConsentViewController` stay and are reused. `PluginImporter.preview` passes `hooks: []` (`PluginImporter.swift:47`) — the nutrition label must compute hooks from `manifest.requiredHooks`.
- **Prompt inventory.** On-device (FoundationModels): `RescuePrompts` (LunaURLRescue), `AudioTrimIntelligence.instructions` + `AudioCleanupVerdict` guide (LunaAudioPlayback), `AppNamePlatform.screenPrompt/safariScreenPrompt` (LunaIntents), `FoundationModelsWritingAssistant` (LunaWriterEditor). External-chat: `PluginRecoveryPromptBuilder` (LunaPluginKit, 28,000-char budget — replaced).
- **`extensionContext.open`** is the only URL-opening route an extension has (`ShareViewController.swift:764`, best effort, not universally honored).

## 3. The Luna file

One UTF-8 text file. The first non-whitespace token is a block comment whose
first line (trimmed) is the **marker**, followed by ONE JSON object, closed by
`*/`. `PluginManifestParser.extractHeader` already parses this shape for
`luna-plugin`; it is generalized into `LunaFileHeader.parse(_:)` (LunaModels)
that returns the marker and the JSON text, and the plugin parser calls it.

| Marker | Body after `*/` | Meaning |
| --- | --- | --- |
| `luna-plugin` | JavaScript (unchanged plugin format) | a plugin draft |
| `luna-recovery` | one JSON object (§3.1) | a recovered save |

Anything else (no header, unknown marker, header JSON invalid) is not a Luna
file. Size cap 1,024 KB (`PluginManifestParser.maxSourceKB`, reused).

### 3.1 Recovery file

```
/* luna-recovery
{ "api": 1, "url": "https://example.com/the-page", "kind": "article" }
*/
{
  "recipe": { "url": "https://example.com/the-page?output=amp",
              "headers": { "user-agent": "googlebot", "referer": "https://example.com/" },
              "javascript": "return document.querySelector('article').outerHTML" },
  "content": { "kind": "article", "title": "…", "author": "…", "publishedAt": "…",
               "html": "<p>…</p>", "leadImageURL": "…", "language": "en" }
}
```

- Header JSON: `api` (integer, must be 1), `url` (the page the user saved,
  absolute http(s)), `kind` (`article` | `media` | `product`, must equal
  `content.kind`), optional `note` (≤ 300 chars, human-readable, shown
  nowhere in v1 but kept for diagnostics).
- `content` is **required** and is exactly a plugin `PluginModel` of that
  kind (same decoder, same caps: `title` 300, `html` 4 MB, `assets` 1…50,
  price amount a decimal string). A relative URL inside it resolves against
  the header `url`.
- `recipe` is **optional**: `url` (https, same registrable domain as the
  header URL or one of the fixed mirrors `web.archive.org` / `r.jina.ai`),
  `headers` (only `user-agent` as a `RescueDirectiveValidator.userAgent(fromToken:)`
  token or a literal UA, `referer`, `accept-language`; anything else is
  dropped, never an error), `javascript` (≤ 8 KiB, runs in the off-screen
  `RescueWebScriptRunner`, must return a string), `returns`
  (`html` | `json` | `mediaURL`, default `html`).

**Apply order (app):** locate the save by URL → validate the recipe → replay
it (reroute → raw `IngestPipeline.processResolved`; javascript → script
runner, result fed to extraction; 30 s total) → if that produced a ready
save, learn a `RescueRuleStore` rule for the host and stop → else adopt
`content` through `PluginModelAdopters` + `PluginOutcomeMapping` →
`SavesIngestor.applyRescued(_:forItemID:interactive:)` against the EXISTING
failed item (found by normalized URL, `.failed` or `.needsCaptcha`); when no
such item exists, `reserveSaveAttempt` a new one (as `PluginModelDrain`
does). The result then goes through the ordinary surface gate, so a Reader
receiving a product file shows the existing unsupported-save card and stores
nothing.

**Apply order (share/action extension):** no recipe replay (LunaURLRescue is
not linked): adopt `content` directly, same gate, present through the
existing `ShareKindPresenters` so the user sees the normal saved card. The
recipe is written to `PendingRecoveryRecipeStore` (App Group, 24 h) and the
app replays it on next foreground purely to LEARN a host rule; the already
recovered save is not touched.

### 3.2 Plugin file

Unchanged from `docs/plugins/README.md` §1. The file extension is what
changes: the LLM is asked for `{name}.luna`, and Luna also accepts `.js`
through the existing manual import path.

### 3.3 Registering the type

In the shared `Luna/Info.plist`, every content app EXPORTS the same four
UTIs (identical static declarations — an exporter set that agrees is
harmless, and it means each app knows the family's types whether or not its
siblings are installed):

| UTI | Extension | Conforms to |
| --- | --- | --- |
| `$(PRODUCT_BUNDLE_PREFIX).file` | `luna` | `public.plain-text`, `public.content` |
| `$(PRODUCT_BUNDLE_PREFIX).reader.file` | `lunar` | `$(PRODUCT_BUNDLE_PREFIX).file` |
| `$(PRODUCT_BUNDLE_PREFIX).downloader.file` | `lunad` | `$(PRODUCT_BUNDLE_PREFIX).file` |
| `$(PRODUCT_BUNDLE_PREFIX).pricetracker.file` | `lunas` | `$(PRODUCT_BUNDLE_PREFIX).file` |

`CFBundleDocumentTypes` has ONE entry whose `LSItemContentTypes` is
`$(LUNA_DOC_UTI)` with `LSHandlerRank = Owner`, and `LUNA_DOC_UTI` is set
per app target in `project.pbxproj` beside `LUNA_URL_SCHEME`: central Luna →
`$(PRODUCT_BUNDLE_PREFIX).file` (which, by conformance, covers all four
extensions), Reader → `.reader.file`, Downloader → `.downloader.file`, Price
Tracker → `.pricetracker.file`. `LSSupportsOpeningDocumentsInPlace` = NO
(Luna copies the file out of its inbox and deletes it).
`scripts/add_luna_app.rb` gains the `LUNA_DOC_UTI` override next to its
bundle-id override (and should also start setting `LUNA_URL_SCHEME`, a
pre-existing gap). `LSApplicationQueriesSchemes` gains `chatgpt` and
`claude`. A `LunaFileTypeTests` reads the built app's Info.plist and checks
the four declarations, the document type and the queries schemes.

`LunaApp.fileExtension` (LunaModels): `luna`/`lunar`/`lunad`/`lunas`;
`LunaApp.acceptedFileExtensions`: central → all four, others → own only.

### 3.4 Intake — every way a Luna file reaches Luna

`LunaFileIntake` (LunaModels, pure): `classify(text:) -> LunaFileKind?` and
a single dispatch seam `LunaFileIntakeHandling` (protocol; `recovery(_:)`,
`plugin(_:)`), installed by each composition root:

| Route | Where | What it does |
| --- | --- | --- |
| Open In / Files / a provider's "Open in Luna" | `SceneDelegate.route` gains a `url.isFileURL` branch (cold launch and `openURLContexts`) | security-scoped read (≤ 1 MB), delete the inbox copy, `LunaFileIntake.classify`, dispatch |
| Share sheet / action sheet, file attachment | `ShareAttachmentRouter.documentTypes` gets the four UTIs FIRST; `ShareViewController.handleDocument` reads the text and dispatches before `saveDocumentDirectly` | same |
| Share sheet, plain text | `handleText`: if the trimmed text starts with `/*` and `LunaFileIntake.classify` recognizes it, dispatch — this is the fallback for a provider that can only show the file as a code block (long-press → Share) | same |
| A `.js` file via Settings → Plugins → + | unchanged manual import (also accepts a `.luna` plugin file) | plugin |

A plugin file in a sibling app (Reader/Downloader/Price Tracker) shows the
existing `UnsupportedSaveCardViewController` with a new message ("Plugins run
in Luna."). A recovery file whose `kind` the app does not handle shows the
existing generic unsupported card.

## 4. Recovery flow

### 4.1 Apple Intelligence: automatic, once, silent

- `RescueLedgerStore.maxAutoAttempts = 1`; `autoRetrySpacing` and the
  24-hour re-try are deleted; `shouldAutoRescue` is "no attempt yet and not
  guardrailed". `resetAttempts(for:)`, `URLRescueCoordinator.reopenStaleVersionAttempts`,
  `SaveFailureRecord.aiAttemptVersion`, `recordAIAttempt`, `hasSpentAIAttempt`,
  `idsWithStaleAIAttempt` are deleted (an app update no longer reopens the
  budget — D5's "if it fails don't retry it"). The `guardrailedAt` and
  `browserHandoffAt` legs stay.
- `requestManualRescue`, `rescueAndWait`, `RescueRunResult.spendsVersionAttempt`
  and the `countsAgainstBudget`/`spendsVersionAttempt` parameters go; the
  one funnel is `runRescue(itemID:)`, always budgeted. `LinkImportRunner`'s
  `rescue:` / `rescueFraction:` closures go (the imported item's own
  `.failed` fires the ordinary trigger).
- Triggers that remain: `SavesIngestor.rescueTrigger` on a `.failed` first
  pass (interactive or not — the "interactive only" gate on `itemJustFailed`
  is dropped, the background sweep already covered the rest), the debounced
  foreground sweep (still batch 3, still `ledger.prune`), and the
  extension→app queue: the extension's failure leg ALWAYS appends a
  `PendingRescueRequest` (no tap; dedupe by URL is already there), and
  `drainPendingRequests` runs the budgeted funnel.
- `ContentHint` stays `.auto` everywhere; `RescueHint` loses its last two
  programmatic callers and is deleted with them (`ProductPriceRescue`,
  `MediaCardRescue`, `URLRescueWiring.rescueProductInfo`, the
  `RescueRequest.hint` plumbing → `RescueRequest.ContentHint` collapses to
  the auto path; `RescueDirectiveValidator` keeps `ContentHint.allows` only
  if it is still reachable, else it goes too).
- Diagnostics keeps `RescueStatsStore` and the sweep log line.

### 4.2 The failed card

`FailedSaveCardModel.RescueState` becomes:

```swift
public enum RescueState {
    case running(progress: Double)          // the one automatic attempt is in flight
    case offer                              // show the LLM row
    case waiting(LLMProvider)               // the user tapped a provider; file not back yet
    case applying(progress: Double)         // a Luna file is being applied
}
```

No terminal apology, no Retry with AI, no `spent`/`unavailable`. The chin
under the URL bar is the **LLM row** (`LLMHandoffRowView`, LunaDesignSystem):
a caption ("Recover with") and two glass buttons, each a provider glyph plus
name. In `.waiting` the row stays and a hint line reads "Tap the .lunar file
in the reply and choose Luna." (`LunaApp.fileExtension` interpolated).
The Claude button's long-press menu offers "Use Claude Code" (D1). Long-press
on the card keeps Share Link…, Share Diagnostics… (with a trace), Create
Plugin… (central Luna), Delete.

Tapping a provider: build `LLMHandoffPrompts.recovery(...)` (§7), build the
provider URL (`LLMDeepLink`), record `LLMHandoffStore.begin(.recovery(itemID:url:), provider:)`,
`UIApplication.open`. While a handoff is recorded for the item the card shows
`.waiting`; the record expires after 24 h or when a Luna file for that URL is
applied (from any process — the store is App Group JSON).

The Downloader's failed-download card (`MediaCardFactory`, failure kind
`.noMedia`) shows the same row (kind `media`) in place of its retry button.
The price editor's no-price alert loses its AI action.

### 4.3 The extension failure card

`RescueFailureViewController` shows the same LLM row. A tap tries
`host.openURL(providerURL)`; because `extensionContext.open` may be refused,
the leg ALSO writes the `LLMHandoffStore` record and, when the completion
reports `false`, opens the containing app at `<scheme>://llm?item=<uuid>`
(same best-effort route as `<scheme>://rescue`), whose handler opens the
provider URL from the app. Either way the card's hint line tells the user
the reply's file opens in Luna.

### 4.4 Applying the file

`RecoveryFileApplier` (LunaSaves): the §3.1 apply order. Recipe replay is an
injected protocol witness `RecoveryRecipeReplaying` (installed by
`URLRescueWiring` in the app; `NoRecipeReplay` elsewhere), so LunaSaves never
links LunaURLRescue. Progress posts on the existing `.rescueProgressChanged`
so the card's `MoonHorizonProgressBar` animates `.applying`. On success the
deck selects the recovered card (the normal save viewer); on a decode or
validation failure the card returns to `.offer` with a one-line reason
(`LunaFileError.localizedDescription`), and the file is not retried.

### 4.5 Deep link additions (`LunaDeepLink`)

`<scheme>://llm?item=<uuid>` (open the provider for a recorded handoff) and
nothing else — a Luna file never travels in a deep link.

## 5. Plugin flow (central Luna only)

### 5.1 Create screen

`PluginCreateViewController` (LunaPluginUI) replaces the workshop. It is
opened from Settings → Plugins (the wand button, title "Create with AI") and
from the failed card's "Create Plugin…". Contents: a multi-line description
box ("Describe the site or the kind of link, and paste an example URL"),
the LLM row, and — when a handoff is recorded — the waiting hint. From a
failed card the box is prefilled with the URL and the failure sentence
(`RescueFailureEvidence.failureSentence`, moved to LunaModels as
`SaveFailureReason.rescueSentence` so LunaPluginUI can reach it) and the
matched-plugin list from the save's trace when one exists.

Tap → `LLMHandoffPrompts.pluginCreation(description:host:)` → provider URL →
`LLMHandoffStore.begin(.plugin(description:host:), provider:)`. The
description persists in that record, so leaving and returning shows it
again (also from the share extension, which reads the same store).

### 5.2 Review screen (the nutrition label)

`PluginDraftReviewViewController` (LunaPluginUI) opens whenever a
`luna-plugin` Luna file arrives (app or extension). It runs
`PluginImporter.preview` (header only) then `PluginDraftValidator.validate`
(disposable runtime; classify/ingest when the recorded handoff or the header
gives a target URL, else load-preflight only) and shows, top to bottom:

1. Name, version, description, "Replaces version N" when applicable.
2. **Produces** (kind sentences) and **Matches** (`hostPatterns` / "any
   website"), priority.
3. **Hooks** (`manifest.requiredHooks` ∪ hooks the preflight saw registered).
4. **Capabilities**: one plain-language line each (`PluginCapabilityCopy`),
   `(new)` tagged on an update; capabilities the draft test did not exercise
   are marked "not tested". `PluginDraftValidator.allowedCapabilities` widens
   to every capability; only `fetch`/`html` are SERVED during the test, the
   rest are the standard unavailable proxies.
5. Settings fields it declares, background flag, export declaration.
6. **Validation result**: passed (kind produced) or the error list.
7. `containmentDisclosure`.
8. Buttons: **Save** (= consent + `installAsync`, transactional; disabled
   while validation runs, enabled on pass; on a FAILED validation still
   enabled but labelled "Save anyway" — an author who knows better is not
   blocked), **Discard**, and **Generate again** as the LLM row, which builds
   `LLMHandoffPrompts.pluginCorrection(description:errors:)` from the
   recorded handoff (a compact error list, ≤ 900 chars) and opens a NEW chat.

Saving from an extension writes `PluginStore` (App Group); the app reloads
its runtime on `sceneDidForeground` when `PluginStore.changeToken`
(a new mtime-stamped marker file) differs from what it last loaded.

### 5.3 What is deleted

`PluginRecoveryWorkshopViewController`, `PluginRecoveryPromptBuilder` (its
budget helpers go too), the `Plugins_recovery{CopyFix,CopyPrompt,SharePrompt,
Intro,PrivacyTitle,PrivacyMessage,PasteLabel,Validate,Validating,Passed,
Revalidate,Install,Installed,URLTitle,URLMessage,InvalidURL,Probing}` strings,
`FailedSavePluginRecovery`'s workshop push (the seam stays, it now presents the
create screen), and the Safari handoff's workshop target (it now opens the
create screen prefilled from the handoff case). `docs/plugins/README.md` §10
is rewritten for the new loop.

## 6. The JavaScript API for generated plugins

Goal: the things an LLM-written extractor most often reimplements badly get
one correct, tested helper each. All under existing capabilities; every new
`luna.html` member is specified in `html-subset.spec.js` and runs on all
three backings, except `article`, which is native (SwiftSoup
`ArticleExtractor`) in the app/extensions, RELAYED to native from Safari
(`plugins.article` message, like `fetch`), and approximated by
`@mozilla/readability` in the node harness (documented as approximate).

| Addition | Shape | Notes |
| --- | --- | --- |
| `luna.html.meta(doc)` | `{ title?, description?, canonical?, image?, author?, published?, siteName?, language?, type? }` | `<title>`, OpenGraph, Twitter cards, `<meta name=author>`, `article:published_time`, `<link rel=canonical>`, `<html lang>`; JSON-LD `Article`/`NewsArticle`/`Product` fill gaps |
| `luna.html.jsonLD(doc)` | `object[]` | `jsonScripts(doc, "application/ld+json")` with `@graph` flattened and parse errors skipped |
| `luna.html.article(html, baseURL?)` | `{ title, html, text, author?, publishedAt?, leadImageURL?, excerpt? } \| null` | Luna's own readability pass; `null` when no main content |
| `luna.fetch.text/json/doc(url, opts?)` | `Promise<string>` / `Promise<unknown>` / `Promise<HTMLDocument>` | sugar over `luna.fetch`; `doc` sets `baseURL` to the final URL; non-2xx rejects `fetch-failed` with `status` in the message |
| `luna.text.price(s)` | `{ amount: string, currency?: string } \| null` | Luna's `PriceParsing` rules (thousands/decimal separators, symbols → ISO 4217) |
| `luna.text.date(s)` | ISO 8601 string or `null` | common absolute formats; no relative dates |
| `luna.text.clean(s)` | string | entity decode, whitespace collapse, trim |

Cleanups in the same package: `tools/plugin-sim/run.mjs`'s hand-rolled
manifest validator is replaced by the same rules table the Swift parser
reads (`PluginManifestRules.json`, bundled in LunaPluginKit and imported by
the harness; `PluginManifestRulesParityTests` pins them); `luna-plugin.d.ts`
and `docs/plugins/api.md` gain the new members; `PluginAPISurfaceTests` pins
that the `.d.ts` declares every `PluginCapabilityName` namespace and every
`luna.html`/`luna.fetch`/`luna.text` member the bridges install.

## 7. Prompts (written by the lead, not by the packages)

All external-chat prompts live in ONE file, `LunaLibraries/Sources/LunaModels/AI/LLMHandoffPrompts.swift`
(pure functions, no I/O, budget-asserted by `LLMHandoffPromptTests`):

- `recovery(url:app:failure:)` — the failed-save hand-off (≤ 2,600 chars).
- `pluginCreation(description:host:app:)` — Settings/failed-card plugin
  request (≤ 3,600 chars), links `https://luna-site-bm6.pages.dev/p1`.
- `pluginCorrection(description:errors:)` — Generate again (≤ 3,600 chars).

On-device prompts rewritten in place: `RescuePrompts`, `AudioTrimIntelligence`,
`AppNamePlatform`, `FoundationModelsWritingAssistant`. The hosted reference
is `docs/plugins/llm-api.md`, copied by `scripts/build_site.py` to
`site/dist/p1` and served as `text/markdown` via `_headers`.

`LLMDeepLink` (LunaModels): `url(for provider: LLMProvider, prompt: String, claudeTarget:) -> URL`,
`fallbackURL(...)`, `maxPromptCharacters = 3_600`, `maxURLCharacters = 8_000`;
encoding uses a strict allowed set (`urlQueryAllowed` minus `&+=?#/`).

## 8. Persistence summary

| Store | Where | Lifetime | Written by | Read by |
| --- | --- | --- | --- | --- |
| `LLMHandoffStore` (`llmHandoffs.json`) | App Group, `LunaStorage` | 24 h, cleared on apply | app + extensions | failed card, extension card, create screen, review screen |
| `PendingRecoveryRecipeStore` | App Group | 24 h | extensions | app foreground (rule learning) |
| `PendingRescueRequestStore` | existing | 3 days | extension failure leg (now automatic) | `drainPendingRequests` |
| `LLMProviderPreferences` | `UserDefaults` (App Group) | — | Claude long-press | `LLMDeepLink` |

## 9. Work packages

Every package: worktree off `ai-flows`, foreground `xcodebuild` only,
`scripts/run_tests.sh --changed` while iterating, commit in small chunks,
update the docs it touches, report the exact test line. The lead merges
into `ai-flows`, runs the full suite, then merges into `main`.

### WP1 — Luna file, type registration, intake (LunaModels, LunaShareSurface, app shell)

Files: `LunaModels/LunaFile*.swift` (header parser, `LunaFileKind`,
`LunaFileIntake`, `LunaFileIntakeHandling`, `LunaApp.fileExtension`),
`PluginManifestParser.extractHeader` → uses the shared header parser,
`Luna/Info.plist`, `project.pbxproj` (`LUNA_DOC_UTI` per target),
`scripts/add_luna_app.rb`, `SceneDelegate.route` file branch,
`ShareAttachmentRouter`, `ShareViewController.handleDocument/handleText`,
`LunaDeepLink` (`llm` host), `UnsupportedSaveCard` plugin message, strings,
tests (`LunaFileTests`, `LunaFileTypeTests`, `ShareAttachmentRouterTests`,
`LunaDeepLinkTests`). Installs a no-op intake handler stub in every root so
WP2/WP3 only replace the witness.

### WP4 — JavaScript API (LunaPluginRuntime bridges, plugin_host.js, harness, docs)

Files: `PluginHTMLBridge`, `PluginFetchBridge` (sugar), new
`PluginTextBridge` (under `html` — no new capability), `plugin_host.js`,
`SafariPluginMessages+Luna` (`plugins.article` relay),
`tools/plugin-sim/{bridge.mjs,run.mjs,luna-plugin.d.ts}`,
`html-subset.spec.js` (+ cases), `PluginManifestRules.json` + parity test,
`docs/plugins/api.md`, `claudedocs/plugins.md` §5.

WP1 and WP4 run in parallel first. WP2 and WP3 start from `ai-flows` after
WP1 merges.

### WP2 — Recovery (LunaStorage, LunaSaves, LunaSavesUI, LunaShareSurface, LunaDesignSystem, app shell, LunaURLRescue)

Files: `RescueLedgerStore`, `SaveFailureStore`, `URLRescueCoordinator`,
`URLRescueWiring`, `LinkImportRunner`, `FailedSaveCardViewController`,
`FailedSaveCardFactory`, `RescueFailureViewController`, `ShareSurfaceDriver`
(auto-queue), `MediaCardFactory`, `ProductDetailViewController` (alert),
`GlassStyle` (delete `retryWithAIConfiguration`), new `LLMHandoffRowView`
+ provider glyphs (LunaDesignSystem), `LLMProvider`/`LLMDeepLink`/
`LLMProviderPreferences` (LunaModels), `LLMHandoffStore`,
`PendingRecoveryRecipeStore` (LunaStorage), `RecoveryFileApplier` (LunaSaves)
+ `RecoveryRecipeReplaying` witness (LunaURLRescue + wiring), `RescueHint`
removal, strings, stages (`failedSave.offer/waiting/applying`), docs
(`url-rescue.md`, `failed-saves.md`, new `claudedocs/llm-handoff.md`),
tests (update `URLRescueCoordinatorTests`, `URLRescueStorageTests`,
`FailedSaveTests`, `ShareSurfaceDriverTests`; new `RecoveryFileApplierTests`,
`LLMHandoffStoreTests`, `LLMDeepLinkTests`).

### WP3 — Plugin creation and review (LunaPluginUI, LunaPluginIngest, app shell, Safari handoff, site docs link)

Files: delete the workshop + prompt builder, `PluginCreateViewController`,
`PluginDraftReviewViewController`, `PluginsSettingsScreen` (wand →
create), `KindWiring+Luna` (intake witness, failed-card seam, Safari handoff
→ create screen, foreground plugin reload), `ShareEntry+Luna`/`ActionEntry+Luna`
(intake witness), `PluginDraftValidator` (widen capabilities, optional
target URL), `PluginStore.changeToken`, `StageCatalog+Plugins` (create,
review-pass, review-fail), strings, `docs/plugins/README.md` §10,
`claudedocs/plugins.md` §10/§13, tests (`PluginDraftReviewTests`,
`PluginCreateScreenTests`, update `PluginDraftValidatorTests`,
`SaveDiagnosticsShareUITests`, `KindCompositionRootTests` roots list).

### Lead (this document's author)

`LLMHandoffPrompts.swift` + tests, the four on-device prompt rewrites,
`docs/plugins/llm-api.md`, `scripts/build_site.py` + `site/dist/p1` +
`_headers`, the deploy, merges, the full-suite run, `main` merge, memory.

## 10. Test plan

- `LunaFileTests`: header parsing (marker exactness, JSON errors name a line,
  `*/` inside the body JSON is fine, size cap), classify text vs file,
  recovery header/body validation (kind mismatch, missing content, bad api).
- `LunaFileTypeTests`: the built `Luna.app` Info.plist declares the four
  UTIs, the document type resolves `$(LUNA_DOC_UTI)` per target, queries
  schemes include `chatgpt`/`claude`.
- `LLMHandoffPromptTests`: each prompt under budget for the longest realistic
  inputs, mentions the right extension per app, carries the header contract
  and the docs link; `LLMDeepLinkTests`: encoding round-trips `& + = ? # /`
  and newlines, URL length cap, Claude target switch, ChatGPT web fallback.
- `RecoveryFileApplierTests`: recipe wins and learns a rule; recipe fails →
  content adopted; content-only; unknown URL → new save; foreign kind →
  surface-gate drop; existing `.needsCaptcha` item recovered.
- Ledger/coordinator: exactly one automatic attempt, none after; no manual
  API; the extension failure leg queues without a tap; guardrail unchanged.
- Card: state table (`running`→`offer`→`waiting`→`applying`), no rescue
  button anywhere (`SaveDiagnosticsShareUITests` menu verbs updated), the
  Downloader failed-download card row, extension card row.
- Plugin: review screen renders hosts/hooks/capabilities/validation; Save
  installs transactionally; Discard writes nothing; Generate again builds the
  correction prompt from the recorded handoff; a sibling app shows the
  unsupported card for a plugin file; validator serves only fetch/html while
  passing a manifest that declares more.
- JS API: spec cases for `meta`, `jsonLD`, `text.*`; `article` bridge tests on
  SwiftSoup + Safari relay; `PluginAPISurfaceTests`; `PluginManifestRulesParityTests`;
  `npm test` + `npm run spec` green.
- Whole suite green on a fresh simulator before `main`.

## 11. Out of scope (recorded so nobody re-opens them)

- No LLM provider API keys, no in-app network call to any LLM.
- No detection of whether the provider honored the prompt; D1's long-press
  menu is the user's escape hatch.
- Gemini and other providers: `LLMProvider` is an enum with two cases;
  adding one is a glyph, a URL builder and a strings line.
- Recipe replay in extensions.
