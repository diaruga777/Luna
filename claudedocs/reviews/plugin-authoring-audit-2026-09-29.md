# JavaScript plugin authoring audit — September 29, 2026

## Fixed

| Finding | Change |
| --- | --- |
| Native registration accepted non-functions; getters could change a hook after validation. | Validate function values and capture a frozen hook table once in JSC, Safari and Node. |
| Circular/BigInt results lost useful errors; throwing thenables could become timeouts. | One settlement path uses captured Promise and JSON methods; errors reach diagnostics and a thenable settles once. |
| Invalid URLs threw in Safari/Node but returned null in the app. | Return null consistently; fix the nullable type declaration. |
| Native UTF-8 conversion emitted invalid bytes for lone surrogates and misread malformed sequences. | Match TextEncoder/TextDecoder replacement and BOM behavior; compare 775 decoding vectors. |
| Document articles required dummy HTML despite the documented contract. | Accept document-only articles in native decoding and the authoring harness. |
| Manifest validation drift hid bad settings, translations, export formats and Bluetooth declarations. | Shared enum/format tables and 57 shared acceptance cases; validate nested flags/options and reject malformed host patterns. |
| The default Node run bypassed validation and could hang forever. | All modes use one process-bounded evaluator, check host matching and serialize results through JSON. |
| Node fetch treated seconds as milliseconds and stopped timing the request before its body finished. | Convert seconds correctly, bound body consumption and abort on timeout. |
| Declared unavailable capabilities disappeared from Node. | Reject unavailable-here consistently while undeclared names stay absent. |
| Authoring guidance included an undefined model placeholder, wrong URL types and contradictory examples. | Working AI starter, precedence/export guidance, shorter human and AI references, tested article/media/product starters and TypeScript checks. |

The dependency update removes the undici advisory reported by npm audit. The
harness does not use WebSockets, the affected feature. Two existing test races
were also exposed: a UI fake published its invocation before its argument, and
an idle-budget test had insufficient scheduling headroom under simulator load.
The fake now records atomically; the budget test still exceeds its wall-clock
budget while allowing more time between callbacks.

## Scope and limits

Reviewed runtime registration/settlement, bootstrap helpers, manifest parsing,
Node and Safari bridges, Model decoding, authoring tools/docs/prompts, import
rollback and ingest dispatch/adoption. Existing plugin suites cover storage,
exports, browser recovery, transport fakes and bundled extractors.

JavaScriptCore still cannot interrupt a synchronous infinite loop; caller
budgets do not reclaim the executing thread. Node child isolation is a timeout
boundary, not an OS sandbox. The harness approximates article extraction,
network behavior and Model validation; native validation remains authoritative.
No live delivery, reader hardware or upstream extraction was verified. No
physical iPhone automation was used. The updated public-reference artifact
`site/dist/p1` is committed locally; the website has not been deployed.

## Verification

- `npm test --prefix tools/plugin-sim`: runtime/CLI regressions, 57 manifest cases,
  775 UTF-8 cases, 108 HTML/text cases, all bundled registrations, starter
  fixtures and TypeScript checks passed.
- `npm audit --prefix tools/plugin-sim --audit-level=moderate`: zero vulnerabilities.
- Native iOS 26.2: 75 plugin/handoff classes, 696 tests selected. The final broad
  run passed 695 and recorded one process crash in
  `XTranscriptPluginTests.testTheVideoIsTheSourceAndThePostTextLeads`.
  The entire X transcript class (4 tests) passed in the immediate isolated rerun.
  Focused runtime, Safari, manifest, Model, bridge and prompt checks also passed.
- The crash stack enters JavaScriptCore `JSRopeString::resolveRope` from regexp
  testing during a plugin hook. Its cause has not been established; it remains
  an intermittent verification limitation, not a clean broad-suite pass.
  Result bundle: `/tmp/luna-plugin-audit-dd/Logs/Test/Test-Luna-2026.09.29_15-57-27-+1000.xcresult`.
  Crash report: `/Users/hsp/Library/Logs/DiagnosticReports/Luna-2026-09-29-155815.ips`.
