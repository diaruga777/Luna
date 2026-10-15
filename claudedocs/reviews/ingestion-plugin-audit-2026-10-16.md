# Ingestion plugin ownership audit — October 16, 2026

Reviewed the preceding 48 hours of commits through `d40095d13` (October 14–16,
Australia/Sydney), including the full diffs of ingestion-related Swift changes.
No publisher extraction or recovery rule from those fixes needs moving out of
Swift: all six changes below are in `docs/plugins/lib/access.js`, embedded in
the shipping `LunaBundledPlugins/Plugins/publisher-access.js`.

| Commit | Plugin-owned behavior |
| --- | --- |
| `7eb583f2a` | Return the first readable crawler/archive probe instead of waiting for stalled siblings. |
| `b2df5f04f` | Select Daily Beast Astro editorial blocks marked `tdb-paywall`. |
| `6502c2e95` | Route WSJ recovery to archives; detect archive challenges and readable roots. |
| `96cbfafce` | Resolve archive snapshots using TimeMap. |
| `d18b5c2a3` | Establish the archive session via its homepage before loading a snapshot. |
| `c02461812` | Recover verified WSJ syndication, check canonical identity, and select Mint continuation paragraphs. |

The associated Swift changes stay within the host's responsibilities:

- `bc88815c4`: retry the currently installed plugin on unlock, preserving save
  identity and clearing obsolete browser requests after successful recovery.
- `3629b0c79`, `3b9c3eff3`: preserve recoverable locks and checkpoint browser
  requests across cancellation, failed capture, and process termination.
- `dcc49f51f`, `d53ae3120`: bound page capture, ignore late callbacks, and keep
  one modal during plugin execution and browser steps. The host executes the
  plugin-supplied detection/cleanup scripts without choosing publisher rules.
- `bea4b345f`: cache immutable bundled manifests while retaining fresh enabled
  state and live directory-backed catalogs.

No recent changes touched the legacy native article extraction/paywall modules.
Other Swift changes in the window concern reader/library UI, local indexing,
mail transport/import, music/podcasts, Bluetooth restoration, or launch work;
they do not introduce publisher interpretation into the plugin host.

## New Yorker regression

The reported Cookie Monster page has an unmarked opening paragraph followed by
21 paragraphs marked `paywall`. Its JSON-LD body starts at the second paragraph.
The existing generic interpreter discarded each short marked paragraph and
accepted the incomplete JSON-LD body. This was reproduced on the fetched page.

Web 1.1.2 and publisher access 1.0.7 embed the same publisher-specific
`docs/plugins/lib/newyorker.js` helper. It normalizes only New Yorker's editorial
paragraph marker, keeps all article chunks, and preserves the remaining attributes
and markup. Ordinary saves reach web first; publisher recovery alone would not
repair that path. Owner refreshes also use web's normalization. The generic
interpreter and Swift production sources are unchanged. A synthetic
fixture models the omitted JSON-LD opening, multiple chunks, inline links/images,
hidden paragraphs, unrelated page furniture, and an actual subscription notice.

Validation commands:

```sh
cd tools/plugin-sim && npm test
TEST_RUNNER_LUNA_NEWYORKER_LIVE_FIXTURE=1 scripts/run_tests.sh -d <iOS-26.2-simulator> -- \
  -only-testing:LunaTests/WebPluginMigrationTests \
  -only-testing:LunaTests/PluginBrowserBridgeTests \
  -only-testing:LunaTests/PluginResumeTests \
  -only-testing:LunaTests/PluginBrowserViewControllerTests
```

The opt-in live regression reads a fresh capture at
`/tmp/luna-newyorker-cookie.html`; the copyrighted full page is not committed.
The permanent fixture uses synthetic prose. The Node regression covers both
plugins with captured pages and initial fetches in app/share/Safari hook contexts.
The iOS regression runs shipping plugins through the actual JavaScriptCore/SwiftSoup
bridge, including the normal ordered plugin walk, native model adoption, and a
saved-content read-back to verify the opening survives persistence.

Results: the complete Node harness passed (including 109 HTML/text parity cases).
The selected iOS 26.2 suites ran 48 tests with zero failures and one opt-in WSJ
live-capture skip; the New Yorker live-capture test ran and passed. A fresh save
through the running simulator app also persisted 22 paragraphs under `app.luna.web`,
with the correct first and second paragraphs, and displayed the restored opening
in the reader. Existing saved articles are not automatically rewritten by a
bundled-plugin update.
