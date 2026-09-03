#!/usr/bin/env node
// Process-bounded plugin simulator. See README for `validate` and `test`.

import { readFileSync, existsSync, readdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import { createBridge } from "./bridge.mjs";

const scriptPath = fileURLToPath(import.meta.url);
const SOURCE_LIMIT = 1024 * 1024;
const KINDS = new Set(["article", "media", "product"]);
const FORMATS = new Set([
  "url",
  "epub",
  "pdf",
  "docx",
  "markdown",
  "text",
  "html",
  "json",
  "file",
]);
const CAPS = new Set([
  "fetch",
  "html",
  "page",
  "storage",
  "secrets",
  "files",
  "crypto",
  "browser",
  "downloads",
  "settings",
  "ui",
  "mail",
  "notifications",
  "bluetooth",
  "wifi",
  "exports",
]);

export function parseHeader(source) {
  if (Buffer.byteLength(source, "utf8") > SOURCE_LIMIT)
    throw new Error(`source exceeds ${SOURCE_LIMIT / 1024} KB`);
  const opening = source.match(/^\s*\/\*/);
  if (!opening)
    throw new Error("no /* luna-plugin ... */ header at the top of the file");
  const start = opening[0].length;
  const close = source.indexOf("*/", start);
  if (close < 0)
    throw new Error("no /* luna-plugin ... */ header at the top of the file");
  const lines = source.slice(start, close).split("\n");
  if ((lines.shift() || "").trim() !== "luna-plugin")
    throw new Error("the first header line must be exactly luna-plugin");
  try {
    return JSON.parse(lines.join("\n"));
  } catch (error) {
    throw new Error(`manifest JSON is invalid: ${error.message}`);
  }
}

function manifestErrors(manifest) {
  const errors = [];
  for (const key of ["id", "name", "version", "api"])
    if (manifest?.[key] === undefined) errors.push(`${key} is required`);
  if (
    typeof manifest?.id !== "string" ||
    !/^[a-z0-9.-]+$/.test(manifest.id || "") ||
    manifest.id.startsWith(".") ||
    manifest.id.endsWith(".") ||
    manifest.id.includes("..")
  )
    errors.push("id must use lower-case letters, digits, dots and hyphens");
  if (typeof manifest?.name !== "string" && !manifest?.name?.en)
    errors.push("name must be a string or localized object with en");
  if (
    typeof manifest?.version !== "string" ||
    !/^\d+\.\d+\.\d+$/.test(manifest.version || "")
  )
    errors.push("version must look like 1.0.0");
  if (manifest?.api !== 1) errors.push("api must be 1");
  if (
    manifest?.capabilities &&
    (!Array.isArray(manifest.capabilities) ||
      manifest.capabilities.some((x) => !CAPS.has(x)))
  )
    errors.push("capabilities contains an unknown name");
  const produces = manifest?.produces;
  if (
    produces !== undefined &&
    (!Array.isArray(produces) ||
      !produces.length ||
      produces.some((x) => !KINDS.has(x)))
  )
    errors.push(
      "produces must be a non-empty list of article, media or product",
    );
  if (Array.isArray(produces) && produces.length && !manifest.match)
    errors.push("match is required for an ingest plugin");
  if (manifest?.match && typeof manifest.match !== "object")
    errors.push("match must be an object");
  if (manifest?.export) {
    const e = manifest.export;
    if (
      !Array.isArray(e.kinds) ||
      !e.kinds.length ||
      e.kinds.some((x) => !KINDS.has(x))
    )
      errors.push("export.kinds must contain valid Model kinds");
    if (!FORMATS.has(e.input)) errors.push("export.input is not supported");
    if (typeof e.title !== "string" && !e.title?.en)
      errors.push("export.title must be a string or localized object with en");
  }
  return errors;
}

function fixturePath(dir, url) {
  if (!dir || !existsSync(dir)) return null;
  const parsed = new URL(url);
  const candidates = new Set([
    path.basename(parsed.pathname) || "index",
    `${parsed.hostname}${parsed.pathname}${parsed.search}`.replace(
      /[\\/?&=]/g,
      "_",
    ),
  ]);
  for (const file of readdirSync(dir))
    if (
      candidates.has(path.parse(file).name) ||
      candidates.has(file.replace(/\.response\.json$/, ""))
    )
      return path.join(dir, file);
  return null;
}

export function fixtureFetch(dir) {
  return async (requestUrl) => {
    const file = fixturePath(dir, String(requestUrl));
    if (!file) throw new Error(`no fixture for ${requestUrl} under ${dir}`);
    const raw = readFileSync(file, "utf8");
    let response = file.endsWith(".response.json")
      ? JSON.parse(raw)
      : { body: raw };
    if (response.error) throw new Error(String(response.error));
    const bytes = Buffer.from(String(response.body ?? ""), "utf8");
    const status = response.status ?? 200;
    return {
      ok: status >= 200 && status < 300,
      status,
      url: response.url || String(requestUrl),
      redirected: !!response.redirected,
      headers: new Map(Object.entries(response.headers || {})),
      async arrayBuffer() {
        return bytes;
      },
    };
  };
}

function options(argv) {
  const out = { fixture: null, hook: null, timeout: 10_000, positional: [] };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--fixture") out.fixture = argv[++i];
    else if (argv[i] === "--hook") out.hook = argv[++i];
    else if (argv[i] === "--timeout") out.timeout = Number(argv[++i]);
    else out.positional.push(argv[i]);
  }
  return out;
}

