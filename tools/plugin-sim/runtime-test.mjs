// Host primitives used by every plugin. No network or app state.
import assert from "node:assert/strict";
import { createBridge } from "./bridge.mjs";

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
console.log("plugin runtime primitive tests passed");
