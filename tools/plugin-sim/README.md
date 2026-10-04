# luna-plugin-sim

A Node harness for iterating on a Luna plugin outside Xcode
(`claudedocs/plans/plugin-platform.md` §13.4). It implements the `luna.*`
bridge (`bridge.mjs`) with `undici` for `luna.fetch`, `linkedom` for
`luna.html` and `luna.text`, `@mozilla/readability` for
`luna.html.article` (APPROXIMATE — see below), in-memory maps for
`luna.storage`/`luna.settings`/`luna.files`
(so a multipart `file` part and `as: "file"` behave the same as the app),
`luna.downloads` fed from a fixture's own job list. A declared `luna.browser`
namespace is present but always rejects `unavailable-here` (there is no page to
run a challenge detector against outside a real WebKit process).

This is a convenience tool, not a build gate. `LunaTests` and the Xcode
suites are the tests that matter; this exists so a plugin author (or an
implementation agent) sees an answer in seconds instead of a full
`xcodebuild` cycle.

## Setup

```sh
cd tools/plugin-sim
npm ci
```

## Running a plugin

```sh
node run.mjs <plugin.js> <url>
node run.mjs <plugin.js> <url> --hook classify   # classify, then ingest if claimed
node run.mjs <plugin.js> <url> --hook ingest     # ingest only, against a synthetic claim
node run.mjs <plugin.js> <url> --hook export     # export-only convenience run
node run.mjs <plugin.js> <url> --fixture ./fixtures/some-platform
node run.mjs <plugin.js> <url> --intent transcribe  # the app's Transcribe action: `intent` on the hook input
node run.mjs validate <plugin.js>                 # JSON preflight report
node run.mjs test <plugin.js> <url> --fixture ./fixtures/some-platform
```

`--intent transcribe` sets `intent: "transcribe"` on the `classify` and
`ingest` inputs, exactly as the app does for its Transcribe actions and never
otherwise (the key is absent, not null, on a plain save). A media plugin must
decline it; an `article` Model may then carry a `transcription` spec instead
of `html`, and the validator checks that spec's shape. The bundled transcript
plugins' fixture directories are under `fixtures/<platform>-transcript*/`.

The default and `test` forms use the same evaluator and report. Every command prints one structured JSON report
and exit non-zero when the manifest, registration, hook result, or timeout is
invalid. All forms evaluate the plugin in a child process and kill that process at
the deadline, so a draft with a top-level infinite loop cannot hang the shell.

`--fixture <dir>` answers every `luna.fetch` from a file in that directory
instead of hitting the network. A plain matching file is a 200 response. For
realistic failures, use the same basename with `.response.json`, for example:

```json
{"status":403,"headers":{"content-type":"text/html"},"body":"blocked"}
```

The descriptor may also set `url`, `redirected`, or `error` (a transport
failure). `ok` is always derived from the HTTP status (200–299), matching
`Response.ok`. Record a page once, then iterate on the plugin offline.

## Plugin-owned web interpretation

Executing plugins must bundle semantic extraction code. The native article/meta
and price/date helpers are retired; `docs/plugins/lib/web.js` is the source used
by bundled web and NYTimes plugins. Run `node core-migration-test.mjs` for the
recorded X video/text, article, product, wrapper and intent regressions.

## `luna.html` / `luna.text` parity

```sh
node spec.mjs
```

Runs `LunaTests/Fixtures/Plugins/html-subset.spec.js` — the same file
`PluginHTMLSubsetTests` (SwiftSoup) and `PluginHTMLParityTests` (`plugin_host
.js`'s `DOMParser`) run — against this package's `linkedom` backing. It
specifies `luna.html` and `luna.text` together, because `luna.text` rides on
the `html` capability and the same three backings answer it. A disagreement is
a defect in one of the three backings, never a reason to special-case a plugin.
`luna.html.article` is the one member NOT in the file: it is native everywhere,
so there is no page-side backing to compare.

## Manifest rules

`manifest.mjs` does not carry its own copy of the manifest limits. It reads
`LunaLibraries/Sources/LunaPluginKit/Resources/PluginManifestRules.json`, the
same file the app bundles, and `PluginManifestRulesParityTests` pins that file
to `PluginManifestParser`'s own constants. Shared acceptance fixtures also compare host patterns, translations,
settings, export formats and Bluetooth declarations with the native parser.
The full native Model decoder remains the authority for Model limits.

## Typings

`luna-plugin.d.ts` is the `luna.*` API surface (§3–§6), shipped with the
authoring docs under `docs/plugins/`. Reference it from a plugin file for
editor checking:

```js
// Place this AFTER the JSON header; adjust the path for your plugin.
/// <reference path="../../tools/plugin-sim/luna-plugin.d.ts" />
```

## What is NOT here

- `luna.browser` — declared but always rejects `unavailable-here`; see above.
- `luna.secrets`, `luna.ui`, `luna.mail`, `luna.notifications`,
  `luna.bluetooth`, `luna.wifi`, `luna.exports` — app-only or WebKit-only
  capabilities with no Node equivalent. Declared names reject `unavailable-here`; undeclared names remain absent.
- A three-strikes disable — the `validate`/`test` parent kills a child at its
  deadline and reports a timeout; production's JavaScriptCore policy remains
  Luna's responsibility.

## Checks and practical limits

Run `npm test` for runtime primitives, shared manifest cases, CLI regressions,
bundled registrations, starter fixtures, HTML/text parity and starter type checks.

`luna.fetch` timeout values are seconds (default 20, capped at 120). The
harness uses a wall-clock request deadline including body consumption and
aborts the request on expiry; the app uses an idle network deadline. CLI
`--timeout` is milliseconds and bounds the whole child process in all modes.
The child process is a timeout boundary, not an OS security sandbox: only run
plugin source you trust in Node. Browser/Node globals are not portable to JSC.

The harness checks common Model shapes, not every native field/cap. `ok:true`
with `ingest:null` is a valid decline, not successful extraction. A host
mismatch fails the run because Luna would never select that plugin.
