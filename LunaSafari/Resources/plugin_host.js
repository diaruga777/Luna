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

    class LunaError extends Error {
        constructor(message, code, details) {
            super(message);
            this.name = "LunaError";
            this.code = code || "error";
            if (details !== undefined) { this.details = details; }
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

    // ------------------------------------------------------------- the bridge

    /// Builds one plugin's `luna` object. `config.capabilities` are the
    /// manifest's declared names — only those namespaces are installed, so
    /// `Object.keys(luna)` matches what the plugin declared plus the
    /// always-present set, honestly reflecting what native will actually serve
    /// (native re-checks the same declarations independently; this is not the
    /// security boundary, it is the plugin's own contract with itself).
    function createBridge(config, sendNative) {
        var send = makeSequencer(sendNative);
        var declared = {};
        (config.capabilities || []).forEach(function (name) { declared[name] = true; });
        var registeredHooks = null;

        var luna = {};

        luna.register = function (hooks) {
            if (registeredHooks) {
                throw new LunaError("luna.register was called more than once", "already-registered");
            }
            if (!hooks || typeof hooks !== "object") {
                throw new LunaError("luna.register needs an object of hooks", "invalid-hooks");
            }
            registeredHooks = hooks;
        };
        Object.defineProperty(luna, "__registeredHooks", {
            get: function () { return registeredHooks; },
        });

        luna.parseURL = function (url, base) {
            return wrapParsedURL(base ? new URL(url, base) : new URL(url));
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

        luna.env = {
            context: "safari", api: 1, pluginId: config.pluginId,
            version: config.version || "0.0.0", locale: config.locale || "en",
        };

        luna.LunaError = LunaError;

        if (declared.html) {
            luna.html = { parse: parseHTML, text: htmlText, jsonScripts: jsonScripts };
        }

        if (declared.page) {
            luna.page = {
                document: function () { return wrapDocument(document, location.href); },
                url: function () { return location.href; },
                title: function () { return document.title || ""; },
                html: function () {
                    return document.documentElement ? document.documentElement.outerHTML : "";
                },
            };
        }

        if (declared.fetch) {
            luna.fetch = function (request) {
                var req = typeof request === "string" ? { url: request } : (request || {});
                return send("plugins.fetch", { id: config.pluginId, request: req })
                    .then(function (response) {
                        if (!response || response.error) {
                            throw new LunaError(
                                (response && response.message) || "fetch failed",
                                (response && response.error) || "fetch-failed");
                        }
                        return response;
                    });
            };
        }

        if (declared.storage) {
            luna.storage = {
                get: function (key) {
                    return send("plugins.storage.get", { id: config.pluginId, key: key })
                        .then(function (r) { return r ? r.value : undefined; });
                },
                set: function (key, value) {
                    return send("plugins.storage.set", { id: config.pluginId, key: key, value: value })
                        .then(function () {});
                },
                delete: function (key) {
                    return send("plugins.storage.delete", { id: config.pluginId, key: key })
                        .then(function () {});
                },
                keys: function (prefix) {
                    return send("plugins.storage.keys", { id: config.pluginId, prefix: prefix })
                        .then(function (r) { return (r && r.keys) || []; });
                },
                collection: function (name) {
                    return {
                        put: function (id, doc, index) {
                            return send("plugins.collection.put", {
                                id: config.pluginId, collection: name, docId: id, doc: doc,
                                k1: index && index.k1, k2: index && index.k2,
                            }).then(function () {});
                        },
                        get: function (id) {
                            return send("plugins.collection.get", {
                                id: config.pluginId, collection: name, docId: id,
                            }).then(function (r) { return r ? r.doc : undefined; });
                        },
                        delete: function (id) {
                            return send("plugins.collection.delete", {
                                id: config.pluginId, collection: name, docId: id,
                            }).then(function () {});
                        },
                        find: function (where, opts) {
                            return send("plugins.collection.find", {
                                id: config.pluginId, collection: name,
                                k1: where && where.k1, k2: where && where.k2,
                                limit: opts && opts.limit, offset: opts && opts.offset,
                            }).then(function (r) { return (r && r.items) || []; });
                        },
                        count: function (where) {
                            return send("plugins.collection.count", {
                                id: config.pluginId, collection: name,
                                k1: where && where.k1, k2: where && where.k2,
                            }).then(function (r) { return (r && r.count) || 0; });
                        },
                    };
                },
            };
        }

        if (declared.settings) {
            luna.settings = {
                get: function (key) {
                    return send("plugins.settings.get", { id: config.pluginId, key: key })
                        .then(function (r) { return r ? r.value : undefined; });
                },
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
                        throw new LunaError("browser-deferred", "browser-deferred");
                    });
                },
            };
        }

        return luna;
    }

    return {
        html: { parse: parseHTML, text: htmlText, jsonScripts: jsonScripts },
        LunaError: LunaError,
        createBridge: createBridge,
    };
})();
