#!/usr/bin/env node
// Process-bounded plugin simulator. See README for `validate` and `test`.

import { readFileSync, existsSync, readdirSync } from "node:fs";
import path from "node:path";
import { inflateSync } from "node:zlib";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";

const scriptPath = fileURLToPath(import.meta.url);

import { rules as RULES, parseHeader, manifestErrors, matchesURL } from "./manifest.mjs";
export { parseHeader } from "./manifest.mjs";
const KINDS = new Set(RULES.kinds);

export function fixtureFetch(dir) {
  const files = new Map();
  if (existsSync(dir)) {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      if (!entry.isFile() && !entry.isSymbolicLink()) continue;
      const file = entry.name;
      files.set(file, file);
      const alias = path.parse(file).name;
      if (!files.has(alias)) files.set(alias, file);
    }
  }
  return async (requestUrl) => {
    const url = new URL(requestUrl);
    const specific = (url.hostname + url.pathname + url.search).replace(/[\\/?&=]/g, "_");
    const basename = path.basename(url.pathname) || "index";
    const file = files.get(specific + ".response.json") ?? files.get(specific)
      ?? files.get(basename + ".response.json") ?? files.get(basename);
    if (!file) throw new Error(`no fixture for ${requestUrl} under ${dir}`);
    const raw = readFileSync(path.join(dir, file));
    const descriptor = file.endsWith(".response.json");
    const response = descriptor ? JSON.parse(raw.toString("utf8")) : {};
    if (response.error) throw new Error(String(response.error));
    const bytes = descriptor ? Buffer.from(String(response.body ?? ""), "utf8") : raw;
    const status = response.status ?? 200;
    return {
      ok: status >= 200 && status < 300,
      status,
      url: response.url || String(requestUrl),
      redirected: !!response.redirected,
      headers: new Headers(response.headers),
      async arrayBuffer() {
        return bytes;
      },
    };
  };
}

function options(argv) {
  const out = {
    fixture: null,
    hook: null,
    intent: null,
    timeout: 10_000,
    positional: [],
  };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (["--fixture", "--hook", "--intent", "--timeout"].includes(arg)) {
      const value = argv[++i];
      if (!value || value.startsWith("--")) throw new Error(`${arg} needs a value`);
      out[arg.slice(2)] = arg === "--timeout" ? Number(value) : value;
    } else if (arg.startsWith("--")) throw new Error(`unknown option ${arg}`);
    else out.positional.push(arg);
  }
  if (!Number.isFinite(out.timeout) || out.timeout < 1 || out.timeout > 2_147_483_647)
    throw new Error("--timeout must be between 1 and 2147483647 milliseconds");
  if (out.hook && !["classify", "ingest", "export"].includes(out.hook))
    throw new Error("--hook must be classify, ingest or export");
  if (out.intent && out.intent !== "transcribe") throw new Error("--intent must be transcribe");
  return out;
}

// Same binary attachment contract as LunaFileReader; plain .js/legacy .luna
// sources remain usable during local plugin development.
function decodeSource(data) {
  const limit = 1024 * 1024;
  const maxFileBytes = limit + (limit >>> 12) + (limit >>> 14) + (limit >>> 25) + 13 + 10;
  if (data.length > maxFileBytes) throw new Error("Luna file exceeds 1 MiB");
  const signature = Buffer.from("894c554e410d0a1a0a", "hex");
  if (data.subarray(0, signature.length).equals(signature)) {
    if (data[9] !== 1) throw new Error("Unsupported Luna container version");
    const payload = data.subarray(10);
    const { buffer, engine } = inflateSync(payload, { maxOutputLength: limit, info: true });
    if (engine.bytesWritten !== payload.length) throw new Error("Trailing Luna container data");
    data = buffer;
  }
  if (data.length > limit) throw new Error("Luna source exceeds 1 MiB");
  return new TextDecoder("utf-8", { fatal: true }).decode(data);
}

