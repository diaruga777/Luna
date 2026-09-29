// Host primitives used by every plugin. No network or app state.
import assert from "node:assert/strict";
import { createBridge } from "./bridge.mjs";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const luna = createBridge();
assert.equal(luna.parseURL("not a url"), null);
assert.equal(luna.parseURL("/path", "bad base"), null);
assert.equal(luna.parseURL("../c", "https://example.com/a/b").href, "https://example.com/c");
for (const hooks of [[], { classify: 42 }, { ingest: {} }, { export: null }]) {
  assert.throws(() => createBridge().register(hooks), { code: "invalid-hooks" });
}
let reads = 0;
const hooks = { get classify() { reads++; return () => reads; } };
luna.register(hooks);
assert.equal(luna.__registeredHooks.classify(), 1);
assert.equal(Object.isFrozen(luna.__registeredHooks), true);
assert.throws(() => luna.register({}), { code: "already-registered" });
for (const name of ["secrets", "page", "ui", "mail", "notifications", "bluetooth", "wifi", "exports"]) {
  const bridge = createBridge({capabilities: [name]});
  assert.equal(createBridge()[name], undefined);
  await assert.rejects(bridge[name].someMethod(), {code: "unavailable-here"});
  assert.equal(await Promise.resolve(bridge[name]), bridge[name]);
}
// A request's timeout is seconds. Include body consumption and cancel the fetch.
const response = () => ({status: 200, headers: new Map(), async arrayBuffer() {return Buffer.from("ok");}});
const slow = createBridge({capabilities:["fetch"], fetchImpl: async () => {
  await new Promise((resolve) => setTimeout(resolve, 30));
  return response();
}});
assert.equal((await slow.fetch({url:"https://example.com", timeout:0.5})).text, "ok");
let signal;
const stalled = createBridge({capabilities:["fetch"], fetchImpl: async (_url, opts) => {
  signal = opts.signal;
  return {...response(), arrayBuffer: () => new Promise(() => {})};
}});
await assert.rejects(stalled.fetch({url:"https://example.com", timeout:0.02}), {code:"timeout"});
assert.equal(signal.aborted, true);
for (const timeout of [0, -1, NaN, Infinity, "20", true])
  await assert.rejects(slow.fetch({url:"https://example.com", timeout}), {code:"bad-argument"});
console.log("plugin runtime primitive tests passed");

// Run the actual JSC bootstrap with no browser globals, comparing byte
// conversions to the platform TextEncoder/TextDecoder used by Safari.
const swift = readFileSync(new URL("../../LunaLibraries/Sources/LunaPluginRuntime/PluginBootstrapScript.swift", import.meta.url), "utf8");
const bootstrap = swift.match(/static let source = #"""([\s\S]*?)"""#/)[1];
const context = vm.createContext({});
vm.runInContext(bootstrap, context);
const nativeBytes = context.luna.bytes;
for (const text of ["", "héllo 🌙", "\ud800", "\udc00", "a\ud800b", "\ud800\ud800\udc00", "\ufeffhi"]) {
  const expected = [...new TextEncoder().encode(text)];
  assert.deepEqual([...nativeBytes.utf8Encode(text)], expected);
  assert.deepEqual([...luna.bytes.utf8Encode(text)], expected);
}
const vectors = [[], [0xef,0xbb,0xbf,65], [0xef,0xbb,0xbf,0xef,0xbb,0xbf], [0xe2,0x82], [0xe2,40,0xa1], [0xed,0xa0,0x80], [0xf4,0x90,0x80,0x80]];
for (let lead = 0; lead < 256; lead++) {
  vectors.push([lead], [lead,0x80,0x80,0x80,65], [lead,0xbf,0xbf,0xbf]);
}
for (const bytes of vectors) {
  const expected = new TextDecoder().decode(Uint8Array.from(bytes));
  assert.equal(nativeBytes.utf8Decode(bytes), expected, String(bytes));
  assert.equal(luna.bytes.utf8Decode(bytes), expected, String(bytes));
}
console.log(`${vectors.length} UTF-8 decoding vectors passed`);
