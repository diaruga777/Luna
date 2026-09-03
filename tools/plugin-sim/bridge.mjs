// bridge.mjs
//
// A Node implementation of the `luna.*` bridge, for iterating on a plugin
// outside Xcode (claudedocs/plans/plugin-platform.md §13.4). It shares no
// code with `plugin_host.js` or the SwiftSoup bridge — three independent
// implementations of one small, spec-defined surface, the same way
// `spec.mjs`/`PluginHTMLParityTests`/`PluginHTMLSubsetTests` run the SAME
// `html-subset.spec.js` against each of the three `luna.html` backings.
//
// Implemented: `html` (linkedom), `crypto`, `storage`, `settings`, `files`
// (an in-memory map — `fetch`'s multipart `file` parts and `as: "file"`
// resolve through it same as the app), `fetch` and `downloads` (fed from
// `config.downloads`, since there is no real download engine or saves
// database here). `browser` is declared when requested but always rejects
// `unavailable-here` — there is no page to run a challenge detector against
// outside a real WebKit process. Absent entirely, same as an undeclared
// capability everywhere else: `secrets`, `page`, `ui`, `mail`,
// `notifications`, `bluetooth`, `wifi`, `exports` (see
// `claudedocs/plugins.md` §13.3 for the reasoning behind each).

import { fetch as undiciFetch } from "undici";
import { parseHTML } from "linkedom";
import crypto from "node:crypto";

/// `(code, message, details)`, the same order `PluginBootstrapScript.swift`
/// declares for the JavaScriptCore backing and `plugin_host.js` for the Safari
/// content-script world. A plugin branching on `error.code` reads the same
/// thing here as it does in the app; `PluginBridgeParityTests` pins the three.
export class LunaError extends Error {
  constructor(code, message, details) {
    super(message === undefined || message === null ? String(code) : String(message));
    this.name = "LunaError";
    this.code = String(code);
    this.details = details;
  }
}

// ---------------------------------------------------------------- luna.html

/// `textContent`, but skipping a `<script>`/`<style>` subtree — matches
/// SwiftSoup's `Element.text()`, which `plugin_host.js` also follows, rather
/// than the raw DOM property (which includes a script body verbatim).
function visibleTextContent(node) {
  let text = "";
  for (const child of node.childNodes || []) {
    if (child.nodeType === 1) {
      const tag = (child.tagName || "").toUpperCase();
      if (tag === "SCRIPT" || tag === "STYLE") continue;
      text += visibleTextContent(child);
    } else if (child.nodeType === 3 || child.nodeType === 4) {
      text += child.textContent || "";
    }
  }
  return text;
}

function wrapNode(node, baseURI) {
  if (!node) return null;
  return {
    querySelector: (css) => {
      const found = node.querySelector(css);
      return found ? wrapNode(found, baseURI) : null;
    },
    querySelectorAll: (css) =>
      Array.from(node.querySelectorAll(css)).map((n) => wrapNode(n, baseURI)),
    get textContent() { return visibleTextContent(node); },
    get innerHTML() { return node.innerHTML || ""; },
    get outerHTML() { return node.outerHTML || ""; },
    get children() {
      return Array.from(node.children || []).map((n) => wrapNode(n, baseURI));
    },
    get parentElement() {
      return node.parentElement ? wrapNode(node.parentElement, baseURI) : null;
    },
    get tagName() { return (node.tagName || "").toUpperCase(); },
    getAttribute: (name) => (node.getAttribute ? node.getAttribute(name) : null),
    hasAttribute: (name) => (node.hasAttribute ? node.hasAttribute(name) : false),
    get attributes() {
      // HTML attribute names are case-insensitive and a real parser folds
      // them to lower case; linkedom keeps whatever case the source used.
      const out = {};
      for (const attr of node.attributes || []) out[attr.name.toLowerCase()] = attr.value;
      return out;
    },
    matches: (css) => (node.matches ? node.matches(css) : false),
    closest: (css) => {
      const found = node.closest ? node.closest(css) : null;
      return found ? wrapNode(found, baseURI) : null;
    },
    get baseURI() { return baseURI; },
    absoluteURL(attr) {
      const value = node.getAttribute ? node.getAttribute(attr) : null;
      if (value === null || value === undefined) return null;
      try { return new URL(value, baseURI).href; } catch { return null; }
    },
  };
}