async function load(pluginPath, opts) {
  const source = decodeSource(readFileSync(pluginPath));
  const manifest = parseHeader(source);
  const errors = manifestErrors(manifest);
  if (errors.length) return { source, manifest, errors, hooks: null };
  const { createBridge } = await import("./bridge.mjs");
  const luna = createBridge({
    pluginId: manifest.id,
    version: manifest.version,
    capabilities: (manifest.capabilities || []).map((name) => name.trim()),
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
  if (manifest.bluetooth && typeof hooks?.onBluetooth !== "function")
    errors.push("bluetooth declarations must register onBluetooth");
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
    (!Number.isFinite(value.confidence) ||
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
  if (value && typeof value.rewriteURL === "string") {
    try { return /^https?:$/.test(new URL(value.rewriteURL).protocol) ? null : "rewriteURL must be HTTP(S)"; }
    catch (_) { return "rewriteURL must be an absolute URL"; }
  }
  if (!value || typeof value !== "object" || !KINDS.has(value.kind)) {
    return "ingest must return null or a Model with a valid kind";
  }
  if (!manifest.produces?.includes(value.kind))
    return `ingest returned ${value.kind}, which is not in produces`;
  if (value.kind === "article") {
    if (typeof value.title !== "string" || !value.title.trim())
      return "article.title must be a non-empty string";
    const spec = value.transcription;
    if (spec !== undefined) {
      if (!spec || typeof spec !== "object")
        return "article.transcription must be an object";
      if (typeof spec.url !== "string" || !spec.url.trim())
        return "article.transcription.url must be a non-empty string";
      if (!["audio", "video"].includes(spec.type))
        return "article.transcription.type must be audio or video";
      if (spec.audioURL !== undefined && typeof spec.audioURL !== "string")
        return "article.transcription.audioURL must be a string when provided";
      if (spec.headers !== undefined && (!spec.headers || typeof spec.headers !== "object"))
        return "article.transcription.headers must be an object when provided";
      if (spec.expiresAt !== undefined && typeof spec.expiresAt !== "number")
        return "article.transcription.expiresAt must be a number (epoch seconds)";
      if (value.document !== undefined)
        return "article.document and article.transcription cannot both be set";
      if (value.html !== undefined && typeof value.html !== "string")
        return "article.html must be a string when provided";
    }
    if (value.document != null) {
      const doc = value.document;
      if (!doc || typeof doc.url !== "string" || !doc.url.trim())
        return "article.document.url must be a non-empty string";
      if (!["pdf", "epub", "docx", "rtf", "html", "md", "txt"].includes(doc.type))
        return "article.document.type is not supported";
    }
    if (value.html != null && typeof value.html !== "string") return "article.html must be a string";
    if (value.html == null && !value.document && !value.transcription)
      return "article needs html, document or transcription";
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

/// The hook argument with `intent` added ONLY when `--intent` was given — the
/// app encodes the key the same way, so an unset intent is absent, not null.
function hookInput(input, opts) {
  return opts.intent ? { ...input, intent: opts.intent } : input;
}

function addEvent(report, phase, detail) {
  report.events.push({ phase, detail });
}

export async function evaluate(mode, pluginPath, url, opts) {
  let loaded;
  try {
    loaded = await load(pluginPath, opts);
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
  // Match the native host filter, which runs before classify/ingest.
  if (hook !== "export" && !matchesURL(loaded.manifest, url)) {
    report.ok = false;
    report.errors.push("URL does not match the manifest; Luna would not run this plugin");
    return report;
  }
  // Cross the same JSON boundary as the native runtime. This also detects
  // cycles/BigInt inside the hook's error handler rather than breaking stdout.
  const invoke = async (name, input) => {
    const value = await loaded.hooks[name](input);
    return JSON.parse(JSON.stringify(value) ?? "null");
  };
  let activeHook = hook;
  try {
    addEvent(report, activeHook, "started");
    if (hook === "classify") {
      const value = await invoke("classify",
        hookInput({ url, context: "app" }, opts),
      );
      report.result = { hook, value };
      const error = claimError(value, loaded.manifest);
      if (error) report.errors.push(error);
      if (!error && value && loaded.hooks.ingest) {
        addEvent(report, "classify", "completed");
        activeHook = "ingest";
        addEvent(report, activeHook, "started");
        const model = await invoke("ingest",
          hookInput(
            {
              url,
              claim: { kind: value.kind, itemId: value.itemId },
              context: "app",
              reason: "save",
            },
            opts,
          ),
        );
        report.result.ingest = model;
        const modelIssue = modelError(model, loaded.manifest);
        if (modelIssue) report.errors.push(modelIssue);
      }
    } else if (hook === "ingest") {
      const value = await invoke("ingest",
        hookInput(
          {
            url,
            claim: { kind: loaded.manifest.produces?.[0] || "article" },
            context: "app",
            reason: "save",
          },
          opts,
        ),
      );
      report.result = { hook, value };
      const error = modelError(value, loaded.manifest);
      if (error) report.errors.push(error);
    } else if (hook === "export") {
      const value = await invoke("export", {
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
      activeHook,
      report.errors.length ? "completed with validation errors" : "completed",
    );
  } catch (error) {
    addEvent(report, activeHook, "threw an error");
    report.errors.push(`${activeHook} failed: ${error?.message ?? String(error)}`);
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
      ...(opts.intent ? ["--intent", opts.intent] : []),
    ];
    const child = spawn(process.execPath, args, {
      // stdout is reserved for the parent CLI's JSON. Both plugin log streams
      // go to stderr, while the child sends the complete report over IPC.
      stdio: ["ignore", 2, "inherit", "ipc"],
    });
    let timedOut = false;
    let report;
    child.on("message", (message) => { report = message; });
    const timer = setTimeout(
      () => {
        timedOut = true;
        child.kill("SIGKILL");
      },
      Math.max(1, opts.timeout),
    );
    child.on("error", (error) => {
      clearTimeout(timer);
      resolve({ ok: false, mode, errors: [error.message], events: [] });
    });
    child.on("close", (code, signal) => {
      clearTimeout(timer);
      if (timedOut) {
        resolve({ ok: false, mode, errors: [`timed out after ${opts.timeout} ms`], events: [] });
      } else {
        resolve(report ?? { ok: false, mode,
          errors: [`validator child exited without a report (${signal ?? code})`], events: [] });
      }
    });
  });
}

async function main() {
  const argv = process.argv.slice(2);
  if (argv[0] === "--child") {
    const opts = options(argv.slice(3));
    // A pending Promise alone does not keep Node alive. Let the parent own
    // the deadline even when the plugin has no active I/O or timers.
    process.channel.ref();
    const report = await evaluate(
      argv[1],
      argv[2],
      argv[3]?.startsWith("--") ? null : argv[3],
      opts,
    );
    process.send(report, (error) => process.exit(!error && report.ok ? 0 : 1));
    return;
  }
  const mode =
    argv[0] === "validate" || argv[0] === "test" ? argv.shift() : "run";
  const opts = options(argv);
  const [pluginPath, url] = opts.positional;
  if (!pluginPath || (mode !== "validate" && !url)) {
    console.error(
      "usage: run.mjs validate <plugin.js> [--timeout ms]\n       run.mjs test <plugin.js> <url> [--fixture dir] [--hook classify|ingest|export] [--intent transcribe]\n       run.mjs <plugin.js> <url> [--fixture dir] [--hook classify|ingest] [--intent transcribe]",
    );
    process.exitCode = 2;
    return;
  }
  const report = await bounded(mode, pluginPath, url, opts);
  console.log(JSON.stringify(report, null, 2));
  process.exitCode = report.ok ? 0 : 1;
}

main().catch((error) => {
  console.error(error?.message ?? error);
  process.channel?.unref();
  process.exitCode = 1;
});
