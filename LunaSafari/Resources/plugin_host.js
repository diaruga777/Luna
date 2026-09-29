// plugin_host.js
//
// The `luna` bridge for a plugin running in the Safari content-script world
// (`claudedocs/plans/plugin-platform.md` §13.1). `content.js` fetches this
// file's TEXT and concatenates it with one plugin's source into a single
// `new Function` body, so `LunaPluginHost` and the plugin's top-level
// `luna.register(...)` call share one scope with no shared mutable state
// between plugins. Loaded as a plain script (the parity test harness does
// this), the same `var` becomes `window.LunaPluginHost` instead.
//
// `luna.html` is also exercised directly through `LunaPluginHost.html`, so the
// DOMParser backing can be run against the same spec file the SwiftSoup and
// linkedom backings run (`html-subset.spec.js`, §6.3, §13.3).
var LunaPluginHost = (function () {
    "use strict";

    // ---------------------------------------------------------------- errors

    /// `(code, message, details)`, character for character the constructor
    /// `PluginBootstrapScript.swift` declares for the JavaScriptCore backing
    /// and `bridge.mjs` for the node harness. A plugin branching on
    /// `error.code` reads the same thing in every process;
    /// `PluginBridgeParityTests` pins the three to each other.
    class LunaError extends Error {
        constructor(code, message, details) {
            super(message === undefined || message === null ? String(code) : String(message));
            this.name = "LunaError";
            this.code = String(code);
            this.details = details;
        }
    }

    // ------------------------------------------------------------- luna.html

    /// Wraps a live DOM node in the §6.3 subset: an Array from
    /// `querySelectorAll`/`children` rather than a live collection, a plain
    /// object from `attributes`, and `absoluteURL`/`baseURI` resolved against
    /// the URL the plugin asked to parse against — never the real document's
    /// own URL, which a detached `DOMParser` document does not carry anyway.
    /// `textContent`, but skipping a `<script>`/`<style>` subtree — the DOM
    /// property includes them (their body is, mechanically, a child text
    /// node), while SwiftSoup's `Element.text()` reads only what a page
    /// visibly shows. `luna.html` follows SwiftSoup's rule, so a plugin
    /// reading a page's text never has to filter script bodies out itself.
    function visibleTextContent(node) {
        var text = "";
        var children = node.childNodes || [];
        for (var i = 0; i < children.length; i++) {
            var child = children[i];
            if (child.nodeType === 1) {
                var tag = (child.tagName || "").toUpperCase();
                if (tag === "SCRIPT" || tag === "STYLE") { continue; }
                text += visibleTextContent(child);
            } else if (child.nodeType === 3 || child.nodeType === 4) {
                text += child.textContent || "";
            }
        }
        return text;
    }

    function wrapNode(node, baseURI) {
        if (!node) { return null; }
        return {
            querySelector: function (css) {
                var found = node.querySelector(css);
                return found ? wrapNode(found, baseURI) : null;
            },
            querySelectorAll: function (css) {
                return Array.prototype.map.call(
                    node.querySelectorAll(css), function (n) { return wrapNode(n, baseURI); });
            },
            get textContent() { return visibleTextContent(node); },
            get innerHTML() { return node.innerHTML || ""; },
            get outerHTML() { return node.outerHTML || ""; },
            get children() {
                return Array.prototype.map.call(
                    node.children || [], function (n) { return wrapNode(n, baseURI); });
            },
            get parentElement() {
                return node.parentElement ? wrapNode(node.parentElement, baseURI) : null;
            },
            get tagName() { return (node.tagName || "").toUpperCase(); },
            getAttribute: function (name) {
                return node.getAttribute ? node.getAttribute(name) : null;
            },
            hasAttribute: function (name) {
                return node.hasAttribute ? node.hasAttribute(name) : false;
            },
            get attributes() {
                var out = {};
                var attrs = node.attributes;
                if (attrs) {
                    for (var i = 0; i < attrs.length; i++) { out[attrs[i].name] = attrs[i].value; }
                }
                return out;
            },
            matches: function (css) { return node.matches ? node.matches(css) : false; },
            closest: function (css) {
                var found = node.closest ? node.closest(css) : null;
                return found ? wrapNode(found, baseURI) : null;
            },
            get baseURI() { return baseURI; },
            absoluteURL: function (attr) {
                var value = node.getAttribute ? node.getAttribute(attr) : null;
                if (value === null || value === undefined) { return null; }
                try { return new URL(value, baseURI).href; } catch (e) { return null; }
            },
        };
    }

    function wrapDocument(doc, baseURI) {
        var wrapped = wrapNode(doc, baseURI);
        Object.defineProperties(wrapped, {
            title: { get: function () { return doc.title || ""; } },
            documentElement: { get: function () { return wrapNode(doc.documentElement, baseURI); } },
            body: { get: function () { return doc.body ? wrapNode(doc.body, baseURI) : null; } },
            head: { get: function () { return doc.head ? wrapNode(doc.head, baseURI) : null; } },
        });
        return wrapped;
    }

    function parseHTML(html, baseURL) {
        var doc = new DOMParser().parseFromString(html || "", "text/html");
        return wrapDocument(doc, baseURL || "about:blank");
    }

    /// Strips tags and decodes entities by parsing `html` as a document body
    /// and reading its text — the same rule `querySelector('body').textContent`
    /// already follows, so there is only one text-extraction path to agree on.
    function htmlText(html) {
        var doc = new DOMParser().parseFromString(html || "", "text/html");
        return doc.body ? visibleTextContent(doc.body) : "";
    }

    /// Parsed `<script type="application/ld+json">`/`"application/json">`
    /// bodies. `doc` is already a wrapped `HTMLDocument`, so this only reads
    /// through its own `querySelectorAll`/`textContent`.
    function jsonScripts(doc, type) {
        var selector = type
            ? 'script[type="' + type + '"]'
            : 'script[type="application/ld+json"], script[type="application/json"]';
        var out = [];
        doc.querySelectorAll(selector).forEach(function (node) {
            try { out.push(JSON.parse(node.textContent)); } catch (e) { /* skip bad JSON */ }
        });
        return out;
    }

    /// Every `<script type="application/ld+json">` body, parse errors
    /// skipped and a `@graph` array flattened one level.
    /// `PluginHTMLMetadata.jsonLD` (SwiftSoup) and `bridge.mjs` (linkedom)
    /// answer the same list.
    function jsonLD(doc) {
        var out = [];
        jsonScripts(doc, "application/ld+json").forEach(function (value) {
            if (Array.isArray(value)) {
                value.forEach(function (entry) { appendGraph(entry, out); });
                return;
            }
            appendGraph(value, out);
        });
        return out;
    }

    function appendGraph(value, out) {
        if (value && typeof value === "object" && Array.isArray(value["@graph"])) {
            value["@graph"].forEach(function (entry) { out.push(entry); });
            return;
        }
        out.push(value);
    }

    /// The JSON-LD `@type`s that answer for the document as a whole.
    var LD_DOCUMENT_TYPES = ["Article", "NewsArticle", "BlogPosting", "Product"];

    /// `luna.html.meta` — one page's own account of itself, read out of
    /// OpenGraph, Twitter cards, plain `<meta name>`, `<link rel=canonical>`,
    /// `<title>`, `<html lang>` and JSON-LD, in that order per key. The rules
    /// are `PluginHTMLMetadata.swift`'s, case for case.
    function htmlMeta(doc) {
        var linked = jsonLD(doc).filter(function (object) {
            if (!object || typeof object !== "object") { return false; }
            var raw = object["@type"];
            var names = typeof raw === "string" ? [raw] : (Array.isArray(raw) ? raw : []);
            return names.some(function (name) { return LD_DOCUMENT_TYPES.indexOf(name) >= 0; });
        });

        function attribute(selector, name) {
            var node = doc.querySelector(selector);
            if (!node) { return null; }
            return clean(node.getAttribute(name));
        }
        function property(name) {
            return attribute('meta[property="' + name + '"]', "content")
                || attribute('meta[name="' + name + '"]', "content");
        }
        function named(name) { return attribute('meta[name="' + name + '"]', "content"); }
        function linkedField(field) {
            for (var i = 0; i < linked.length; i++) {
                var value = clean(linked[i][field]);
                if (value) { return value; }
            }
            return null;
        }
        function linkedNamed(field) {
            for (var i = 0; i < linked.length; i++) {
                var value = linked[i][field];
                var found = namedValue(value);
                if (found) { return found; }
            }
            return null;
        }
        function namedValue(value) {
            if (typeof value === "string") { return clean(value); }
            if (Array.isArray(value)) {
                for (var i = 0; i < value.length; i++) {
                    var found = namedValue(value[i]);
                    if (found) { return found; }
                }
                return null;
            }
            if (value && typeof value === "object") { return clean(value.name); }
            return null;
        }
        function linkedImage() {
            for (var i = 0; i < linked.length; i++) {
                var value = linked[i].image;
                if (typeof value === "string") { return clean(value); }
                if (Array.isArray(value)) { value = value[0]; }
                if (typeof value === "string") { return clean(value); }
                if (value && typeof value === "object" && clean(value.url)) {
                    return clean(value.url);
                }
            }
            return null;
        }
        function absolute(value) {
            if (!value) { return null; }
            try { return new URL(value, doc.baseURI).href; } catch (e) { return value; }
        }

        var found = {
            title: property("og:title") || property("twitter:title") || clean(doc.title)
                || linkedField("headline") || linkedField("name"),
            description: property("og:description") || property("twitter:description")
                || named("description"),
            canonical: absolute(property("og:url") || attribute('link[rel="canonical"]', "href")),
            image: absolute(property("og:image") || property("og:image:url")
                || property("twitter:image") || property("twitter:image:src") || linkedImage()),
            author: named("author") || property("article:author") || linkedNamed("author"),
            published: property("article:published_time") || named("date") || named("pubdate")
                || attribute('meta[itemprop="datePublished"]', "content")
                || attribute('[itemprop="datePublished"]', "datetime")
                || linkedField("datePublished"),
            siteName: property("og:site_name") || named("application-name"),
            language: clean(doc.documentElement && doc.documentElement.getAttribute("lang"))
                || attribute('meta[http-equiv="content-language"]', "content")
                || linkedField("inLanguage"),
            type: property("og:type"),
        };
        var result = {};
        Object.keys(found).forEach(function (key) {
            if (found[key]) { result[key] = found[key]; }
        });
        return result;
    }

    // -------------------------------------------------------------- luna.text

    /// The currency symbols `PriceParsing.normalizeCurrency` knows.
    var CURRENCY_SYMBOLS = { "$": "USD", "£": "GBP", "€": "EUR", "¥": "JPY" };

    var MONTHS = ["january", "february", "march", "april", "may", "june",
                  "july", "august", "september", "october", "november", "december"];

    /// Any run of Unicode whitespace becomes one space, and the result is
    /// trimmed. `\s` covers the no-break space, which is what a scraped label
    /// is usually padded with.
    function collapseWhitespace(text) {
        return String(text === undefined || text === null ? "" : text)
            .replace(/\s+/g, " ").trim();
    }

    /// Whitespace-collapsed, or null when nothing is left.
    function clean(value) {
        if (value === undefined || value === null) { return null; }
        var text = collapseWhitespace(value);
        return text === "" ? null : text;
    }

    /// `"$1,299.00"` -> `{amount:"1299.00",currency:"USD"}`. The separator rule
    /// is `PriceParsing`'s: with both separators present the later one is the
    /// decimal point; a lone comma is a decimal point only before one or two
    /// digits.
    function textPrice(raw) {
        var source = String(raw === undefined || raw === null ? "" : raw);
        var match = source.match(/[0-9][0-9.,]*/);
        if (!match) { return null; }
        var run = match[0].replace(/[.,]+$/, "");
        if (!run) { return null; }
        var lastDot = run.lastIndexOf(".");
        var lastComma = run.lastIndexOf(",");
        var amount;
        if (lastDot >= 0 && lastComma >= 0) {
            amount = lastDot > lastComma
                ? run.replace(/,/g, "")
                : run.replace(/\./g, "").replace(/,/g, ".");
        } else if (lastComma >= 0) {
            var afterComma = run.length - lastComma - 1;
            amount = (afterComma === 1 || afterComma === 2)
                ? run.replace(/,/g, ".")
                : run.replace(/,/g, "");
        } else {
            amount = run;
        }
        var start = source.indexOf(match[0]);
        var before = source.slice(0, start).replace(/\s+$/, "");
        var after = source.slice(start + run.length).replace(/^\s+/, "");
        var currency = null;
        Object.keys(CURRENCY_SYMBOLS).forEach(function (symbol) {
            if (currency) { return; }
            if (before.slice(-symbol.length) === symbol || after.slice(0, symbol.length) === symbol) {
                currency = CURRENCY_SYMBOLS[symbol];
            }
        });
        if (!currency) {
            var trailing = before.match(/([A-Za-z]+)$/);
            var leading = after.match(/^([A-Za-z]+)/);
            var code = (trailing && trailing[1]) || (leading && leading[1]) || "";
            if (code.length === 3 && code === code.toUpperCase()) { currency = code; }
        }
        var price = { amount: amount };
        if (currency) { price.currency = currency; }
        return price;
    }

    /// An absolute date as ISO 8601, or null. A date with a time answers UTC
    /// (`…T09:30:00Z`); a date without one answers `YYYY-MM-DD`, which is what
    /// the page said. A relative phrase answers null.
    function textDate(raw) {
        var text = String(raw === undefined || raw === null ? "" : raw).trim();
        if (!text) { return null; }
        var m = text.match(
            /^(\d{4})-(\d{2})-(\d{2})(?:[Tt ](\d{2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?\s*(Z|z|[+-]\d{2}:?\d{2})?)?$/);
        if (m) {
            return m[4] === undefined
                ? plainDate(+m[1], +m[2], +m[3])
                : instant(+m[1], +m[2], +m[3], +m[4], +m[5], +(m[6] || 0), m[7]);
        }
        m = text.match(/^(\d{4})\/(\d{1,2})\/(\d{1,2})$/);
        if (m) { return plainDate(+m[1], +m[2], +m[3]); }
        m = text.match(/^([A-Za-z]{3,9})\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})$/);
        if (m && monthNumber(m[1])) { return plainDate(+m[3], monthNumber(m[1]), +m[2]); }
        m = text.match(/^(\d{1,2})(?:st|nd|rd|th)?\s+([A-Za-z]{3,9})\.?,?\s+(\d{4})$/);
        if (m && monthNumber(m[2])) { return plainDate(+m[3], monthNumber(m[2]), +m[1]); }
        m = text.match(
            /^(?:[A-Za-z]{3},\s*)?(\d{1,2})\s+([A-Za-z]{3,9})\s+(\d{4})\s+(\d{2}):(\d{2})(?::(\d{2}))?\s*(GMT|UTC|Z|[+-]\d{4})?$/);
        if (m && monthNumber(m[2])) {
            return instant(+m[3], monthNumber(m[2]), +m[1], +m[4], +m[5], +(m[6] || 0), m[7]);
        }
        return null;
    }

    function monthNumber(name) {
        var lower = String(name).toLowerCase();
        for (var i = 0; i < MONTHS.length; i++) {
            if (MONTHS[i] === lower || (lower.length === 3 && MONTHS[i].indexOf(lower) === 0)) {
                return i + 1;
            }
        }
        return 0;
    }

    function isRealDay(year, month, day) {
        if (!(year >= 1000 && year <= 9999) || month < 1 || month > 12 || day < 1) { return false; }
        var leap = (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0;
        var lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
        return day <= lengths[month - 1];
    }

    function pad(value, width) {
        var text = String(value);
        while (text.length < width) { text = "0" + text; }
        return text;
    }

    function plainDate(year, month, day) {
        if (!isRealDay(year, month, day)) { return null; }
        return pad(year, 4) + "-" + pad(month, 2) + "-" + pad(day, 2);
    }

    function instant(year, month, day, hour, minute, second, zone) {
        if (!isRealDay(year, month, day) || hour > 23 || minute > 59 || second > 59) {
            return null;
        }
        var offset = 0;
        var m = String(zone || "").trim().match(/^([+-])(\d{2}):?(\d{2})$/);
        if (m) { offset = (m[1] === "-" ? -1 : 1) * ((+m[2]) * 3600 + (+m[3]) * 60); }
        var stamp = Date.UTC(year, month - 1, day, hour, minute, second) - offset * 1000;
        var moment = new Date(stamp);
        return pad(moment.getUTCFullYear(), 4) + "-" + pad(moment.getUTCMonth() + 1, 2) + "-"
            + pad(moment.getUTCDate(), 2) + "T" + pad(moment.getUTCHours(), 2) + ":"
            + pad(moment.getUTCMinutes(), 2) + ":" + pad(moment.getUTCSeconds(), 2) + "Z";
    }

    /// Entities decoded, tags dropped, whitespace collapsed, trimmed — the
    /// same rule `PluginTextParsing.clean` follows, over `luna.html.text`.
    function textClean(raw) {
        return collapseWhitespace(htmlText(String(raw === undefined || raw === null ? "" : raw)));
    }

    var text = { price: textPrice, date: textDate, clean: textClean };

    // -------------------------------------------------------------- luna.bytes

    function base64ToBytes(base64) {
        var binary = atob(base64);
        var bytes = new Uint8Array(binary.length);
        for (var i = 0; i < binary.length; i++) { bytes[i] = binary.charCodeAt(i); }
        return bytes;
    }

    function bytesToBase64(bytes) {
        var binary = "";
        for (var i = 0; i < bytes.length; i++) { binary += String.fromCharCode(bytes[i]); }
        return btoa(binary);
    }

    function utf8Encode(text) { return new TextEncoder().encode(text); }
    function utf8Decode(bytes) { return new TextDecoder("utf-8").decode(bytes); }

    /// `luna.fetch`'s body / `luna.crypto`'s input: a plain string is UTF-8
    /// text, `{ base64 }` is already bytes.
    function bytesFromInput(input) {
        return typeof input === "string" ? utf8Encode(input) : base64ToBytes(input.base64);
    }

    // ------------------------------------------------------------- luna.crypto

    function toArrayBuffer(bytes) {
        return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
    }

    function cryptoSHA256(data) {
        return crypto.subtle.digest("SHA-256", toArrayBuffer(bytesFromInput(data)))
            .then(function (buffer) { return bytesToBase64(new Uint8Array(buffer)); });
    }

    function cryptoHMACSHA256(key, data) {
        var keyBytes = bytesFromInput(key);
        return crypto.subtle.importKey(
            "raw", toArrayBuffer(keyBytes), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]
        ).then(function (cryptoKey) {
            return crypto.subtle.sign("HMAC", cryptoKey, toArrayBuffer(bytesFromInput(data)));
        }).then(function (buffer) { return bytesToBase64(new Uint8Array(buffer)); });
    }

    function cryptoRandomBytes(count) {
        var bytes = new Uint8Array(Math.max(0, count | 0));
        crypto.getRandomValues(bytes);
        return Promise.resolve(bytesToBase64(bytes));
    }

    // ---------------------------------------------------------------- parseURL

    function wrapParsedURL(url) {
        return {
            href: url.href, protocol: url.protocol, host: url.host, hostname: url.hostname,
            port: url.port, pathname: url.pathname, search: url.search, hash: url.hash,
            searchParams: {
                get: function (key) { return url.searchParams.get(key); },
                getAll: function (key) { return url.searchParams.getAll(key); },
                has: function (key) { return url.searchParams.has(key); },
                entries: function () { return Array.from(url.searchParams.entries()); },
            },
        };
    }

    // -------------------------------------------------------- native relay

    /// Runs native-message calls one at a time. WebKit's extension messaging
    /// guards against overlapping in-flight requests from one page, so every
    /// `luna.*` capability that reaches native shares this one chain rather
    /// than firing independently.
    function makeSequencer(sendNative) {
        var tail = Promise.resolve();
        return function (type, payload) {
            var result = tail.then(function () { return sendNative(type, payload); });
            tail = result.then(function () {}, function () {});
            return result;
        };
    }

    /// A messaging failure as a `LunaError`. A plugin catches one code shape
    /// off every `luna.*` call, never a bare `Error` from WebKit's own
    /// `sendMessage`.
    function relayFailure(error) {
        if (error instanceof LunaError) { return error; }
        return new LunaError(
            "bridge-failed", (error && error.message) || "the app did not answer that call");
    }

    /// Rejects one call on a namespace this process serves only in part.
    function refuseHere(namespace, member) {
        return Promise.reject(new LunaError(
            "unavailable-here",
            (member ? "luna." + namespace + "." + member : "luna." + namespace)
                + " is not available in this process"));
    }

    /// The stand-in for a capability the plugin DECLARED and Safari cannot
    /// serve at all. It matches `PluginUnavailableNamespace` in
    /// `LunaPluginRuntime/PluginCapabilityRegistry.swift`: the Proxy target is
    /// a FUNCTION, because a namespace may be called directly
    /// (`luna.fetch(…)`) as well as read from (`luna.storage.get(…)`), and a
    /// plain object would throw a TypeError the author cannot branch on.
    function unavailableNamespace(name) {
        return new Proxy(function () {}, {
            apply: function () { return refuseHere(name, null); },
            get: function (_target, property) {
                if (property === "then") { return undefined; }
                return function () { return refuseHere(name, String(property)); };
            },
        });
    }

    // --------------------------------------------------------- localization

    /// Resolves a `name`/`label`-shaped value the identical way the manifest
    /// parser resolves a plugin's own copy tables (§2.2): a string passes
    /// through; a table tries an exact language tag, then that tag's
    /// language (`pt-BR` -> `pt`), then `en`. `PluginBootstrapScript.swift`
    /// and `bridge.mjs` carry the same rule.
    function resolveLocalized(table, languages) {
        if (typeof table === "string") { return table; }
        if (!table || typeof table !== "object") { return undefined; }
        var langs = languages || [];
        for (var i = 0; i < langs.length; i++) {
            if (Object.prototype.hasOwnProperty.call(table, langs[i])) { return table[langs[i]]; }
        }
        for (var i = 0; i < langs.length; i++) {
            var prefix = String(langs[i]).split("-")[0];
            if (Object.prototype.hasOwnProperty.call(table, prefix)) { return table[prefix]; }
        }
        return table.en;
    }

    // ------------------------------------------------------------- the bridge

    /// Builds one plugin's `luna` object. `config.capabilities` are the
    /// manifest's declared names — only those namespaces are installed, so
    /// `Object.keys(luna)` matches what the plugin declared plus the
    /// always-present set, honestly reflecting what native will actually serve
    /// (native re-checks the same declarations independently; this is not the
    /// security boundary, it is the plugin's own contract with itself).
    function createBridge(config, sendNative) {
        var send = makeSequencer(sendNative);
        /// One relayed call. A reply carrying an `error` code, an explicit
        /// `ok: false` (a storage write whose row was over the cap answers
        /// that way), or a messaging failure all reject a `LunaError` —
        /// reading past one let a plugin carry on as though a failed write
        /// had landed.
        var relay = function (type, payload) {
            return send(type, payload).then(function (reply) {
                if (!reply) {
                    throw new LunaError("bridge-failed", "the app did not answer that call");
                }
                if (reply.error) {
                    throw new LunaError(reply.error, reply.message || "the app refused that call");
                }
                if (reply.ok === false) {
                    throw new LunaError(
                        "bridge-failed", reply.message || "the app refused that call");
                }
                return reply;
            }, function (error) { throw relayFailure(error); });
        };
        var declared = {};
        (config.capabilities || []).forEach(function (name) { declared[name] = true; });
        var registeredHooks = null;

        var luna = {};

        luna.register = function (hooks) {
            if (registeredHooks) {
                throw new LunaError("already-registered", "luna.register was called more than once");
            }
            if (!hooks || typeof hooks !== "object" || Array.isArray(hooks)) {
                throw new LunaError("invalid-hooks", "luna.register needs an object of hooks");
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
            get: function () { return registeredHooks; },
        });

        luna.parseURL = function (url, base) {
            try { return wrapParsedURL(base ? new URL(url, base) : new URL(url)); }
            catch (_) { return null; }
        };

        luna.log = function (message, data) {
            var text = typeof message === "string" ? message : String(message);
            send("plugins.log", { id: config.pluginId, message: text, data: data })
                .catch(function () {});
        };

        luna.bytes = {
            fromBase64: base64ToBytes, toBase64: bytesToBase64,
            utf8Encode: utf8Encode, utf8Decode: utf8Decode,
        };

        // `navigator.languages` (the page's own preferred-language list) is
        // reachable here because `plugin_host.js` and the plugin body run
        // concatenated in ONE `new Function` body inside the content-script
        // world, which shares the page's globals (§13.1).
        var languages = (typeof navigator !== "undefined" && navigator.languages
            && navigator.languages.length)
            ? navigator.languages.slice()
            : [config.locale || "en"];

        luna.env = {
            context: "safari", api: 1, pluginId: config.pluginId,
            version: config.version || "0.0.0",
            locale: languages[0] || "en", languages: languages,
        };

        luna.localize = function (table) { return resolveLocalized(table, luna.env.languages); };

        luna.LunaError = LunaError;

        if (declared.html) {
            // `article` is the one `luna.html` member with no implementation
            // in the page: it is Luna's own readability pass, relayed to
            // native so one extractor answers in every process. It is a
            // Promise in the app too, for exactly that reason.
            var articleLimit = 1500000;
            luna.html = {
                parse: parseHTML, text: htmlText, jsonScripts: jsonScripts,
                jsonLD: jsonLD, meta: htmlMeta,
                article: function (html, baseURL) {
                    var source = String(html === undefined || html === null ? "" : html);
                    if (!source) {
                        return Promise.reject(new LunaError(
                            "bad-argument", "luna.html.article needs HTML text"));
                    }
                    if (source.length > articleLimit) {
                        return Promise.reject(new LunaError(
                            "too-large", "that page is too large to send to Luna"));
                    }
                    return relay("plugins.article", {
                        id: config.pluginId, html: source,
                        baseURL: baseURL === undefined || baseURL === null
                            ? location.href : String(baseURL),
                    }).then(function (reply) {
                        return reply.article === undefined ? null : reply.article;
                    });
                },
            };
            // `luna.text` rides on the `html` grant, as it does in the app
            // (`PluginCapabilityName.companionNamespaces`).
            luna.text = text;
        }

        if (declared.page) {
            var pageHTMLLimit = 200000;
            var currentPageHTML = function () {
                var html = document.documentElement ? document.documentElement.outerHTML : "";
                return { html: html.slice(0, pageHTMLLimit), truncated: html.length > pageHTMLLimit };
            };
            luna.page = {
                document: function () { return wrapDocument(document, location.href); },
                url: function () { return location.href; },
                title: function () { return document.title || ""; },
                html: function () { return currentPageHTML().html; },
                truncated: function () { return currentPageHTML().truncated; },
            };
        }

        if (declared.fetch) {
            // `ok: false` is a real answer here — a 404 whose body the plugin
            // still reads — so only an `error` code is a rejection.
            var lunaFetch = function (request) {
                var req = typeof request === "string" ? { url: request } : (request || {});
                return send("plugins.fetch", { id: config.pluginId, request: req })
                    .then(function (response) {
                        if (!response || response.error) {
                            throw new LunaError(
                                (response && response.error) || "fetch-failed",
                                (response && response.message) || "the fetch failed");
                        }
                        return response;
                    }, function (error) { throw relayFailure(error); });
            };
            // The `text`/`json`/`doc` sugar, character for character the
            // contract `PluginFetchBridge.sugarFactory` installs in the app: a
            // non-2xx rejects `fetch-failed` with the status, and `doc` needs
            // the `html` capability as well.
            var fetchGet = function (url, opts) {
                var request = {};
                var source = opts || {};
                Object.keys(source).forEach(function (key) { request[key] = source[key]; });
                request.url = String(url);
                request.method = request.method || "GET";
                request.as = "text";
                return lunaFetch(request).then(function (response) {
                    if (!response || !response.ok) {
                        throw new LunaError(
                            "fetch-failed",
                            request.method + " " + request.url + " answered "
                                + ((response && response.status) || 0));
                    }
                    return response;
                });
            };
            lunaFetch.text = function (url, opts) {
                return fetchGet(url, opts).then(function (response) {
                    return typeof response.text === "string" ? response.text : "";
                });
            };
            lunaFetch.json = function (url, opts) {
                return fetchGet(url, opts).then(function (response) {
                    try {
                        return JSON.parse(
                            typeof response.text === "string" ? response.text : "");
                    } catch (error) {
                        throw new LunaError(
                            "fetch-failed", String(url) + " did not answer JSON: " + error.message);
                    }
                });
            };
            lunaFetch.doc = function (url, opts) {
                return fetchGet(url, opts).then(function (response) {
                    if (!luna.html || typeof luna.html.parse !== "function") {
                        throw new LunaError(
                            "capability-not-declared",
                            "luna.fetch.doc parses the page, so the manifest must "
                                + "declare the \"html\" capability too");
                    }
                    return luna.html.parse(response.text || "", response.url || String(url));
                });
            };
            luna.fetch = lunaFetch;
        }

        if (declared.storage) {
            luna.storage = {
                // A key that holds nothing answers `undefined`;
                // `PluginStorageBridge` answers the same, so `null` stays a
                // value a plugin may have stored on purpose.
                get: function (key) {
                    return relay("plugins.storage.get", { id: config.pluginId, key: key })
                        .then(function (r) { return r.value; });
                },
                // `undefined` is not a value: a native message drops an
                // undefined field, so this would otherwise reach the store as
                // JSON null. `PluginStorageBridge.set` rejects it too.
                set: function (key, value) {
                    if (value === undefined) {
                        return Promise.reject(new LunaError(
                            "bad-argument",
                            "luna.storage.set needs a value; use delete to remove a key"));
                    }
                    return relay(
                        "plugins.storage.set", { id: config.pluginId, key: key, value: value }
                    ).then(function () {});
                },
                delete: function (key) {
                    return relay("plugins.storage.delete", { id: config.pluginId, key: key })
                        .then(function () {});
                },
                keys: function (prefix) {
                    return relay("plugins.storage.keys", { id: config.pluginId, prefix: prefix })
                        .then(function (r) { return r.keys || []; });
                },
                // A nameless collection rejects rather than throwing, so a
                // plugin reads a code off it — `PluginStorageBridge.collection`
                // answers a rejected promise from the same call.
                collection: function (name) {
                    if (typeof name !== "string" || name === "") {
                        return Promise.reject(new LunaError(
                            "bad-argument", "luna.storage.collection needs a name"));
                    }
                    return {
                        put: function (id, doc, index) {
                            return relay("plugins.collection.put", {
                                id: config.pluginId, collection: name, docId: id, doc: doc,
                                k1: index && index.k1, k2: index && index.k2,
                            }).then(function () {});
                        },
                        get: function (id) {
                            return relay("plugins.collection.get", {
                                id: config.pluginId, collection: name, docId: id,
                            }).then(function (r) { return "doc" in r ? r.doc : null; });
                        },
                        delete: function (id) {
                            return relay("plugins.collection.delete", {
                                id: config.pluginId, collection: name, docId: id,
                            }).then(function () {});
                        },
                        find: function (where, opts) {
                            return relay("plugins.collection.find", {
                                id: config.pluginId, collection: name,
                                k1: where && where.k1, k2: where && where.k2,
                                limit: opts && opts.limit, offset: opts && opts.offset,
                            }).then(function (r) { return r.items || []; });
                        },
                        count: function (where) {
                            return relay("plugins.collection.count", {
                                id: config.pluginId, collection: name,
                                k1: where && where.k1, k2: where && where.k2,
                            }).then(function (r) { return r.count || 0; });
                        },
                    };
                },
            };
        }

        if (declared.settings) {
            luna.settings = {
                // Native answers the manifest field's own default for a key
                // the user never touched, and `null` for a key the schema does
                // not declare — the two answers `PluginSettingsBridge.value`
                // gives in the app.
                get: function (key) {
                    return relay("plugins.settings.get", { id: config.pluginId, key: key })
                        .then(function (r) { return "value" in r ? r.value : null; });
                },
                // Writing a setting from a page would change what the user
                // sees in Settings from a process they cannot see, and reading
                // the whole schema has no relay.
                set: function () { return refuseHere("settings", "set"); },
                all: function () { return refuseHere("settings", "all"); },
            };
        }

        if (declared.crypto) {
            luna.crypto = {
                sha256: cryptoSHA256, hmacSHA256: cryptoHMACSHA256, randomBytes: cryptoRandomBytes,
            };
        }

        if (declared.browser) {
            luna.browser = {
                // No save exists yet in Safari (§8.2): the native side hands
                // back a deep link that starts one, and this always rejects —
                // the caller (an ingest hook) lets the rejection propagate so
                // the walk treats the page as locked rather than declined.
                open: function (request) {
                    return send("plugins.browserDeferred", {
                        id: config.pluginId, url: request && request.url, request: request,
                    }).catch(function () {}).then(function () {
                        throw new LunaError(
                            "browser-deferred", "no save exists yet in Safari");
                    });
                },
            };
        }

        // A capability the plugin DECLARED that no Safari relay serves still
        // EXISTS, and every call on it rejects `unavailable-here` — the same
        // contract `PluginUnavailableNamespace` gives the JavaScriptCore
        // processes, so `error.code` is the one thing a plugin has to handle
        // rather than a TypeError it cannot catch by code.
        Object.keys(declared).forEach(function (name) {
            if (luna[name] !== undefined) { return; }
            luna[name] = unavailableNamespace(name);
        });

        return luna;
    }

    return {
        // `article` is absent here on purpose: it is the one member with no
        // page-side implementation, so the parity harness (which has no
        // native side) cannot run it. Every other member is the same function
        // `createBridge` installs.
        html: {
            parse: parseHTML, text: htmlText, jsonScripts: jsonScripts,
            jsonLD: jsonLD, meta: htmlMeta,
        },
        text: text,
        LunaError: LunaError,
        createBridge: createBridge,
        resolveLocalized: resolveLocalized,
    };
})();
