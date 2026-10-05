# Swift → JavaScript ingestion audit — 2026-10-06

## Verdict

**The migration is not complete and cannot be certified bug-free.** Core’s ownership boundary is substantially implemented, but disabling native extraction does not establish behavioral parity. This audit fixed reproducible regressions and identified the remaining gaps below.

Reviewed baseline: `24ae4cca4`, compared with `0db46d6e4` and the retained native implementations/tests. Scope is central Luna (`URLBehaviorPolicy.pluginsOnly`), including app, share/action, Safari, refresh and media re-resolution. Reader, Downloader and Price Tracker intentionally retain native implementations. Deleting those would break sibling apps; “nothing remains in Swift” is not literally true of the repository or linked binaries.

## Remaining findings

### P1 — Media results lose metadata and assets at the ingestion boundary

`LunaIngest/PluginOutcomeMapping.swift` converts `.media(assets, platform, itemID, title, thumbnailURL)` into `.video`/`.social`, retaining only platform and item ID. `IngestResult` carries URL/outcome/plugin ID, not the resolved model. `SavesIngestor` stamps the owner but cannot persist the lost model. `PlatformItemIngestor.platformMetadata` correctly refuses native enrichment in Core, leaving no replacement for the dropped plugin title/thumbnail. `Luna/PluginModelDrain.swift` takes the same path despite its no-refetch comment.

Downloads subsequently call `PluginMediaResolver` again. This wastes resolution, loses a page-only Safari result, and can select another plugin during initial download resolution. Expiry resolution is owner-filtered, but that does not fix initial-result loss. Repair: carry an explicit resolved-media payload through both persistence surfaces; retain declared assets and metadata together. Test a page-only plugin whose second invocation fails. Do not restore native scraping.

### P1 — Non-media social posts have no equivalent plugin result

`PluginModelKind` supports article/media/product only. Media requires `1...50` assets and `MediaModelAdopter` declines empty arrays. There is no bundled Bluesky plugin; `x.js` declines short text-only posts. Core preserves these as neutral links, whereas the former platform path classified them and fetched metadata, including Bluesky oEmbed titles. Repair requires a plugin-declared social/link metadata contract and implementing plugins, not fictitious media assets or articles.

### P2 — “Read instead” is not passed to plugins

`IngestInput.forceArticle` survives URL redispatch, but neither `PluginClassifyInput` nor `PluginIngestHookInput` exposes it. `web.js` interprets products before articles. The old pipeline honored this explicit choice. Add a documented preferred-kind/intent contract and enforce it at adoption; test the product reader action end to end.

### P2 — URL and retail parity remains incomplete

* Core’s `URLUnwrapper.ingestURL` rejects `fbrpc:` before dispatch. The old Facebook handler accepted its `target_url`; the replacement plugin cannot receive that input through the normal gate.
* `URLClassification.canonicalURL` returns the original URL in Core. The rewrite plugin ports wrappers, not the former tracking-query/identity normalization policy. Identifying a post in JS does not normalize its stored URL; tracking variants can remain separate identities.
* The JS Google Shopping detector is restricted to `google.com`. Prefixed prices such as `AU$` also need explicit normalization: the generic parser sees the trailing `$` as USD. Current Australian fixtures cover a narrower shape.

These repairs belong in plugin contracts/rules, not host-specific Swift exceptions.

### P2 — Article/publisher parity is not exhaustive

Measured failures were fixed below, but Swift’s `ArticleExtractor` also has detailed inline recirculation removal, comment-count terminators, trailing image/link-farm trimming, lead-image placement and short-page arbitration. Those algorithms are not all mirrored in `LunaWeb.article`. The X article renderer is a simplified renderer, not a complete port of native Draft entity-range/link handling. Publisher access approximates the old ladders. A few fixtures do not prove every publisher behavior; live site availability was not checked.

### Runtime limitation — Deadlines do not interrupt JavaScript

JSC uses one persistent context per plugin over a shared VM and serial queue. A synchronous infinite loop can monopolize that queue/VM. The caller’s deadline returns but cannot terminate the loop through the public JSC API. Safari timers likewise cannot interrupt synchronous JS blocking their world. Capability grants are not CPU/memory isolation. Hostile-code containment needs a separate execution-isolation design; this audit does not certify it.

