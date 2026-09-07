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
  const result = spawnSync(process.execPath, [run, ...args], {
    encoding: "utf8",
  });
  let report;
  try {
    report = JSON.parse(result.stdout);
  } catch {
    throw new Error(`${result.stderr}\n${result.stdout}`);
  }
  return { result, report };
}
const header = (id, extra = "") => {
  const fields = [
    `"id":"${id}"`,
    `"name":"Test"`,
    `"version":"1.0.0"`,
    `"api":1`,
  ];
  if (extra) fields.push(extra);
  return `/* luna-plugin\n{${fields.join(",")}}\n*/\n`;
};
try {
  const ingest = path.join(temp, "ingest.js");
  writeFileSync(
    ingest,
    header(
      "test.ingest",
      `"produces":["article"],"match":{"hosts":["example.com"]},"capabilities":["fetch"]`,
    ) +
      `luna.register({ classify: () => ({kind:"article"}), ingest: async ({url}) => { const r = await luna.fetch(url); return {kind:"article", title:String(r.ok), html:r.text}; } });`,
  );
  assert.equal(invoke(["validate", ingest]).report.ok, true);
  const control = path.join(temp, "control.js");
  writeFileSync(control, header("test.control") + "luna.register({});");
  assert.equal(
    invoke(["validate", control, "--timeout", "1500"]).report.ok,
    true,
  );
  const finite = path.join(temp, "finite.js");
  writeFileSync(
    finite,
    header("test.finite") +
      "for (let i = 0; i < 1e6; i++) {}\nluna.register({});",
  );
  assert.equal(
    invoke(["validate", finite, "--timeout", "1500"]).report.ok,
    true,
  );
  const fixture = path.join(temp, "fixture");
  const responsePath = path.join(fixture, "index.response.json");
  mkdirSync(fixture);
  writeFileSync(
    responsePath,
    JSON.stringify({
      status: 403,
      ok: true,
      headers: { "content-type": "text/html" },
      body: "blocked",
    }),
  );
  const tested = invoke([
    "test",
    ingest,
    "https://example.com/",
    "--fixture",
    fixture,
  ]);
  assert.equal(tested.report.ok, true);
  assert.equal(tested.report.result.ingest.title, "false");
  assert.equal(tested.report.result.ingest.html, "blocked");
  assert.ok(tested.report.events.some((event) => event.phase === "classify"));

  const badModel = path.join(temp, "bad-model.js");
  writeFileSync(
    badModel,
    header(
      "test.bad-model",
      `"produces":["article"],"match":{"hosts":["example.com"]}`,
    ) +
      `luna.register({ classify: () => ({kind:"article"}), ingest: () => ({kind:"article",title:"",html:""}) });`,
  );
  const badModelResult = invoke(["test", badModel, "https://example.com/"]);
  assert.equal(badModelResult.report.ok, false);
  assert.match(badModelResult.report.errors[0], /article.title/);

  const badCookie = path.join(temp, "bad-cookie.js");
  writeFileSync(
    badCookie,
    header(
      "test.bad-cookie",
      `"produces":["article"],"match":{"hosts":["example.com"]},"capabilities":["fetch"]`,
    ) +
      `luna.register({ classify: () => ({kind:"article"}), ingest: async ({url}) => { await luna.fetch({url,cookies:"browser"}); return null; } });`,
  );
  const badCookieResult = invoke([
    "test",
    badCookie,
    "https://example.com/",
    "--fixture",
    fixture,
  ]);
  assert.equal(badCookieResult.report.ok, false);
  assert.match(badCookieResult.report.errors[0], /cookies/);

  // A transcript plugin: `--intent transcribe` reaches classify, and an
  // article Model may carry a `transcription` spec in place of `html`.
  const transcript = path.join(temp, "transcript.js");
  writeFileSync(
    transcript,
    header(
      "test.transcript",
      `"produces":["article"],"match":{"hosts":["example.com"]}`,
    ) +
      `luna.register({ classify: ({intent}) => ({kind:"article", itemId: intent || "none"}), ingest: async ({url, intent}) => ({kind:"article", title: intent || "plain", transcription:{url: url, type:"audio", expiresAt: 4102444800}}) });`,
  );
  const transcribed = invoke([
    "test",
    transcript,
    "https://example.com/talk.mp3",
    "--intent",
    "transcribe",
  ]);
  assert.equal(transcribed.report.ok, true);
  assert.equal(transcribed.report.result.value.itemId, "transcribe");
  assert.equal(transcribed.report.result.ingest.title, "transcribe");
  assert.equal(transcribed.report.result.ingest.transcription.type, "audio");
  const plain = invoke(["test", transcript, "https://example.com/talk.mp3"]);
  assert.equal(plain.report.ok, true);
  assert.equal(plain.report.result.value.itemId, "none");
  assert.equal(plain.report.result.ingest.title, "plain");

  const badSpec = path.join(temp, "bad-spec.js");
  writeFileSync(
    badSpec,
    header(
      "test.bad-spec",
      `"produces":["article"],"match":{"hosts":["example.com"]}`,
    ) +
      `luna.register({ classify: () => ({kind:"article"}), ingest: async ({url}) => ({kind:"article", title:"t", transcription:{url: url, type:"image"}}) });`,
  );
  const badSpecResult = invoke(["test", badSpec, "https://example.com/a.mp3"]);
  assert.equal(badSpecResult.report.ok, false);
  assert.match(badSpecResult.report.errors[0], /transcription.type/);

  const bothSpecs = path.join(temp, "both-specs.js");
  writeFileSync(
    bothSpecs,
    header(
      "test.both-specs",
      `"produces":["article"],"match":{"hosts":["example.com"]}`,
    ) +
      `luna.register({ classify: () => ({kind:"article"}), ingest: async ({url}) => ({kind:"article", title:"t", document:{url: url, type:"pdf"}, transcription:{url: url, type:"video"}}) });`,
  );
  const bothSpecsResult = invoke(["test", bothSpecs, "https://example.com/a"]);
  assert.equal(bothSpecsResult.report.ok, false);
  assert.match(bothSpecsResult.report.errors[0], /document and article.transcription/);

  const exportPlugin = path.join(temp, "export.js");
  writeFileSync(
    exportPlugin,
    header(
      "test.export",
      `"export":{"kinds":["article"],"input":"text","title":"Send"}`,
    ) + `luna.register({ export: async () => ({text:"sent"}) });`,
  );
  const exported = invoke([
    "test",
    exportPlugin,
    "https://example.com/a",
    "--hook",
    "export",
  ]);
  assert.equal(exported.report.ok, true);
  assert.equal(exported.report.result.value.text, "sent");
  const badExport = path.join(temp, "bad-export.js");
  writeFileSync(
    badExport,
    header(
      "test.bad-export",
      `"export":{"kinds":["article"],"input":"text","title":"Send"}`,
    ) + `luna.register({ export: async () => ({text:4}) });`,
  );
  const badExportResult = invoke([
    "test",
    badExport,
    "https://example.com/a",
    "--hook",
    "export",
  ]);
  assert.equal(badExportResult.report.ok, false);
  assert.match(badExportResult.report.errors[0], /export.text/);

  const badMarker = path.join(temp, "bad.js");
  writeFileSync(
    badMarker,
    header("test.bad").replace("luna-plugin", "luna-plugin-evil"),
  );
  assert.equal(invoke(["validate", badMarker]).report.ok, false);

  const hung = path.join(temp, "hung.js");
  writeFileSync(
    hung,
    header("test.hung") + `while (true) {}\nluna.register({});`,
  );
  const timeout = invoke(["validate", hung, "--timeout", "2500"]);
  assert.equal(timeout.report.ok, false);
  assert.match(timeout.report.errors[0], /timed out/);
  console.log("plugin-sim tests passed");
} finally {
  rmSync(temp, { recursive: true, force: true });
}