function wrapDocument(doc, baseURI) {
  const wrapped = wrapNode(doc, baseURI);
  Object.defineProperties(wrapped, {
    title: { get: () => doc.title || "" },
    documentElement: { get: () => wrapNode(doc.documentElement, baseURI) },
    body: { get: () => (doc.body ? wrapNode(doc.body, baseURI) : null) },
    head: { get: () => (doc.head ? wrapNode(doc.head, baseURI) : null) },
  });
  return wrapped;
}

/// linkedom's `parseHTML` does not auto-wrap a bare fragment in `<html>`/
/// `<body>` the way a real browser's tolerant parser does — a fragment with
/// no block element can even come back with no `documentElement` at all.
/// Wrapping first keeps this backing's document shape consistent with the
/// other two (DOMParser, SwiftSoup) for exactly the inputs the spec exercises.
function wrapFragmentIfNeeded(html) {
  const text = html || "";
  return /<html[\s>]/i.test(text) ? text : `<html><head></head><body>${text}</body></html>`;
}

function htmlParse(htmlText, baseURL) {
  const { document } = parseHTML(wrapFragmentIfNeeded(htmlText));
  return wrapDocument(document, baseURL || "about:blank");
}

function htmlToText(htmlText) {
  const { document } = parseHTML(wrapFragmentIfNeeded(htmlText));
  return document.body ? visibleTextContent(document.body) : "";
}

function jsonScripts(doc, type) {
  const selector = type
    ? `script[type="${type}"]`
    : 'script[type="application/ld+json"], script[type="application/json"]';
  const out = [];
  for (const node of doc.querySelectorAll(selector)) {
    try { out.push(JSON.parse(node.textContent)); } catch { /* skip bad JSON */ }
  }
  return out;
}

export const html = { parse: htmlParse, text: htmlToText, jsonScripts };

// ------------------------------------------------------------- luna.bytes

function base64ToBytes(b64) { return new Uint8Array(Buffer.from(b64, "base64")); }
function bytesToBase64(bytes) { return Buffer.from(bytes).toString("base64"); }
function utf8Encode(text) { return new Uint8Array(Buffer.from(text, "utf8")); }
function utf8Decode(bytes) { return Buffer.from(bytes).toString("utf8"); }
function bytesFromInput(input) {
  return typeof input === "string" ? utf8Encode(input) : base64ToBytes(input.base64);
}

// ------------------------------------------------------------- luna.crypto

async function cryptoSHA256(data) {
  return bytesToBase64(crypto.createHash("sha256").update(Buffer.from(bytesFromInput(data))).digest());
}
async function cryptoHMACSHA256(key, data) {
  const keyBytes = Buffer.from(bytesFromInput(key));
  return bytesToBase64(crypto.createHmac("sha256", keyBytes).update(Buffer.from(bytesFromInput(data))).digest());
}
async function cryptoRandomBytes(count) {
  return bytesToBase64(crypto.randomBytes(Math.max(0, count | 0)));
}

// --------------------------------------------------------- localization

/// Resolves a `name`/`label`-shaped value the identical way the manifest
/// parser resolves a plugin's own copy tables (§2.2): a string passes
/// through; a table tries an exact language tag, then that tag's language
/// (`pt-BR` -> `pt`), then `en`. `PluginBootstrapScript.swift` and
/// `plugin_host.js` carry the same rule.
export function resolveLocalized(table, languages) {
  if (typeof table === "string") return table;
  if (!table || typeof table !== "object") return undefined;
  const langs = languages || [];
  for (const lang of langs) {
    if (Object.prototype.hasOwnProperty.call(table, lang)) return table[lang];
  }
  for (const lang of langs) {
    const prefix = String(lang).split("-")[0];
    if (Object.prototype.hasOwnProperty.call(table, prefix)) return table[prefix];
  }
  return table.en;
}