## Fixed in this audit

| Area | Defect and repair |
| --- | --- |
| Wrappers | Restored publisher whole-segment interstitial matching, legacy/case-insensitive keys and same-site aliases; validated Facebook targets and padded Google News base64 IDs. |
| Article boundaries | Stopped adjacent-story concatenation and prioritized explicit body containers over longer unrelated discussion. |
| Article preservation | Replaced markup-as-identity with tree identity/order; retained duplicate paragraphs, div prose, code, tables and additional headings. |
| Paywalls | Added plugin-owned structural truncation, withheld-body, gate and weak-marker checks; stopped saving long previews as complete articles. |
| Retail | Restored Bunnings/nested-currency embedded JSON extraction and Amazon identifier/image enrichment, without evaluating page scripts. |
| Redirects | Owner refresh/compare interprets final responses; subscription redirects decline into publisher access instead of creating rewrite cycles. |
| CDN requests | TikTok/YouTube plugins now declare referers removed from Core’s native defaults. |
| Cancellation | Cancelled hooks stop waiting promptly without busy-polling or receiving timeout strikes. |
| Idle budgets | Pending calls capture the outer pipeline heartbeat; bounded browser steps keep both idle clocks alive while awaiting user interaction. |
| Late callbacks | Promise validity includes invocation lifetime before JS resumes, even if another call keeps its generation alive. |
| DOM/URL parity | Native selectors exclude their receiver like DOMParser/linkedom; URL fragments retain their encoded representation. |
| Result schema | JSC and Safari reject answers containing both a rewrite and a model. |
| Native remnants | Deleted unused native plugin article extraction and semantic metadata/price/date bodies; retained generic DOM/JSON/text primitives. |
| Authoring/tests | Deprecated retired APIs in typings; semantic parity tests now run the actual plugin-owned JS helper over JSC/Safari/Node. |

## Call structure and APIs

App/share/action composition → `IngestPipeline.processResolved` → `PluginIngestStage` → matched `classify` → `ingest` → schema validation → relative URL resolution → native adapter → outcome → persistence. Rewrites re-enter matching, discard old captures and enforce cycle/hop limits. No claim produces Core’s plain-link baseline; unsupported transcription remains a distinct failure.

Safari runs `content.js`/`plugin_host.js`, relays privileged operations to `SafariPluginMessages`, and queues models for `PluginModelDrain`. Native capability/schema validation remains authoritative. Price refresh/compare invokes the recorded owner. Expiry resolution filters by owner; initial media result loss is the exception described above.

Swift legitimately retains HTTP, bounded downloads, cookies, browser presentation, DOM syntax, persistence, trusted markup conversion, document conversion, muxing and transcription. Website extraction policy should not be hidden inside those services.

The generic bridge APIs support the repaired extraction rules. The missing social-result and preferred-kind contracts are significant authoring gaps. Plugins must use `luna.parseURL`/`luna.bytes`, rather than assume browser globals exist in JSC. Bundle shared helpers into the plugin file and bump its version when changing them. Node is a development harness, not a sandbox or a substitute for native/Safari testing.

## Verification and limits

The original selected baseline passed 90 simulator tests and the full existing Node harness before the additional cases exposed regressions. New shared fixtures cover article boundaries, duplicates, div prose, code/tables, unlocked wrappers, long truncation, and readable/paywalled NYTimes, WSJ, SMH, Washington Post, The Information and Paris Review pages. Existing retailer fixtures now exercise shipping JS too.

Final totals appear below. No production site calls, App Store mutations, physical-device automation or WebDriverAgent use occurred. Full legacy/UI snapshots and live publisher/retailer reliability are not covered. Passing tests does not close the remaining findings.

Final verification: **223 selected iOS 26.2 simulator tests passed, 0 failures** (`/tmp/luna-ingestion-audit-final-tests.log`); the full `tools/plugin-sim` npm test command passed, including **109 shared API cases**, 775 UTF-8 vectors, 57 manifest cases, migration/ownership regressions, the new article/retail matrix and TypeScript authoring checks (`/tmp/luna-ingestion-audit-node-final.log`).