function load(pluginPath, opts) {
  const source = readFileSync(pluginPath, "utf8");
  const manifest = parseHeader(source);
  const errors = manifestErrors(manifest);
  if (errors.length) return { source, manifest, errors, hooks: null };
  const luna = createBridge({
    pluginId: manifest.id,
    version: manifest.version,
    capabilities: manifest.capabilities || [],
    settingsSchema: manifest.settings,
    fetchImpl: opts.fixture ? fixtureFetch(opts.fixture) : undefined,
  });
  let hooks;
  try {
    hooks = new Function("luna", `${source}\nreturn luna.__registeredHooks;`)(
      luna,
    );
  } catch (error) {
    return {
      source,
      manifest,
      errors: [`source evaluation failed: ${error.message}`],
      hooks: null,
    };
  }
  if (!hooks || typeof hooks !== "object")
    errors.push("the plugin never called luna.register");
  if (manifest.produces?.length && typeof hooks?.classify !== "function")
    errors.push("ingest plugins must register classify");
  if (manifest.produces?.length && typeof hooks?.ingest !== "function")
    errors.push("ingest plugins must register ingest");
  if (manifest.export && typeof hooks?.export !== "function")
    errors.push("export declarations must register export");
  return { source, manifest, errors, hooks, luna };
}

