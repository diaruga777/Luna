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
npm install
```

## Running a plugin

```sh
node run.mjs <plugin.js> <url>
node run.mjs <plugin.js> <url> --hook classify   # classify only
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

The first form prints the `classify` verdict and, when it claims the URL, the
`ingest` Model as JSON. `validate` and `test` print one structured JSON report
and exit non-zero when the manifest, registration, hook result, or timeout is
invalid. They evaluate the plugin in a child process and kill that process at
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

## `luna.html.article` is APPROXIMATE here

The app runs Luna's own `ArticleExtractor` (SwiftSoup) behind
`luna.html.article`, and the Safari content world relays the call to that same
native code. There is no port of that pass to Node, so this harness substitutes
`@mozilla/readability`. Expect a different `html` string, a different
`excerpt`, and sometimes a different verdict on a borderline page. Use the
harness to check that your plugin CALLS the helper and handles `null`
correctly; never compare its output to the app's.

`luna.html.article` answers a `Promise` in every process, here included: Safari
has to relay it, so a synchronous shape could not hold everywhere.

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

`run.mjs` does not carry its own copy of the manifest limits. It reads
`LunaLibraries/Sources/LunaPluginKit/Resources/PluginManifestRules.json`, the
same file the app bundles, and `PluginManifestRulesParityTests` pins that file
to `PluginManifestParser`'s own constants. So a name this harness accepts is a
name the app accepts.

## Typings

`luna-plugin.d.ts` is the `luna.*` API surface (§3–§6), shipped with the
authoring docs under `docs/plugins/`. Reference it from a plugin file for
editor checking:

```js
/// <reference path="../../tools/plugin-sim/luna-plugin.d.ts" />
```

## What is NOT here

- `luna.browser` — declared but always rejects `unavailable-here`; see above.
- `luna.secrets`, `luna.ui`, `luna.mail`, `luna.notifications`,
  `luna.bluetooth`, `luna.wifi`, `luna.exports` — app-only or WebKit-only
  capabilities with no Node equivalent. `bridge.mjs` simply never installs
  them, matching how an undeclared capability is absent everywhere else.
- A three-strikes disable — the `validate`/`test` parent kills a child at its
  deadline and reports a timeout; production's JavaScriptCore policy remains
  Luna's responsibility.
