//
//  PluginBootstrapScript.swift
//  LunaPluginRuntime
//

import Foundation

/// The JavaScript every plugin context starts with.
///
/// It is written in JS rather than bridged from Swift for the parts a plugin
/// touches by VALUE: `LunaError` must be a real class so `instanceof` works,
/// `luna.bytes` must answer a `Uint8Array`, and `parseURL`'s `searchParams`
/// must carry methods. A bare `JSContext` has no `TextEncoder`, no `atob` and
/// no `URL`, so the byte conversions are spelled out here.
///
/// The Safari world's `plugin_host.js` (Wave 2) implements the same names over
/// the page's own globals; `PluginHTMLSubsetTests`' spec file is what pins the
/// two to each other.
enum PluginBootstrapScript {

    /// Defines `luna` with the always-present members that need no native
    /// help. The runtime adds `register`, `parseURL`, `log` and `env` after.
    static let source = #"""
    (function () {
        "use strict";

        class LunaError extends Error {
            constructor(code, message, details) {
                super(message === undefined || message === null ? String(code) : String(message));
                this.name = "LunaError";
                this.code = String(code);
                this.details = details;
            }
        }

        const BASE64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

        function toBytes(input) {
            if (input instanceof Uint8Array) { return input; }
            if (Array.isArray(input)) { return new Uint8Array(input); }
            if (input && typeof input.length === "number") { return new Uint8Array(input); }
            throw new LunaError("bad-argument", "expected a Uint8Array");
        }

        function fromBase64(text) {
            const clean = String(text).replace(/[^A-Za-z0-9+/=]/g, "");
            const out = [];
            let buffer = 0;
            let bits = 0;
            for (let i = 0; i < clean.length; i++) {
                const character = clean.charAt(i);
                if (character === "=") { break; }
                const value = BASE64.indexOf(character);
                if (value < 0) { continue; }
                buffer = (buffer << 6) | value;
                bits += 6;
                if (bits >= 8) {
                    bits -= 8;
                    out.push((buffer >> bits) & 0xff);
                }
            }
            return new Uint8Array(out);
        }

        // The long strings here are joined from an array rather than grown with
        // `+=`. Each `+=` adds one fibre to a JavaScriptCore rope, so an
        // EPUB-sized payload built that way leaves a rope hundreds of thousands
        // deep, and every later read of it walks the whole chain. `join`
        // flattens once.
        function toBase64(bytes) {
            const data = toBytes(bytes);
            const parts = [];
            for (let i = 0; i < data.length; i += 3) {
                const b0 = data[i];
                const b1 = i + 1 < data.length ? data[i + 1] : 0;
                const b2 = i + 2 < data.length ? data[i + 2] : 0;
                parts.push(
                    BASE64.charAt(b0 >> 2)
                    + BASE64.charAt(((b0 & 3) << 4) | (b1 >> 4))
                    + (i + 1 < data.length ? BASE64.charAt(((b1 & 15) << 2) | (b2 >> 6)) : "=")
                    + (i + 2 < data.length ? BASE64.charAt(b2 & 63) : "="));
            }
            return parts.join("");
        }

        function utf8Encode(text) {
            const source = String(text);
            const out = [];
            for (let i = 0; i < source.length; i++) {
                let code = source.charCodeAt(i);
                if (code >= 0xd800 && code <= 0xdbff && i + 1 < source.length) {
                    const low = source.charCodeAt(i + 1);
                    if (low >= 0xdc00 && low <= 0xdfff) {
                        code = 0x10000 + ((code - 0xd800) << 10) + (low - 0xdc00);
                        i++;
                    }
                }
                // TextEncoder replaces an unpaired UTF-16 surrogate.
                if (code >= 0xd800 && code <= 0xdfff) code = 0xfffd;
                if (code < 0x80) {
                    out.push(code);
                } else if (code < 0x800) {
                    out.push(0xc0 | (code >> 6), 0x80 | (code & 63));
                } else if (code < 0x10000) {
                    out.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 63), 0x80 | (code & 63));
                } else {
                    out.push(
                        0xf0 | (code >> 18), 0x80 | ((code >> 12) & 63),
                        0x80 | ((code >> 6) & 63), 0x80 | (code & 63));
                }
            }
            return new Uint8Array(out);
        }

