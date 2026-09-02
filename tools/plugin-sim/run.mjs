#!/usr/bin/env node
// run.mjs
//
// node tools/plugin-sim/run.mjs <plugin.js> <url> [--fixture dir] [--hook classify|ingest]
//
// Loads one plugin file under the Node bridge (bridge.mjs) and prints its
// `classify` verdict and, when it claims the URL, its `ingest` Model — for a
// plugin author (or an implementation agent) iterating in seconds instead of
// through `xcodebuild` (claudedocs/plans/plugin-platform.md §13.4). This is a
// convenience tool, not a test gate; `spec.mjs` is the one with a pass/fail
// exit code.
//
// `--fixture <dir>` answers every `luna.fetch` from a file in that directory
// instead of the network: a request URL matches a file whose basename (no
// extension) equals either the URL's last path segment or its host+path with
// `/`/`?` turned into `_`. Record a fixture once, then iterate offline.

import { readFileSync, existsSync, readdirSync } from "node:fs";
import path from "node:path";
import { createBridge } from "./bridge.mjs";

function parseHeader(source) {
  const match = source.match(/^\s*\/\*\s*luna-plugin\s*\n([\s\S]*?)\*\//);
  if (!match) throw new Error("no /* luna-plugin ... */ header at the top of the file");
  return JSON.parse(match[1]);
}

function parseArgs(argv) {
  const args = { fixture: null, hook: null, positional: [] };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--fixture") args.fixture = argv[++i];
    else if (argv[i] === "--hook") args.hook = argv[++i];
    else args.positional.push(argv[i]);
  }
  return args;
}

/// A fixture file for `url`, or null. Two names are tried: the URL's last
/// path segment, and its host+path with `/`/`?` folded to `_` — whichever the
/// fixture was saved under.
function fixtureFile(fixtureDir, url) {
  if (!fixtureDir || !existsSync(fixtureDir)) return null;
  const parsed = new URL(url);
  const candidates = new Set([
    path.basename(parsed.pathname) || "index",
    `${parsed.hostname}${parsed.pathname}${parsed.search}`.replace(/[\/?&=]/g, "_"),
  ]);
  for (const file of readdirSync(fixtureDir)) {
    if (candidates.has(path.parse(file).name)) {
      return readFileSync(path.join(fixtureDir, file), "utf8");
    }
  }
  return null;
}

function fixtureFetch(fixtureDir) {
  return async (requestUrl) => {
    const body = fixtureFile(fixtureDir, String(requestUrl));
    if (body === null) throw new Error(`no fixture for ${requestUrl} under ${fixtureDir}`);
    return {
      ok: true, status: 200, url: String(requestUrl), redirected: false,
      headers: new Map(),
      async arrayBuffer() { return Buffer.from(body, "utf8"); },
    };
  };
}

async function main() {
  const { positional, fixture, hook } = parseArgs(process.argv.slice(2));
  const [pluginPath, url] = positional;
  if (!pluginPath || !url) {
    console.error("usage: node run.mjs <plugin.js> <url> [--fixture dir] [--hook classify|ingest]");
    process.exitCode = 2;
    return;
  }

  const source = readFileSync(pluginPath, "utf8");
  const manifest = parseHeader(source);
  console.log(`plugin: ${manifest.id} v${manifest.version} (api ${manifest.api})`);

  const luna = createBridge({
    pluginId: manifest.id, version: manifest.version, capabilities: manifest.capabilities || [],
    settingsSchema: manifest.settings,
    fetchImpl: fixture ? fixtureFetch(fixture) : undefined,
  });
  const factory = new Function("luna", `${source}\nreturn luna.__registeredHooks;`);
  const hooks = factory(luna);
  if (!hooks) throw new Error("the plugin never called luna.register");

  const runClassify = hook !== "ingest";
  const runIngest = hook !== "classify";

  let claim = null;
  if (runClassify) {
    if (!hooks.classify) throw new Error("the plugin declares no classify hook");
    claim = await hooks.classify({ url, context: "app" });
    console.log("classify:", JSON.stringify(claim, null, 2));
  }

  if (runIngest && hooks.ingest) {
    const ingestClaim = claim && claim.kind
      ? { kind: claim.kind, itemId: claim.itemId }
      : { kind: manifest.produces?.[0] || "article" };
    if (hook === "ingest" || claim) {
      const model = await hooks.ingest({
        url, claim: ingestClaim, context: "app", reason: "save",
      });
      console.log("ingest:", JSON.stringify(model, null, 2));
    }
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