function claimError(value, manifest) {
  if (value === false || value === null) return null;
  if (!value || typeof value !== "object" || !KINDS.has(value.kind)) {
    return "classify must return false or { kind: article|media|product }";
  }
  if (value.itemId !== undefined && typeof value.itemId !== "string")
    return "classify.itemId must be a string when provided";
  if (
    value.confidence !== undefined &&
    (typeof value.confidence !== "number" ||
      value.confidence < 0 ||
      value.confidence > 1)
  )
    return "classify.confidence must be a number from 0 to 1";
  return manifest.produces?.includes(value.kind)
    ? null
    : `classify claimed ${value.kind}, which is not in produces`;
}
function modelError(value, manifest) {
  if (value === null) return null;
  if (!value || typeof value !== "object" || !KINDS.has(value.kind)) {
    return "ingest must return null or a Model with a valid kind";
  }
  if (!manifest.produces?.includes(value.kind))
    return `ingest returned ${value.kind}, which is not in produces`;
  if (value.kind === "article") {
    if (typeof value.title !== "string" || !value.title.trim())
      return "article.title must be a non-empty string";
    if (typeof value.html !== "string" || !value.html.trim())
      return "article.html must be a non-empty string";
  } else if (value.kind === "media") {
    if (
      !Array.isArray(value.assets) ||
      value.assets.length < 1 ||
      value.assets.length > 50
    )
      return "media.assets must contain 1 to 50 assets";
    for (const asset of value.assets) {
      if (!asset || typeof asset.url !== "string" || !asset.url.trim())
        return "each media asset needs a non-empty url";
      if (!["video", "image", "gif", "audio"].includes(asset.type))
        return "each media asset needs type video, image, gif or audio";
    }
    if (value.title !== undefined && typeof value.title !== "string")
      return "media.title must be a string when provided";
  } else if (value.kind === "product") {
    if (typeof value.name !== "string" || !value.name.trim())
      return "product.name must be a non-empty string";
    if (
      !value.price ||
      typeof value.price.amount !== "string" ||
      !value.price.amount.trim() ||
      typeof value.price.currency !== "string" ||
      !value.price.currency.trim()
    )
      return "product.price needs non-empty amount and currency strings";
  }
  return null;
}
function exportError(value) {
  if (value === null) return null;
  if (!value || typeof value !== "object")
    return "export must return null or an object with file, text, url or status";
  const keys = ["file", "text", "url", "status"].filter(
    (key) => value[key] !== undefined,
  );
  if (keys.length !== 1)
    return "export result must contain exactly one of file, text, url or status";
  if (value.text !== undefined && typeof value.text !== "string")
    return "export.text must be a string";
  if (
    value.url !== undefined &&
    (typeof value.url !== "string" || !value.url.trim())
  )
    return "export.url must be a non-empty string";
  if (
    value.file !== undefined &&
    (!value.file ||
      typeof value.file.id !== "string" ||
      typeof value.file.name !== "string" ||
      typeof value.file.size !== "number")
  )
    return "export.file must be a FileHandle";
  if (
    value.status !== undefined &&
    !["sent", "failed", "retry"].includes(value.status)
  )
    return "export.status must be sent, failed or retry";
  if (value.message !== undefined && typeof value.message !== "string")
    return "export.message must be a string";
  if (value.hard !== undefined && typeof value.hard !== "boolean")
    return "export.hard must be a boolean";
  if (value.remoteName !== undefined && typeof value.remoteName !== "string")
    return "export.remoteName must be a string";
  return null;
}

function addEvent(report, phase, detail) {
  report.events.push({ phase, detail });
}

export async function evaluate(mode, pluginPath, url, opts) {
  let loaded;
  try {
    loaded = load(pluginPath, opts);
  } catch (error) {
    return { ok: false, mode, errors: [error.message], events: [] };
  }
  const report = {
    ok: loaded.errors.length === 0,
    mode,
    plugin: loaded.manifest?.id || null,
    version: loaded.manifest?.version || null,
    errors: [...loaded.errors],
    events: [],
  };
  if (loaded.manifest) addEvent(report, "manifest", "header parsed");
  if (loaded.errors.length) {
    addEvent(report, "load", "validation failed");
    return report;
  }
  addEvent(report, "load", "source evaluated and registered");
  if (mode === "validate") return report;
  const hook =
    opts.hook ||
    (loaded.manifest.export && !loaded.manifest.produces?.length
      ? "export"
      : "classify");
  try {
    addEvent(report, hook, "started");
    if (hook === "classify") {
      const value = await loaded.hooks.classify({ url, context: "app" });
      report.result = { hook, value };
      const error = claimError(value, loaded.manifest);
      if (error) report.errors.push(error);
      if (!error && value && loaded.hooks.ingest) {
        const model = await loaded.hooks.ingest({
          url,
          claim: { kind: value.kind, itemId: value.itemId },
          context: "app",
          reason: "save",
        });
        report.result.ingest = model;
        const modelIssue = modelError(model, loaded.manifest);
        if (modelIssue) report.errors.push(modelIssue);
      }
    } else if (hook === "ingest") {
      const value = await loaded.hooks.ingest({
        url,
        claim: { kind: loaded.manifest.produces?.[0] || "article" },
        context: "app",
        reason: "save",
      });
      report.result = { hook, value };
      const error = modelError(value, loaded.manifest);
      if (error) report.errors.push(error);
    } else if (hook === "export") {
      const value = await loaded.hooks.export({
        kind: loaded.manifest.export?.kinds?.[0] || "article",
        format: loaded.manifest.export?.input || "text",
        saveId: "00000000-0000-0000-0000-000000000000",
        url,
        title: "Fixture",
        text: "Fixture text",
        json: {},
      });
      report.result = { hook, value };
      const error = exportError(value);
      if (error) report.errors.push(error);
    } else report.errors.push(`unsupported hook ${hook}`);
    addEvent(
      report,
      hook,
      report.errors.length ? "completed with validation errors" : "completed",
    );
  } catch (error) {
    addEvent(report, hook, "threw an error");
    report.errors.push(`${hook} failed: ${error.message}`);
  }
  report.ok = report.errors.length === 0;
  return report;
}

