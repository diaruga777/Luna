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
// outside a real WebKit process. Other declared capabilities without a
// Node implementation reject unavailable-here, just like the native host.

import { fetch as undiciFetch } from "undici";
import { parseHTML } from "linkedom";
import { Readability, isProbablyReaderable } from "@mozilla/readability";
import crypto from "node:crypto";

/// `(code, message, details)`, the same order `PluginBootstrapScript.swift`
/// declares for the JavaScriptCore backing and `plugin_host.js` for the Safari
/// content-script world. A plugin branching on `error.code` reads the same
/// thing here as it does in the app; `PluginBridgeParityTests` pins the three.
export class LunaError extends Error {
  constructor(code, message, details) {
    super(
      message === undefined || message === null
        ? String(code)
        : String(message),
    );
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
    get textContent() {
      return visibleTextContent(node);
    },
    get innerHTML() {
      return node.innerHTML || "";
    },
    get outerHTML() {
      return node.outerHTML || "";
    },
    get children() {
      return Array.from(node.children || []).map((n) => wrapNode(n, baseURI));
    },
    get parentElement() {
      return node.parentElement ? wrapNode(node.parentElement, baseURI) : null;
    },
    get tagName() {
      return (node.tagName || "").toUpperCase();
    },
    getAttribute: (name) =>
      node.getAttribute ? node.getAttribute(name) : null,
    hasAttribute: (name) =>
      node.hasAttribute ? node.hasAttribute(name) : false,
    get attributes() {
      // HTML attribute names are case-insensitive and a real parser folds
      // them to lower case; linkedom keeps whatever case the source used.
      const out = {};
      for (const attr of node.attributes || [])
        out[attr.name.toLowerCase()] = attr.value;
      return out;
    },
    matches: (css) => (node.matches ? node.matches(css) : false),
    closest: (css) => {
      const found = node.closest ? node.closest(css) : null;
      return found ? wrapNode(found, baseURI) : null;
    },
    get baseURI() {
      return baseURI;
    },
    absoluteURL(attr) {
      const value = node.getAttribute ? node.getAttribute(attr) : null;
      if (value === null || value === undefined) return null;
      try {
        return new URL(value, baseURI).href;
      } catch {
        return null;
      }
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
  return /<html[\s>]/i.test(text)
    ? text
    : `<html><head></head><body>${text}</body></html>`;
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
    try {
      out.push(JSON.parse(node.textContent));
    } catch {
      /* skip bad JSON */
    }
  }
  return out;
}

/// Every `<script type="application/ld+json">` body, parse errors skipped and
/// a `@graph` array flattened one level — `PluginHTMLMetadata.jsonLD`
/// (SwiftSoup) and `plugin_host.js` (DOMParser) answer the same list.
function jsonLD(doc) {
  const out = [];
  const append = (value) => {
    if (value && typeof value === "object" && Array.isArray(value["@graph"])) {
      out.push(...value["@graph"]);
      return;
    }
    out.push(value);
  };
  for (const value of jsonScripts(doc, "application/ld+json")) {
    if (Array.isArray(value)) value.forEach(append);
    else append(value);
  }
  return out;
}

const LD_DOCUMENT_TYPES = ["Article", "NewsArticle", "BlogPosting", "Product"];

/// `luna.html.meta`, rule for rule as `PluginHTMLMetadata.swift` and
/// `plugin_host.js` read it.
function htmlMeta(doc) {
  const linked = jsonLD(doc).filter((object) => {
    if (!object || typeof object !== "object") return false;
    const raw = object["@type"];
    const names =
      typeof raw === "string" ? [raw] : Array.isArray(raw) ? raw : [];
    return names.some((name) => LD_DOCUMENT_TYPES.includes(name));
  });
  const attribute = (selector, name) => {
    const node = doc.querySelector(selector);
    return node ? cleanOrNull(node.getAttribute(name)) : null;
  };
  const property = (name) =>
    attribute(`meta[property="${name}"]`, "content") ||
    attribute(`meta[name="${name}"]`, "content");
  const named = (name) => attribute(`meta[name="${name}"]`, "content");
  const linkedField = (field) => {
    for (const object of linked) {
      const value = cleanOrNull(object[field]);
      if (value) return value;
    }
    return null;
  };
  const namedValue = (value) => {
    if (typeof value === "string") return cleanOrNull(value);
    if (Array.isArray(value)) {
      for (const entry of value) {
        const found = namedValue(entry);
        if (found) return found;
      }
      return null;
    }
    if (value && typeof value === "object") return cleanOrNull(value.name);
    return null;
  };
  const linkedImage = () => {
    for (const object of linked) {
      let value = object.image;
      if (typeof value === "string") return cleanOrNull(value);
      if (Array.isArray(value)) value = value[0];
      if (typeof value === "string") return cleanOrNull(value);
      if (value && typeof value === "object" && cleanOrNull(value.url))
        return cleanOrNull(value.url);
    }
    return null;
  };
  const absolute = (value) => {
    if (!value) return null;
    try {
      return new URL(value, doc.baseURI).href;
    } catch {
      return value;
    }
  };
  const found = {
    title:
      property("og:title") ||
      property("twitter:title") ||
      cleanOrNull(doc.title) ||
      linkedField("headline") ||
      linkedField("name"),
    description:
      property("og:description") ||
      property("twitter:description") ||
      named("description"),
    canonical: absolute(
      property("og:url") || attribute('link[rel="canonical"]', "href"),
    ),
    image: absolute(
      property("og:image") ||
        property("og:image:url") ||
        property("twitter:image") ||
        property("twitter:image:src") ||
        linkedImage(),
    ),
    author: named("author") || property("article:author") || namedValue(
      linked.map((object) => object.author).find((value) => value !== undefined),
    ),
    published:
      property("article:published_time") ||
      named("date") ||
      named("pubdate") ||
      attribute('meta[itemprop="datePublished"]', "content") ||
      attribute('[itemprop="datePublished"]', "datetime") ||
      linkedField("datePublished"),
    siteName: property("og:site_name") || named("application-name"),
    language:
      cleanOrNull(
        doc.documentElement && doc.documentElement.getAttribute("lang"),
      ) ||
      attribute('meta[http-equiv="content-language"]', "content") ||
      linkedField("inLanguage"),
    type: property("og:type"),
  };
  const result = {};
  for (const [key, value] of Object.entries(found)) if (value) result[key] = value;
  return result;
}

/// APPROXIMATE. The app runs Luna's own `ArticleExtractor` (SwiftSoup) and
/// Safari relays to it; there is no port of that pass to Node, so the harness
/// substitutes `@mozilla/readability`. Expect a different `html` and a
/// different `excerpt` from the same page — use it to check that your plugin
/// CALLS the helper correctly, never to compare its output to the app's.
async function htmlArticle(htmlText, baseURL) {
  const base = baseURL || "https://example.com/";
  const { document } = parseHTML(wrapFragmentIfNeeded(htmlText));
  const meta = htmlMeta(wrapDocument(document, base));
  let parsed = null;
  try {
    if (isProbablyReaderable(document)) {
      parsed = new Readability(document).parse();
    }
  } catch {
    parsed = null;
  }
  if (!parsed || !parsed.content) return null;
  const absolute = (value) => {
    if (!value) return undefined;
    try {
      return new URL(value, base).href;
    } catch {
      return value;
    }
  };
  const article = {
    title: parsed.title || meta.title || "",
    html: parsed.content,
    text: (parsed.textContent || "").trim(),
  };
  const author = parsed.byline || meta.author;
  if (author) article.author = author;
  const published = parsed.publishedTime || meta.published;
  if (published) article.publishedAt = textDate(published) || published;
  const image = meta.image || absolute(parsed.lead_image_url);
  if (image) article.leadImageURL = image;
  const excerpt = meta.description || parsed.excerpt;
  if (excerpt) article.excerpt = excerpt.slice(0, 1000);
  return article;
}

export const html = {
  parse: htmlParse,
  text: htmlToText,
  jsonScripts,
  jsonLD,
  meta: htmlMeta,
  article: htmlArticle,
};

// --------------------------------------------------------------- luna.text

/// The currency symbols `PriceParsing.normalizeCurrency` knows.
const CURRENCY_SYMBOLS = { $: "USD", "£": "GBP", "€": "EUR", "¥": "JPY" };

const MONTHS = [
  "january", "february", "march", "april", "may", "june",
  "july", "august", "september", "october", "november", "december",
];

function collapseWhitespace(text) {
  return String(text ?? "").replace(/\s+/g, " ").trim();
}

function cleanOrNull(value) {
  if (value === undefined || value === null) return null;
  const text = collapseWhitespace(value);
  return text === "" ? null : text;
}

/// `"$1,299.00"` -> `{amount:"1299.00",currency:"USD"}`, the separator rule
/// `PriceParsing` applies in Swift.
function textPrice(raw) {
  const source = String(raw ?? "");
  const match = source.match(/[0-9][0-9.,]*/);
  if (!match) return null;
  const run = match[0].replace(/[.,]+$/, "");
  if (!run) return null;
  const lastDot = run.lastIndexOf(".");
  const lastComma = run.lastIndexOf(",");
  let amount;
  if (lastDot >= 0 && lastComma >= 0) {
    amount =
      lastDot > lastComma
        ? run.replace(/,/g, "")
        : run.replace(/\./g, "").replace(/,/g, ".");
  } else if (lastComma >= 0) {
    const afterComma = run.length - lastComma - 1;
    amount =
      afterComma === 1 || afterComma === 2
        ? run.replace(/,/g, ".")
        : run.replace(/,/g, "");
  } else {
    amount = run;
  }
  const start = source.indexOf(match[0]);
  const before = source.slice(0, start).replace(/\s+$/, "");
  const after = source.slice(start + run.length).replace(/^\s+/, "");
  let currency = null;
  for (const [symbol, code] of Object.entries(CURRENCY_SYMBOLS)) {
    if (before.endsWith(symbol) || after.startsWith(symbol)) {
      currency = code;
      break;
    }
  }
  if (!currency) {
    const trailing = before.match(/([A-Za-z]+)$/);
    const leading = after.match(/^([A-Za-z]+)/);
    const code = (trailing && trailing[1]) || (leading && leading[1]) || "";
    if (code.length === 3 && code === code.toUpperCase()) currency = code;
  }
  const price = { amount };
  if (currency) price.currency = currency;
  return price;
}

function monthNumber(name) {
  const lower = String(name).toLowerCase();
  for (let i = 0; i < MONTHS.length; i++) {
    if (MONTHS[i] === lower || (lower.length === 3 && MONTHS[i].startsWith(lower)))
      return i + 1;
  }
  return 0;
}

function isRealDay(year, month, day) {
  if (!(year >= 1000 && year <= 9999) || month < 1 || month > 12 || day < 1)
    return false;
  const leap = (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0;
  const lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  return day <= lengths[month - 1];
}

const pad = (value, width) => String(value).padStart(width, "0");

function plainDate(year, month, day) {
  if (!isRealDay(year, month, day)) return null;
  return `${pad(year, 4)}-${pad(month, 2)}-${pad(day, 2)}`;
}

function instant(year, month, day, hour, minute, second, zone) {
  if (!isRealDay(year, month, day) || hour > 23 || minute > 59 || second > 59)
    return null;
  let offset = 0;
  const m = String(zone || "").trim().match(/^([+-])(\d{2}):?(\d{2})$/);
  if (m) offset = (m[1] === "-" ? -1 : 1) * (+m[2] * 3600 + +m[3] * 60);
  const moment = new Date(
    Date.UTC(year, month - 1, day, hour, minute, second) - offset * 1000,
  );
  return (
    `${pad(moment.getUTCFullYear(), 4)}-${pad(moment.getUTCMonth() + 1, 2)}-` +
    `${pad(moment.getUTCDate(), 2)}T${pad(moment.getUTCHours(), 2)}:` +
    `${pad(moment.getUTCMinutes(), 2)}:${pad(moment.getUTCSeconds(), 2)}Z`
  );
}

/// An absolute date as ISO 8601, or null. A relative phrase answers null.
function textDate(raw) {
  const source = String(raw ?? "").trim();
  if (!source) return null;
  let m = source.match(
    /^(\d{4})-(\d{2})-(\d{2})(?:[Tt ](\d{2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?\s*(Z|z|[+-]\d{2}:?\d{2})?)?$/,
  );
  if (m)
    return m[4] === undefined
      ? plainDate(+m[1], +m[2], +m[3])
      : instant(+m[1], +m[2], +m[3], +m[4], +m[5], +(m[6] || 0), m[7]);
  m = source.match(/^(\d{4})\/(\d{1,2})\/(\d{1,2})$/);
  if (m) return plainDate(+m[1], +m[2], +m[3]);
  m = source.match(/^([A-Za-z]{3,9})\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})$/);
  if (m && monthNumber(m[1])) return plainDate(+m[3], monthNumber(m[1]), +m[2]);
  m = source.match(/^(\d{1,2})(?:st|nd|rd|th)?\s+([A-Za-z]{3,9})\.?,?\s+(\d{4})$/);
  if (m && monthNumber(m[2])) return plainDate(+m[3], monthNumber(m[2]), +m[1]);
  m = source.match(
    /^(?:[A-Za-z]{3},\s*)?(\d{1,2})\s+([A-Za-z]{3,9})\s+(\d{4})\s+(\d{2}):(\d{2})(?::(\d{2}))?\s*(GMT|UTC|Z|[+-]\d{4})?$/,
  );
  if (m && monthNumber(m[2]))
    return instant(+m[3], monthNumber(m[2]), +m[1], +m[4], +m[5], +(m[6] || 0), m[7]);
  return null;
}

/// Entities decoded, tags dropped, whitespace collapsed, trimmed.
function textClean(raw) {
  return collapseWhitespace(htmlToText(String(raw ?? "")));
}

export const text = { price: textPrice, date: textDate, clean: textClean };

// ------------------------------------------------------------- luna.bytes

function base64ToBytes(b64) {
  return new Uint8Array(Buffer.from(b64, "base64"));
}
function bytesToBase64(bytes) {
  return Buffer.from(bytes).toString("base64");
}
function utf8Encode(text) {
  return new TextEncoder().encode(text);
}
function utf8Decode(bytes) {
  return new TextDecoder("utf-8").decode(new Uint8Array(bytes));
}
function bytesFromInput(input) {
  return typeof input === "string"
    ? utf8Encode(input)
    : base64ToBytes(input.base64);
}

// ------------------------------------------------------------- luna.crypto

async function cryptoSHA256(data) {
  return bytesToBase64(
    crypto
      .createHash("sha256")
      .update(Buffer.from(bytesFromInput(data)))
      .digest(),
  );
}
async function cryptoHMACSHA256(key, data) {
  const keyBytes = Buffer.from(bytesFromInput(key));
  return bytesToBase64(
    crypto
      .createHmac("sha256", keyBytes)
      .update(Buffer.from(bytesFromInput(data)))
      .digest(),
  );
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
    if (Object.prototype.hasOwnProperty.call(table, prefix))
      return table[prefix];
  }
  return table.en;
}

// ------------------------------------------------------------ luna.storage

export function makeStorage() {
  const MAX_VALUE_BYTES = 256 * 1024;
  const checked = (value) => {
    const encoded = JSON.stringify(value);
    if (
      encoded === undefined ||
      Buffer.byteLength(encoded, "utf8") > MAX_VALUE_BYTES
    ) {
      throw new LunaError(
        "too-large",
        `storage values may be at most ${MAX_VALUE_BYTES} bytes`,
      );
    }
    return value;
  };
  const kv = new Map();
  const collections = new Map();
  function collection(name) {
    if (!collections.has(name)) collections.set(name, new Map());
    const docs = collections.get(name);
    return {
      async put(id, doc, index) {
        docs.set(id, { doc: checked(doc), k1: index?.k1, k2: index?.k2 });
      },
      async get(id) {
        return docs.get(id)?.doc;
      },
      async delete(id) {
        docs.delete(id);
      },
      async find(where = {}, opts = {}) {
        let rows = Array.from(docs.entries()).map(([id, v]) => ({ id, ...v }));
        if (where.k1 !== undefined)
          rows = rows.filter((r) => r.k1 === where.k1);
        if (where.k2 !== undefined)
          rows = rows.filter((r) => r.k2 === where.k2);
        if (opts.offset) rows = rows.slice(opts.offset);
        if (opts.limit !== undefined) rows = rows.slice(0, opts.limit);
        return rows.map(({ id, doc }) => ({ id, doc }));
      },
      async count(where = {}) {
        let rows = Array.from(docs.values());
        if (where.k1 !== undefined)
          rows = rows.filter((r) => r.k1 === where.k1);
        if (where.k2 !== undefined)
          rows = rows.filter((r) => r.k2 === where.k2);
        return rows.length;
      },
    };
  }
  return {
    async get(key) {
      return kv.get(key);
    },
    async set(key, value) {
      kv.set(key, checked(value));
    },
    async delete(key) {
      kv.delete(key);
    },
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
    const bytes =
      typeof data === "string"
        ? Buffer.from(data, "utf8")
        : Buffer.from(data.base64, "base64");
    if (bytes.length > MAX_FILE_BYTES)
      throw new LunaError("too-large", "a file may be at most 8 MB");
    const id = crypto.randomUUID();
    const safe =
      String(name).replace(/[/\\]/g, "_").replace(/\.\./g, "_") || "file";
    files.set(id, {
      id,
      name: safe,
      size: bytes.length,
      mime: mime ?? null,
      bytes,
    });
    return files.get(id);
  }
  function handle(entry) {
    return {
      id: entry.id,
      name: entry.name,
      size: entry.size,
      mime: entry.mime,
    };
  }
  return {
    bytesFor: (h) => files.get(h?.id)?.bytes,
    entryFor: (h) => files.get(h?.id),
    api: {
      async write(name, data, mime) {
        return handle(write(name, data, mime));
      },
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
  const parameter = (raw) =>
    String(raw)
      .replace(/"/g, "%22")
      .replace(/\r/g, "%0D")
      .replace(/\n/g, "%0A");
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
          `a multipart file part may be at most ${MAX_FILE_BYTES / (1024 * 1024)} MB`,
        );
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
    chunks.push(
      Buffer.from(
        `--${boundary}\r\nContent-Disposition: ${disposition}\r\n`,
        "utf8",
      ),
    );
    if (mime)
      chunks.push(Buffer.from(`Content-Type: ${token(mime)}\r\n`, "utf8"));
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
    if (req.userAgent && !headers["User-Agent"])
      headers["User-Agent"] = req.userAgent;
    if (req.cookies && !["shared", "ephemeral", "none"].includes(req.cookies)) {
      throw new LunaError(
        "bad-argument",
        'cookies must be "shared", "ephemeral" or "none"',
      );
    }
    let body;
    if (typeof req.body === "string") body = req.body;
    else if (req.body?.base64) body = Buffer.from(req.body.base64, "base64");
    else if (req.body?.json !== undefined) {
      body = JSON.stringify(req.body.json);
      headers["Content-Type"] = headers["Content-Type"] || "application/json";
    } else if (req.body?.form) {
      body = new URLSearchParams(req.body.form).toString();
      headers["Content-Type"] =
        headers["Content-Type"] || "application/x-www-form-urlencoded";
    } else if (req.body?.multipart) {
      const boundary = `luna-${crypto.randomUUID()}`;
      body = encodeMultipart(req.body.multipart, boundary, files);
      headers["Content-Type"] =
        headers["Content-Type"] || `multipart/form-data; boundary=${boundary}`;
    }
    const seconds = req.timeout === undefined ? 20 : req.timeout;
    if (!Number.isFinite(seconds) || seconds <= 0) {
      throw new LunaError("bad-argument", "timeout must be a finite number greater than 0 (seconds)");
    }
    const timeout = Math.min(seconds, 120) * 1000;
    const controller = new AbortController();
    let timeoutID;
    try {
      return await Promise.race([
        Promise.resolve().then(() => fetchImpl(req.url, {
          method: req.method || "GET",
          headers,
          body,
          redirect: req.redirect === "manual" ? "manual" : "follow",
          signal: controller.signal,
        })).then((response) => makeFetchResult(response, req, files)),
        new Promise((_, reject) => {
          timeoutID = setTimeout(
            () => {
              reject(new LunaError("timeout", "fetch timed out"));
              controller.abort();
            },
            timeout,
          );
        }),
      ]);
    } finally {
      clearTimeout(timeoutID);
    }
  };
}

async function makeFetchResult(response, req, files) {
  const responseHeaders = {};
  response.headers.forEach((value, key) => {
    responseHeaders[key] = value;
  });
  const buffer = Buffer.from(await response.arrayBuffer());
  const cap = Math.min(
    Math.max(0, req.maxBytes ?? 10 * 1024 * 1024),
    10 * 1024 * 1024,
  );
  const truncated = buffer.length > cap;
  const capped = truncated ? buffer.subarray(0, cap) : buffer;
  const result = {
    ok: (response.status ?? 200) >= 200 && (response.status ?? 200) < 300,
    status: response.status ?? 200,
    url: response.url || req.url,
    redirected: !!response.redirected,
    headers: responseHeaders,
    truncated,
    bytes: capped.length,
  };
  if (req.as === "base64") result.base64 = capped.toString("base64");
  else if (req.as === "file") {
    if (!files) {
      throw new LunaError(
        "unavailable-here",
        'as: "file" needs the "files" capability',
      );
    }
    const name = new URL(result.url).pathname.split("/").pop() || "file";
    result.file = files.api.put(
      name,
      { base64: capped.toString("base64") },
      responseHeaders["content-type"],
    );
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
  const fields = schema
    ? new Map(schema.map((field) => [field.key, field]))
    : null;
  const read = (key) => {
    if (!fields) return values.get(key);
    if (String(key).startsWith("_"))
      return values.has(key) ? values.get(key) : null;
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
        throw new LunaError(
          "bad-argument",
          `no setting named "${key}" is declared`,
        );
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
      throw new LunaError(
        "already-registered",
        "luna.register was called more than once",
      );
    }
    if (!hooks || typeof hooks !== "object" || Array.isArray(hooks)) {
      throw new LunaError(
        "invalid-hooks",
        "luna.register needs an object of hooks",
      );
    }
    const captured = {};
    ["classify", "ingest", "export", "onBluetooth", "onSettingsChanged", "onAction"].forEach(function (name) {
      const hook = hooks[name];
      if (hook === undefined) return;
      if (typeof hook !== "function") throw new LunaError("invalid-hooks", name + " must be a function");
      captured[name] = hook;
    });
    registeredHooks = Object.freeze(captured);
  };
  Object.defineProperty(luna, "__registeredHooks", {
    get: () => registeredHooks,
  });

  luna.parseURL = (url, base) => {
    let u;
    try { u = base ? new URL(url, base) : new URL(url); }
    catch { return null; }
    return {
      href: u.href,
      protocol: u.protocol,
      host: u.host,
      hostname: u.hostname,
      port: u.port,
      pathname: u.pathname,
      search: u.search,
      hash: u.hash,
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

  luna.bytes = {
    fromBase64: base64ToBytes,
    toBase64: bytesToBase64,
    utf8Encode,
    utf8Decode,
  };
  const languages =
    config.languages && config.languages.length
      ? config.languages
      : [config.locale || "en"];
  luna.env = {
    context: config.context || "app",
    api: 1,
    pluginId: config.pluginId || "app.luna.dev",
    version: config.version || "0.0.0",
    locale: languages[0] || "en",
    languages,
  };
  luna.localize = (table) => resolveLocalized(table, luna.env.languages);
  luna.LunaError = LunaError;

  if (capabilities.has("html")) {
    const retiredSemanticHelper = () => { throw new Error("Bundle plugin-owned web helpers from docs/plugins/lib/web.js"); };
    luna.html = {...html, meta:retiredSemanticHelper, article:retiredSemanticHelper};
    // `luna.text` rides on the `html` grant, as it does in the app
    // (`PluginCapabilityName.companionNamespaces`).
    luna.text = {...text, price:retiredSemanticHelper, date:retiredSemanticHelper};
  }

  if (capabilities.has("crypto")) {
    luna.crypto = {
      sha256: cryptoSHA256,
      hmacSHA256: cryptoHMACSHA256,
      randomBytes: cryptoRandomBytes,
    };
  }

  if (capabilities.has("storage")) {
    luna.storage = config.storage || makeStorage();
  }

  if (capabilities.has("settings")) {
    luna.settings = makeSettings(
      config.settings || new Map(),
      config.settingsSchema,
    );
  }

  const files = capabilities.has("files") ? makeFiles() : null;
  if (files) luna.files = files.api;

  if (capabilities.has("fetch")) {
    const raw = fetchFactory(config.fetchImpl || undiciFetch, files);
    // The `text`/`json`/`doc` sugar, the same contract
    // `PluginFetchBridge.sugarFactory` and `plugin_host.js` install: a non-2xx
    // rejects `fetch-failed` with the status, and `doc` needs `html` too.
    const lunaFetch = (request) => raw(request);
    const get = async (url, opts) => {
      const response = await raw({
        ...(opts || {}),
        url: String(url),
        method: (opts && opts.method) || "GET",
        as: "text",
      });
      if (!response || !response.ok) {
        throw new LunaError(
          "fetch-failed",
          `${(opts && opts.method) || "GET"} ${url} answered ${(response && response.status) || 0}`,
        );
      }
      return response;
    };
    lunaFetch.text = async (url, opts) => (await get(url, opts)).text ?? "";
    lunaFetch.json = async (url, opts) => {
      const response = await get(url, opts);
      try {
        return JSON.parse(response.text ?? "");
      } catch (error) {
        throw new LunaError(
          "fetch-failed",
          `${url} did not answer JSON: ${error.message}`,
        );
      }
    };
    lunaFetch.doc = async (url, opts) => {
      const response = await get(url, opts);
      if (!luna.html || typeof luna.html.parse !== "function") {
        throw new LunaError(
          "capability-not-declared",
          'luna.fetch.doc parses the page, so the manifest must declare the "html" capability too',
        );
      }
      return luna.html.parse(response.text ?? "", response.url || String(url));
    };
    luna.fetch = lunaFetch;
  }

  // In-memory, fed from `config.downloads` (a `DownloadJob[]`) — the harness
  // has no real download engine or saves database to read, so a fixture
  // supplies whatever jobs `classify`/`ingest` should see.
  if (capabilities.has("downloads")) {
    const jobs = config.downloads || [];
    const uuidPattern =
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    luna.downloads = {
      jobs: async () => jobs,
      job: async (saveId) => {
        if (typeof saveId !== "string" || !uuidPattern.test(saveId)) {
          throw new LunaError(
            "bad-argument",
            "luna.downloads.job needs a save id",
          );
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
          "unavailable-here",
          "luna.browser is not available in the node harness",
        );
      },
    };
  }

  for (const name of capabilities) {
    if (luna[name] !== undefined) continue;
    const refuse = () => Promise.reject(new LunaError(
      "unavailable-here", `luna.${name} is not available in the node harness`));
    luna[name] = new Proxy(refuse, {
      get: (_target, key) => key === "then" ? undefined : refuse,
    });
  }
  return luna;
}
