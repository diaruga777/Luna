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

        function toBase64(bytes) {
            const data = toBytes(bytes);
            let out = "";
            for (let i = 0; i < data.length; i += 3) {
                const b0 = data[i];
                const b1 = i + 1 < data.length ? data[i + 1] : 0;
                const b2 = i + 2 < data.length ? data[i + 2] : 0;
                out += BASE64.charAt(b0 >> 2);
                out += BASE64.charAt(((b0 & 3) << 4) | (b1 >> 4));
                out += i + 1 < data.length ? BASE64.charAt(((b1 & 15) << 2) | (b2 >> 6)) : "=";
                out += i + 2 < data.length ? BASE64.charAt(b2 & 63) : "=";
            }
            return out;
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
            let out = "";
            let i = 0;
            while (i < data.length) {
                const byte = data[i++];
                let code;
                if (byte < 0x80) {
                    code = byte;
                } else if (byte >= 0xc0 && byte < 0xe0) {
                    code = ((byte & 31) << 6) | (data[i++] & 63);
                } else if (byte >= 0xe0 && byte < 0xf0) {
                    code = ((byte & 15) << 12) | ((data[i++] & 63) << 6) | (data[i++] & 63);
                } else {
                    code = ((byte & 7) << 18) | ((data[i++] & 63) << 12)
                        | ((data[i++] & 63) << 6) | (data[i++] & 63);
                }
                if (code > 0xffff) {
                    code -= 0x10000;
                    out += String.fromCharCode(0xd800 + (code >> 10), 0xdc00 + (code & 1023));
                } else {
                    out += String.fromCharCode(code);
                }
            }
            return out;
        }

        globalThis.luna = {
            LunaError: LunaError,
            bytes: {
                fromBase64: fromBase64,
                toBase64: toBase64,
                utf8Encode: utf8Encode,
                utf8Decode: utf8Decode
            }
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
