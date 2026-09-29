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

  // The manifest rules come from PluginManifestRules.json, so a limit the
  // parser enforces is enforced here too rather than only in Swift.
  const longName = path.join(temp, "long-name.js");
  writeFileSync(
    longName,
    `/* luna-plugin\n{"id":"test.longname","name":"${"n".repeat(41)}","version":"1.0.0","api":1}\n*/\n` +
      "luna.register({});",
  );
  const longNameResult = invoke(["validate", longName]);
  assert.equal(longNameResult.report.ok, false);
  assert.match(longNameResult.report.errors[0], /at most 40 characters/);

  // `luna.fetch.json` is the sugar over `luna.fetch`: a GET whose body is
  // parsed, and a non-2xx rejecting `fetch-failed` with the status.
  const jsonFixture = path.join(temp, "json-fixture");
  mkdirSync(jsonFixture);
  writeFileSync(
    path.join(jsonFixture, "clip.response.json"),
    JSON.stringify({
      status: 200,
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ mp4: "https://cdn.test/a.mp4", title: "Clip" }),
    }),
  );
  const sugar = path.join(temp, "sugar.js");
  writeFileSync(
    sugar,
    header(
      "test.sugar",
      `"produces":["media"],"match":{"hosts":["example.com"]},"capabilities":["fetch"]`,
    ) +
      `luna.register({ classify: () => ({kind:"media"}), ingest: async ({url}) => { const info = await luna.fetch.json(url); return {kind:"media", title: info.title, assets:[{url: info.mp4, type:"video"}]}; } });`,
  );
  const sugarResult = invoke([
    "test",
    sugar,
    "https://example.com/clip",
    "--fixture",
    jsonFixture,
  ]);
  assert.equal(sugarResult.report.ok, true);
  assert.equal(sugarResult.report.result.ingest.title, "Clip");

  const sugarFail = path.join(temp, "sugar-fail.js");
  writeFileSync(
    sugarFail,
    header(
      "test.sugarfail",
      `"produces":["article"],"match":{"hosts":["example.com"]},"capabilities":["fetch"]`,
    ) +
      `luna.register({ classify: () => ({kind:"article"}), ingest: async ({url}) => { try { await luna.fetch.text(url); } catch (e) { return {kind:"article", title:e.code, html:"<p>"+e.message+"</p>"}; } return null; } });`,
  );
  const sugarFailResult = invoke([
    "test",
    sugarFail,
    "https://example.com/",
    "--fixture",
    fixture,
  ]);
  assert.equal(sugarFailResult.report.ok, true);
  assert.equal(sugarFailResult.report.result.ingest.title, "fetch-failed");
  assert.match(sugarFailResult.report.result.ingest.html, /403/);

  const badMarker = path.join(temp, "bad.js");
  writeFileSync(
    badMarker,
    header("test.bad").replace("luna-plugin", "luna-plugin-evil"),
  );
  assert.equal(invoke(["validate", badMarker]).report.ok, false);

  // The CLI must exercise the same host filter and JSON boundary as Luna.
  const mismatch = invoke(["test", ingest, "https://other.example/"]);
  assert.equal(mismatch.report.ok, false);
  assert.match(mismatch.report.errors[0], /does not match/);
  for (const body of [
    "const x = {}; x.self = x; return x;",
    "return {value: 1n};",
    "return {get then() {throw new Error('bad then');}};",
    "throw 'plain error';",
  ]) {
    const broken = path.join(temp, "boundary.js");
    writeFileSync(broken, header("test.boundary", '"produces":["article"],"match":{"any":true}')
      + `luna.register({classify() { ${body} }, ingest() { return null; }});`);
    const report = invoke(["test", broken, "https://example.com/"]).report;
    assert.equal(report.ok, false, body);
    assert.match(report.errors[0], /classify failed/, body);
  }
  const document = path.join(temp, "document.js");
  writeFileSync(document, header("test.document", '"produces":["article"],"match":{"any":true}')
    + `luna.register({classify: () => ({kind:"article"}), ingest: () => ({kind:"article",title:"Guide",document:{url:"/guide.pdf",type:"pdf"}})});`);
  assert.equal(invoke(["test", document, "https://example.com/"]).report.ok, true);
  const bluetooth = path.join(temp, "bluetooth.js");
  writeFileSync(bluetooth, header("test.bluetooth", '"bluetooth":{"services":["123"]},"capabilities":["bluetooth"]') + "luna.register({});");
  assert.match(invoke(["validate", bluetooth]).report.errors[0], /onBluetooth/);
  for (const args of [["--timeout"], ["--timeout", "NaN"], ["--timeout", "0"], ["--hook", "typo"], ["--typo"]]) {
    const result = spawnSync(process.execPath, [run, "validate", control, ...args], {encoding:"utf8"});
    assert.notEqual(result.status, 0, args.join(" "));
    assert.ok(result.stderr.trim(), args.join(" "));
  }

  const hung = path.join(temp, "hung.js");
  writeFileSync(
    hung,
    header("test.hung") + `while (true) {}\nluna.register({});`,
  );
  const timeout = invoke(["validate", hung, "--timeout", "2500"]);
  assert.equal(timeout.report.ok, false);
  assert.match(timeout.report.errors[0], /timed out/);
  const defaultTimeout = invoke([hung, "https://example.com/", "--timeout", "1000"]);
  assert.equal(defaultTimeout.report.ok, false);
  assert.match(defaultTimeout.report.errors[0], /timed out/);
  console.log("plugin-sim tests passed");
} finally {
  rmSync(temp, { recursive: true, force: true });
}
