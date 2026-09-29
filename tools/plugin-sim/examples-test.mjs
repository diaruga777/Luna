import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { createBridge } from "./bridge.mjs";
import { parseHeader, manifestErrors } from "./manifest.mjs";
const root = new URL("../../", import.meta.url);
const examples = new URL("docs/plugins/examples/", root);
const bundled = new URL("LunaLibraries/Sources/LunaBundledPlugins/Plugins/", root);
for (const dir of [examples, bundled]) {
  for (const file of readdirSync(dir).filter((name) => name.endsWith(".js"))) {
    const result = spawnSync(process.execPath, [fileURLToPath(new URL("run.mjs", import.meta.url)), "validate", fileURLToPath(new URL(file, dir))], {encoding:"utf8"});
    assert.equal(result.status, 0, `${file}: ${result.stdout}\n${result.stderr}`);
  }
}
for (const [name, url, fixture, kind] of [
  ["minimal-media.js", "https://clipvault.example/clip/abc123", "clipvault/abc123.html", "media"],
  ["minimal-article.js", "https://journal.example/articles/reading", "journal/reading.html", "article"],
  ["minimal-product.js", "https://shop.example/products/widget", "shop/widget.html", "product"],
]) {
  const source = readFileSync(new URL(name, examples), "utf8");
  const manifest = parseHeader(source);
  assert.deepEqual(manifestErrors(manifest), []);
  let requests = 0;
  const html = readFileSync(new URL(`fixtures/${fixture}`, examples), "utf8");
  const finalURL = `${new URL(url).origin}/redirected/story`;
  const luna = createBridge({capabilities:manifest.capabilities, fetchImpl: async () => {
    requests++;
    return {status:200, url:finalURL, redirected:true, headers:new Map(), arrayBuffer:async () => Buffer.from(html)};
  }});
  new Function("luna", source)(luna);
  const hooks = luna.__registeredHooks;
  const claim = await hooks.classify({url, context:"app"});
  assert.equal(claim.kind, kind, name);
  assert.equal(await hooks.classify({url:`${new URL(url).origin}/about`, context:"app"}), false, name);
  const fetched = await hooks.ingest({url, claim, context:"app", reason:"save"});
  assert.equal(fetched.kind, kind, name);
  assert.equal(requests, 1, name);
  const snapshot = await hooks.ingest({url, claim, page:{url:finalURL, html, source:"safari"}, context:"safari", reason:"save"});
  assert.equal(snapshot.kind, kind, name);
  assert.equal(requests, 1, `${name} must reuse the supplied page`);
  if (kind === "article") assert.equal(fetched.baseURL, finalURL);
  if (kind === "product") assert.deepEqual(fetched.price, {amount:"29.95",currency:"USD"});
  if (kind === "media") {
    assert.equal(await hooks.classify({url, intent:"transcribe", context:"app"}), false);
    const relative = await hooks.ingest({url, claim, page:{url:finalURL, html:'<meta property="og:video" content="clip.mp4">'}, context:"safari", reason:"save"});
    assert.equal(relative.assets[0].url, `${new URL(url).origin}/redirected/clip.mp4`);
  }
}
console.log("Bundled plugins validate; authoring starters pass fetch, page and redirect checks");