function bounded(mode, pluginPath, url, opts) {
  return new Promise((resolve) => {
    const args = [
      scriptPath,
      "--child",
      mode,
      pluginPath,
      ...(url ? [url] : []),
      ...(opts.fixture ? ["--fixture", opts.fixture] : []),
      ...(opts.hook ? ["--hook", opts.hook] : []),
    ];
    const child = spawn(process.execPath, args, {
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "",
      stderr = "",
      timedOut = false;
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    const timer = setTimeout(
      () => {
        timedOut = true;
        child.kill("SIGKILL");
      },
      Math.max(1, opts.timeout),
    );
    child.on("close", () => {
      clearTimeout(timer);
      if (timedOut)
        resolve({
          ok: false,
          mode,
          errors: [`timed out after ${opts.timeout} ms`],
          events: [],
        });
      else {
        try {
          resolve(JSON.parse(stdout));
        } catch {
          resolve({
            ok: false,
            mode,
            errors: [stderr.trim() || "validator child returned no JSON"],
            events: [],
          });
        }
      }
    });
  });
}

async function main() {
  const argv = process.argv.slice(2);
  if (argv[0] === "--child") {
    const opts = options(argv.slice(3));
    const report = await evaluate(
      argv[1],
      argv[2],
      argv[3]?.startsWith("--") ? null : argv[3],
      opts,
    );
    process.stdout.write(`${JSON.stringify(report)}\n`);
    process.exitCode = report.ok ? 0 : 1;
    return;
  }
  const mode =
    argv[0] === "validate" || argv[0] === "test" ? argv.shift() : "run";
  const opts = options(argv);
  const [pluginPath, url] = opts.positional;
  if (!pluginPath || (mode === "test" && !url)) {
    console.error(
      "usage: run.mjs validate <plugin.js> [--timeout ms]\n       run.mjs test <plugin.js> <url> [--fixture dir] [--hook classify|ingest|export]\n       run.mjs <plugin.js> <url> [--fixture dir] [--hook classify|ingest]",
    );
    process.exitCode = 2;
    return;
  }
  if (mode !== "run") {
    const report = await bounded(mode, pluginPath, url, opts);
    console.log(JSON.stringify(report, null, 2));
    process.exitCode = report.ok ? 0 : 1;
    return;
  }
  const loaded = load(pluginPath, opts);
  if (loaded.errors.length) throw new Error(loaded.errors.join("; "));
  console.log(
    `plugin: ${loaded.manifest.id} v${loaded.manifest.version} (api ${loaded.manifest.api})`,
  );
  const hook = opts.hook || "classify";
  if (hook === "classify") {
    const claim = await loaded.hooks.classify({ url, context: "app" });
    console.log("classify:", JSON.stringify(claim, null, 2));
    if (claim && loaded.hooks.ingest)
      console.log(
        "ingest:",
        JSON.stringify(
          await loaded.hooks.ingest({
            url,
            claim,
            context: "app",
            reason: "save",
          }),
          null,
          2,
        ),
      );
  } else if (hook === "ingest")
    console.log(
      "ingest:",
      JSON.stringify(
        await loaded.hooks.ingest({
          url,
          claim: { kind: loaded.manifest.produces?.[0] || "article" },
          context: "app",
          reason: "save",
        }),
        null,
        2,
      ),
    );
  else if (hook === "export")
    console.log(
      "export:",
      JSON.stringify(
        await loaded.hooks.export({
          kind: loaded.manifest.export?.kinds?.[0] || "article",
          format: loaded.manifest.export?.input || "text",
          saveId: "00000000-0000-0000-0000-000000000000",
          url,
          title: "Fixture",
          text: "Fixture text",
          json: {},
        }),
        null,
        2,
      ),
    );
  else throw new Error(`unsupported hook ${hook}`);
}

main().catch((error) => {
  console.error(error.message || error);
  process.exitCode = 1;
});