// ------------------------------------------------------------ luna.storage

export function makeStorage() {
  const MAX_VALUE_BYTES = 256 * 1024;
  const checked = (value) => {
    const encoded = JSON.stringify(value);
    if (encoded === undefined || Buffer.byteLength(encoded, "utf8") > MAX_VALUE_BYTES) {
      throw new LunaError("too-large", `storage values may be at most ${MAX_VALUE_BYTES} bytes`);
    }
    return value;
  };
  const kv = new Map();
  const collections = new Map();
  function collection(name) {
    if (!collections.has(name)) collections.set(name, new Map());
    const docs = collections.get(name);
    return {
      async put(id, doc, index) { docs.set(id, { doc: checked(doc), k1: index?.k1, k2: index?.k2 }); },
      async get(id) { return docs.get(id)?.doc; },
      async delete(id) { docs.delete(id); },
      async find(where = {}, opts = {}) {
        let rows = Array.from(docs.entries()).map(([id, v]) => ({ id, ...v }));
        if (where.k1 !== undefined) rows = rows.filter((r) => r.k1 === where.k1);
        if (where.k2 !== undefined) rows = rows.filter((r) => r.k2 === where.k2);
        if (opts.offset) rows = rows.slice(opts.offset);
        if (opts.limit !== undefined) rows = rows.slice(0, opts.limit);
        return rows.map(({ id, doc }) => ({ id, doc }));
      },
      async count(where = {}) {
        let rows = Array.from(docs.values());
        if (where.k1 !== undefined) rows = rows.filter((r) => r.k1 === where.k1);
        if (where.k2 !== undefined) rows = rows.filter((r) => r.k2 === where.k2);
        return rows.length;
      },
    };
  }
  return {
    async get(key) { return kv.get(key); },
    async set(key, value) { kv.set(key, checked(value)); },
    async delete(key) { kv.delete(key); },
    async keys(prefix) {
      const all = Array.from(kv.keys()).sort();
      return prefix ? all.filter((k) => k.startsWith(prefix)) : all;
    },
    collection,
  };
}

// -------------------------------------------------------------- luna.files

/// `luna.files` over an in-memory map. A handle is a descriptor, as it is in
/// the app, so multipart `{ file }` and `as: "file"` behave the same here.
export function makeFiles() {
  const MAX_FILE_BYTES = 8 * 1024 * 1024;
  const files = new Map();
  function write(name, data, mime) {
    const bytes = typeof data === "string"
      ? Buffer.from(data, "utf8")
      : Buffer.from(data.base64, "base64");
    if (bytes.length > MAX_FILE_BYTES) throw new LunaError("too-large", "a file may be at most 8 MB");
    const id = crypto.randomUUID();
    const safe = String(name).replace(/[/\\]/g, "_").replace(/\.\./g, "_") || "file";
    files.set(id, { id, name: safe, size: bytes.length, mime: mime ?? null, bytes });
    return files.get(id);
  }
  function handle(entry) {
    return { id: entry.id, name: entry.name, size: entry.size, mime: entry.mime };
  }
  return {
    bytesFor: (h) => files.get(h?.id)?.bytes,
    entryFor: (h) => files.get(h?.id),
    api: {
      async write(name, data, mime) { return handle(write(name, data, mime)); },
      async read(h, as) {
        const entry = files.get(h?.id);
        if (!entry) throw new LunaError("not-found", "that file is gone");
        if (as === "base64") return entry.bytes.toString("base64");
        return entry.bytes.toString("utf8");
      },
      async size(h) {
        const entry = files.get(h?.id);
        if (!entry) throw new LunaError("not-found", "that file is gone");
        return entry.size;
      },
      // The harness's own way in: a fixture hands a plugin a file to export.
      put: (name, data, mime) => handle(write(name, data, mime)),
    },
  };
}

