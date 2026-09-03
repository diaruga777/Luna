#!/usr/bin/env node
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, rmSync, mkdirSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

const root = path.dirname(new URL(import.meta.url).pathname);
const run = path.join(root, "run.mjs");
const temp = mkdtempSync(path.join(os.tmpdir(), "luna-plugin-sim-"));
function invoke(args) {
  const result = spawnSync(process.execPath, [run, ...args], { encoding: "utf8" });
  let report;
  try { report = JSON.parse(result.stdout); } catch { throw new Error(`${result.stderr}\n${result.stdout}`); }
  return { result, report };
}
const header = (id, extra = "") => `/* luna-plugin\n{"id":"${id}","name":"Test","version":"1.0.0","api":1,${extra}}\n*/\n`;
try {
  const ingest = path.join(temp, "ingest.js");
  writeFileSync(ingest, header("test.ingest", `"produces":["article"],"match":{"hosts":["example.com"]},"capabilities":["fetch"]`) + `luna.register({ classify: () => ({kind:"article"}), ingest: async ({url}) => { const r = await luna.fetch(url); return {kind:"article", title:"Fixture", html:r.text}; } });`);
  assert.equal(invoke(["validate", ingest]).report.ok, true);
  const fixture = path.join(temp, "fixture");
  const responsePath = path.join(fixture, "index.response.json");
  mkdirSync(fixture);
  writeFileSync(responsePath, JSON.stringify({ status: 403, headers: { "content-type": "text/html" }, body: "blocked" }));
  const tested = invoke(["test", ingest, "https://example.com/", "--fixture", fixture]);
  assert.equal(tested.report.ok, true);
  assert.equal(tested.report.result.ingest.html, "blocked");

  const exportPlugin = path.join(temp, "export.js");
  writeFileSync(exportPlugin, header("test.export", `"export":{"kinds":["article"],"input":"text","title":"Send"}`) + `luna.register({ export: async () => ({text:"sent"}) });`);
  const exported = invoke(["test", exportPlugin, "https://example.com/a", "--hook", "export"]);
  assert.equal(exported.report.ok, true);
  assert.equal(exported.report.result.value.text, "sent");

  const badMarker = path.join(temp, "bad.js");
  writeFileSync(badMarker, header("test.bad").replace("luna-plugin", "luna-plugin-evil"));
  assert.equal(invoke(["validate", badMarker]).report.ok, false);

  const hung = path.join(temp, "hung.js");
  writeFileSync(hung, header("test.hung") + `while (true) {}\nluna.register({});`);
  const timeout = invoke(["validate", hung, "--timeout", "100"]);
  assert.equal(timeout.report.ok, false);
  assert.match(timeout.report.errors[0], /timed out/);
  console.log("plugin-sim tests passed");
} finally {
  rmSync(temp, { recursive: true, force: true });
}
