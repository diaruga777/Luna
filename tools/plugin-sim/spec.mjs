// spec.mjs
//
// Runs the shared `html-subset.spec.js` against the `linkedom` backing — the
// third leg of the parity triangle: `PluginHTMLSubsetTests` runs it against
// SwiftSoup in JavaScriptCore, `PluginHTMLParityTests` against `plugin_host
// .js`'s `DOMParser` backing in a WKWebView, and this file against the one
// this Node harness uses (claudedocs/plans/plugin-platform.md §6.3, §13.3,
// §13.4). Not a build gate — run it by hand: `node tools/plugin-sim/spec.mjs`.

import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { html } from "./bridge.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const specPath = path.join(here, "..", "..", "LunaTests", "Fixtures", "Plugins", "html-subset.spec.js");
const specSource = readFileSync(specPath, "utf8");

// The spec file evaluates to the case list — the same contract every runner
// (Swift, WKWebView, here) relies on.
// eslint-disable-next-line no-eval
const cases = eval(specSource);

const DEFAULT_BASE = "https://example.com/dir/page.html";
let failures = 0;

for (const testCase of cases) {
  try {
    const doc = html.parse(testCase.html, testCase.baseURL || DEFAULT_BASE);
    const run = new Function("doc", "luna", testCase.script);
    const answer = run(doc, { html });
    const got = JSON.stringify(answer === undefined ? null : answer);
    const want = JSON.stringify(testCase.expected === undefined ? null : testCase.expected);
    if (got !== want) {
      failures += 1;
      console.error(`FAIL ${testCase.name}: got ${got}, want ${want}`);
    }
  } catch (error) {
    failures += 1;
    console.error(`FAIL ${testCase.name}: threw ${error}`);
  }
}

console.log(`${cases.length - failures}/${cases.length} cases passed`);
process.exitCode = failures ? 1 : 0;