// -------------------------------------------------------------- luna.fetch

/// The largest file a multipart `file` part may carry, as
/// `PluginFilesBridge.maxFileBytes` caps it in the app.
const MAX_FILE_BYTES = 8 * 1024 * 1024;

/// One multipart body, built the way `PluginFetchRequestDecoder` builds it: the
/// three bytes that could forge a header are percent-encoded in a quoted
/// parameter and dropped from a bare one.
function encodeMultipart(parts, boundary, files) {
  const parameter = (raw) => String(raw)
    .replace(/"/g, "%22").replace(/\r/g, "%0D").replace(/\n/g, "%0A");
  const token = (raw) => String(raw).replace(/["\r\n]/g, "");
  const chunks = [];
  for (const part of parts) {
    if (typeof part?.name !== "string") continue;
    let content;
    let filename = part.filename;
    let mime = part.mime;
    if (part.file) {
      const entry = files?.entryFor(part.file);
      if (!entry) throw new LunaError("not-found", "that file is gone");
      if (entry.size > MAX_FILE_BYTES) {
        throw new LunaError(
          "too-large",
          `a multipart file part may be at most ${MAX_FILE_BYTES / (1024 * 1024)} MB`);
      }
      content = entry.bytes;
      filename = filename ?? entry.name;
      mime = mime ?? entry.mime ?? undefined;
    } else if (typeof part.text === "string") {
      content = Buffer.from(part.text, "utf8");
    } else if (typeof part.base64 === "string") {
      content = Buffer.from(part.base64, "base64");
    }
    let disposition = `form-data; name="${parameter(part.name)}"`;
    if (filename !== undefined && filename !== null) {
      disposition += `; filename="${parameter(filename)}"`;
    }
    chunks.push(Buffer.from(`--${boundary}\r\nContent-Disposition: ${disposition}\r\n`, "utf8"));
    if (mime) chunks.push(Buffer.from(`Content-Type: ${token(mime)}\r\n`, "utf8"));
    chunks.push(Buffer.from("\r\n", "utf8"));
    if (content) chunks.push(content);
    chunks.push(Buffer.from("\r\n", "utf8"));
  }
  chunks.push(Buffer.from(`--${boundary}--\r\n`, "utf8"));
  return Buffer.concat(chunks);
}

function fetchFactory(fetchImpl, files) {
  return async function lunaFetch(request) {
    const req = typeof request === "string" ? { url: request } : request || {};
    const headers = { ...(req.headers || {}) };
    if (req.userAgent && !headers["User-Agent"]) headers["User-Agent"] = req.userAgent;
    if (req.cookies && !["shared", "ephemeral", "none", "browser"].includes(req.cookies)) {
      throw new LunaError(
        "bad-argument", 'cookies must be "shared", "ephemeral", "none" or "browser"');
    }
    let body;
    if (typeof req.body === "string") body = req.body;
    else if (req.body?.base64) body = Buffer.from(req.body.base64, "base64");
    else if (req.body?.json !== undefined) {
      body = JSON.stringify(req.body.json);
      headers["Content-Type"] = headers["Content-Type"] || "application/json";
    } else if (req.body?.form) {
      body = new URLSearchParams(req.body.form).toString();
      headers["Content-Type"] = headers["Content-Type"] || "application/x-www-form-urlencoded";
    } else if (req.body?.multipart) {
      const boundary = `luna-${crypto.randomUUID()}`;
      body = encodeMultipart(req.body.multipart, boundary, files);
      headers["Content-Type"] = headers["Content-Type"]
        || `multipart/form-data; boundary=${boundary}`;
    }
    const timeout = Number.isFinite(req.timeout) ? Math.max(1, req.timeout) : 30_000;
    let timeoutID;
    try {
      const response = await Promise.race([
        fetchImpl(req.url, {
          method: req.method || "GET", headers, body,
          redirect: req.redirect === "manual" ? "manual" : "follow",
        }),
        new Promise((_, reject) => {
          timeoutID = setTimeout(() => reject(new LunaError("timeout", "fetch timed out")), timeout);
        }),
      ]);
      return await makeFetchResult(response, req, files);
    } finally {
      clearTimeout(timeoutID);
    }
  };
}

async function makeFetchResult(response, req, files) {
    const responseHeaders = {};
    response.headers.forEach((value, key) => { responseHeaders[key] = value; });
    const buffer = Buffer.from(await response.arrayBuffer());
    const cap = Math.min(Math.max(0, req.maxBytes ?? 10 * 1024 * 1024), 10 * 1024 * 1024);
    const truncated = buffer.length > cap;
    const capped = truncated ? buffer.subarray(0, cap) : buffer;
    const result = {
      ok: response.ok !== false, status: response.status ?? 200, url: response.url || req.url,
      redirected: !!response.redirected, headers: responseHeaders,
      truncated, bytes: capped.length,
    };
    if (req.as === "base64") result.base64 = capped.toString("base64");
    else if (req.as === "file") {
      if (!files) {
        throw new LunaError(
          "unavailable-here", 'as: "file" needs the "files" capability');
      }
      const name = new URL(result.url).pathname.split("/").pop() || "file";
      result.file = files.api.put(
        name, { base64: capped.toString("base64") }, responseHeaders["content-type"]);
    } else result.text = capped.toString("utf8");
  return result;
}

// -------------------------------------------------------------- luna.settings

/// `luna.settings` over the manifest's own `settings` array, applying the three
/// rules `PluginSettingsBridge` applies in the app: an unset field reads its
/// declared `default`, a `secret` field reads back `""` once set and never the
/// value it holds, and `set` on a key the schema does not declare rejects
/// `bad-argument`. A key starting with `_` is Luna's own — a manifest can never
/// declare one, and `_status` is how a destination plugin drives its share-row
/// dot — so it is read and written without a declaration. A missing value reads
/// `null`, the answer the app's bridge gives.
///
/// Called with no schema the harness stores anything under any key, which is
/// what a fixture that hands over a bare value map expects.
function makeSettings(values, schema) {
  const fields = schema ? new Map(schema.map((field) => [field.key, field])) : null;
  const read = (key) => {
    if (!fields) return values.get(key);
    if (String(key).startsWith("_")) return values.has(key) ? values.get(key) : null;
    const field = fields.get(key);
    if (!field) return null;
    if (field.secret) return values.has(key) ? "" : null;
    if (values.has(key)) return values.get(key);
    return field.default === undefined ? null : field.default;
  };
  return {
    get: async (key) => read(key),
    set: async (key, value) => {
      if (fields && !String(key).startsWith("_") && !fields.has(key)) {
        throw new LunaError("bad-argument", `no setting named "${key}" is declared`);
      }
      values.set(key, value);
    },
    all: async () => {
      if (!fields) return Object.fromEntries(values);
      const all = {};
      for (const field of schema) {
        const value = read(field.key);
        if (value !== null && value !== undefined) all[field.key] = value;
      }
      return all;
    },
  };
}

// ----------------------------------------------------------------- bridge

/// `config`: `{ pluginId, version, locale, languages?: string[], capabilities:
/// string[], fetchImpl?, storage?, settings?, settingsSchema?, downloads? }`.
/// `languages` defaults to `[locale || "en"]` when omitted. `fetchImpl` lets
/// `run.mjs --fixture` answer `luna.fetch` from recorded files instead of the
/// network; `settings` is the stored-value `Map` and `settingsSchema` the
/// manifest's `settings` array those values are read against; `downloads` is
/// the fixed `DownloadJob[]` `luna.downloads` reads.
export function createBridge(config = {}) {
  const capabilities = new Set(config.capabilities || []);
  let registeredHooks = null;
  const luna = {};

  luna.register = (hooks) => {
    if (registeredHooks) {
      throw new LunaError("already-registered", "luna.register was called more than once");
    }
    if (!hooks || typeof hooks !== "object") {
      throw new LunaError("invalid-hooks", "luna.register needs an object of hooks");
    }
    registeredHooks = hooks;
  };
  Object.defineProperty(luna, "__registeredHooks", { get: () => registeredHooks });

  luna.parseURL = (url, base) => {
    const u = base ? new URL(url, base) : new URL(url);
    return {
      href: u.href, protocol: u.protocol, host: u.host, hostname: u.hostname,
      port: u.port, pathname: u.pathname, search: u.search, hash: u.hash,
      searchParams: {
        get: (k) => u.searchParams.get(k),
        getAll: (k) => u.searchParams.getAll(k),
        has: (k) => u.searchParams.has(k),
        entries: () => Array.from(u.searchParams.entries()),
      },
    };
  };

  luna.log = (message, data) => {
    const text = typeof message === "string" ? message : String(message);
    const tag = `[${config.pluginId || "plugin"}]`;
    if (data !== undefined) console.error(tag, text, data);
    else console.error(tag, text);
  };

  luna.bytes = { fromBase64: base64ToBytes, toBase64: bytesToBase64, utf8Encode, utf8Decode };
  const languages = config.languages && config.languages.length
    ? config.languages
    : [config.locale || "en"];
  luna.env = {
    context: config.context || "app", api: 1, pluginId: config.pluginId || "app.luna.dev",
    version: config.version || "0.0.0", locale: languages[0] || "en", languages,
  };
  luna.localize = (table) => resolveLocalized(table, luna.env.languages);
  luna.LunaError = LunaError;

  if (capabilities.has("html")) luna.html = html;

  if (capabilities.has("crypto")) {
    luna.crypto = { sha256: cryptoSHA256, hmacSHA256: cryptoHMACSHA256, randomBytes: cryptoRandomBytes };
  }

  if (capabilities.has("storage")) {
    luna.storage = config.storage || makeStorage();
  }

  if (capabilities.has("settings")) {
    luna.settings = makeSettings(config.settings || new Map(), config.settingsSchema);
  }

  const files = capabilities.has("files") ? makeFiles() : null;
  if (files) luna.files = files.api;

  if (capabilities.has("fetch")) {
    luna.fetch = fetchFactory(config.fetchImpl || undiciFetch, files);
  }

  // In-memory, fed from `config.downloads` (a `DownloadJob[]`) — the harness
  // has no real download engine or saves database to read, so a fixture
  // supplies whatever jobs `classify`/`ingest` should see.
  if (capabilities.has("downloads")) {
    const jobs = config.downloads || [];
    const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    luna.downloads = {
      jobs: async () => jobs,
      job: async (saveId) => {
        if (typeof saveId !== "string" || !uuidPattern.test(saveId)) {
          throw new LunaError("bad-argument", "luna.downloads.job needs a save id");
        }
        const matches = jobs.filter((job) => job.saveId === saveId);
        return matches.length ? matches[matches.length - 1] : null;
      },
    };
  }

  // Never available: there is no page to run a challenge detector against
  // outside a real WebKit process. A plugin sees exactly what Safari's
  // content-script world sees when it defers (§8.2), so authoring against
  // this harness surfaces the same fallback path a real deferral takes.
  if (capabilities.has("browser")) {
    luna.browser = {
      async open() {
        throw new LunaError(
          "unavailable-here", "luna.browser is not available in the node harness");
      },
    };
  }

  return luna;
}