        function utf8Decode(bytes) {
            const data = toBytes(bytes);
            const parts = [];
            let first = true;
            for (let i = 0; i < data.length;) {
                const lead = data[i++];
                let code = lead;
                let count = 0;
                let lower = 0x80, upper = 0xbf;
                if (lead >= 0xc2 && lead <= 0xdf) { code &= 31; count = 1; }
                else if (lead >= 0xe0 && lead <= 0xef) {
                    code &= 15; count = 2;
                    if (lead === 0xe0) lower = 0xa0;
                    if (lead === 0xed) upper = 0x9f;
                } else if (lead >= 0xf0 && lead <= 0xf4) {
                    code &= 7; count = 3;
                    if (lead === 0xf0) lower = 0x90;
                    if (lead === 0xf4) upper = 0x8f;
                } else if (lead >= 0x80) { code = 0xfffd; }
                for (let j = 0; j < count; j++) {
                    const next = data[i];
                    if (i === data.length || next < lower || next > upper) {
                        // Reprocess an invalid continuation as the next lead.
                        code = 0xfffd;
                        break;
                    }
                    i++;
                    code = (code << 6) | (next & 63);
                    lower = 0x80; upper = 0xbf;
                }
                // Match TextDecoder's replacement mode and leading BOM rule.
                if (!first || code !== 0xfeff) parts.push(String.fromCodePoint(code));
                first = false;
            }
            return parts.join("");
        }

        // Resolves a `name`/`label`-shaped value the identical way the
        // manifest parser resolves a plugin's own copy tables (§2.2): a
        // string passes through; a table tries an exact language tag, then
        // that tag's language (`pt-BR` -> `pt`), then `en`. `plugin_host.js`
        // and `bridge.mjs` carry the same rule so a plugin sees one answer
        // wherever it runs.
        function localize(table) {
            if (typeof table === "string") { return table; }
            if (!table || typeof table !== "object") { return undefined; }
            var languages = (globalThis.luna && globalThis.luna.env
                && globalThis.luna.env.languages) || [];
            for (var i = 0; i < languages.length; i++) {
                if (Object.prototype.hasOwnProperty.call(table, languages[i])) {
                    return table[languages[i]];
                }
            }
            for (var i = 0; i < languages.length; i++) {
                var prefix = String(languages[i]).split("-")[0];
                if (Object.prototype.hasOwnProperty.call(table, prefix)) {
                    return table[prefix];
                }
            }
            return table.en;
        }

        globalThis.luna = {
            LunaError: LunaError,
            bytes: {
                fromBase64: fromBase64,
                toBase64: toBase64,
                utf8Encode: utf8Encode,
                utf8Decode: utf8Decode
            },
            localize: localize
        };
    })();
    """#

    /// Wraps the native `parseURL` so the value a plugin reads carries the
    /// `searchParams` methods §6.1 promises.
    static let parseURLFactory = #"""
    (function (raw) {
        return function (url, base) {
            const parsed = raw(String(url), base === undefined || base === null ? "" : String(base));
            if (!parsed || parsed.valid !== true) { return null; }
            const pairs = parsed.queryPairs || [];
            delete parsed.queryPairs;
            delete parsed.valid;
            parsed.searchParams = {
                get: function (name) {
                    for (let i = 0; i < pairs.length; i++) {
                        if (pairs[i].name === name) { return pairs[i].value; }
                    }
                    return null;
                },
                getAll: function (name) {
                    return pairs.filter(function (p) { return p.name === name; })
                        .map(function (p) { return p.value; });
                },
                has: function (name) {
                    return pairs.some(function (p) { return p.name === name; });
                },
                entries: function () {
                    return pairs.map(function (p) { return [p.name, p.value]; });
                }
            };
            return parsed;
        };
    })
    """#
}
