# luna-plugin-sim

A Node harness for iterating on a Luna plugin outside Xcode
(`claudedocs/plans/plugin-platform.md` §13.4). It implements the `luna.*`
bridge (`bridge.mjs`) with `undici` for `luna.fetch`, `linkedom` for
`luna.html`, in-memory maps for `luna.storage`/`luna.settings`, and no
`luna.browser` at all (there is no page to run a challenge detector against
outside a real WebKit process — a plugin sees the same `unavailable-here`
rejection the Safari content-script world gives when it defers).

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
node run.mjs <plugin.js> <url> --fixture ./fixtures/some-platform
```

Prints the `classify` verdict and, when it claims the URL, the `ingest`
Model as JSON.

`--fixture <dir>` answers every `luna.fetch` from a file in that directory
instead of hitting the network — record a page once (`curl` it into the
directory under a name matching either its URL's last path segment or its
host+path with `/`/`?`/`&`/`=` turned into `_`), then iterate on the plugin
offline.

## `luna.html` parity

```sh
node spec.mjs
```

Runs `LunaTests/Fixtures/Plugins/html-subset.spec.js` — the same file
`PluginHTMLSubsetTests` (SwiftSoup) and `PluginHTMLParityTests` (`plugin_host
.js`'s `DOMParser`) run — against this package's `linkedom` backing. A
disagreement is a defect in one of the three backings, never a reason to
special-case a plugin.

## Typings

`luna-plugin.d.ts` is the `luna.*` API surface (§3–§6), shipped with the
authoring docs under `docs/plugins/`. Reference it from a plugin file for
editor checking:

```js
/// <reference path="../../tools/plugin-sim/luna-plugin.d.ts" />
```

## What is NOT here

- `luna.browser`, `luna.secrets`, `luna.files`, `luna.ui`, `luna.mail`,
  `luna.notifications`, `luna.bluetooth`, `luna.wifi`, `luna.exports`,
  `luna.downloads` — app-only or WebKit-only capabilities with no Node
  equivalent. `bridge.mjs` simply never installs them, matching how an
  undeclared capability is absent everywhere else.
- A `classify`/`ingest` timeout or three-strikes disable — this harness runs
  one call at a time and lets a hang hang, so you see the real error instead
  of a manufactured one.
