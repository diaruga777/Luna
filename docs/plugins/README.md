# Write a Luna plugin

A plugin is one JavaScript file with a JSON header and one `luna.register`
call. It either extracts an article, media item or product from a URL, or
exports a saved item. Luna owns the UI. Only central Luna runs plugins;
the Reader, Downloader and Price Tracker sibling apps use their native paths.

## Start from a working file

| Task | Starter | What to change |
| --- | --- | --- |
| Read an article | [minimal-article.js](examples/minimal-article.js) | Host, article path rule, extraction if needed |
| Save a video | [minimal-media.js](examples/minimal-media.js) | Host, clip path rule, video selector |
| Track a product | [minimal-product.js](examples/minimal-product.js) | Host, product path rule, price source |
| Send Markdown to a webhook | [export-webhook.js](examples/export-webhook.js) | Delivery requirements; the user sets the endpoint |

From the repository root:

```sh
npm ci --prefix tools/plugin-sim
cp docs/plugins/examples/minimal-media.js my-plugin.luna
node tools/plugin-sim/run.mjs validate my-plugin.luna
node tools/plugin-sim/run.mjs test my-plugin.luna https://clipvault.example/clip/abc123 \
  --fixture docs/plugins/examples/fixtures/clipvault
```

Change the manifest's `id`, `name`, `match.hosts`, and the path/selector rules
for your site. Keep the ID stable for updates. Import the `.luna` file into
Luna and review its permissions and draft test. A `.js` file works for manual
plugin import too. Run a real save in Luna before relying on it.

The fixture command makes no network requests. A report with `ok: true`
means the checks passed; look at `result.ingest` to see the actual Model.
`null` is a legal decline, not successful extraction. The Node harness checks
common shapes; native draft validation checks the full Model decoder.

For autocomplete, put this **after** the JSON header (adjust the path when
moving the file):

```js
/// <reference path="./tools/plugin-sim/luna-plugin.d.ts" />
```

## The contract

```js
/* luna-plugin
{
  "id": "user.example",
  "name": "Example",
  "version": "1.0.0",
  "api": 1,
  "produces": ["article"],
  "match": { "hosts": ["example.com"] },
  "capabilities": ["fetch", "html"]
}
*/
luna.register({
  classify({ url }) {
    return /^\/articles\/[^/]+/.test(luna.parseURL(url)?.pathname || "")
      ? { kind: "article" } : false;
  },
  async ingest({ url, page }) {
    const source = page?.html ? { ok: true, text: page.html, url: page.url } : await luna.fetch(url);
    if (!source.ok) return null;
    const doc = luna.html.parse(source.text, source.url);
    const body = doc.querySelector('article'); // choose this site's actual body
    if (!body || body.textContent.length < 300) return null;
    return {kind:"article", title:doc.title || url, html:body.innerHTML, baseURL:source.url};
  },
});
```

The header must be the first non-whitespace token. Its first comment line is
`luna-plugin`; the rest is JSON. No Markdown fences inside the file.

- Use ES2022 without imports, packages or `require`. The app has no DOM,
  global `fetch`, `URL`, `TextEncoder`, `TextDecoder` or timers. Use `luna`
  helpers. Node having a global does not make it available in Luna.
- Register once at top level. Hooks must be functions; Luna captures their
  values at registration. Return JSON data, not DOM nodes, functions, BigInt
  or cyclic objects. Hooks may be synchronous or async.
- `classify` returns `false` or `{ kind, itemId? }`; `kind` must be in
  `produces`. Decide from the URL when possible. The budget is 8 seconds.
- `ingest` receives that claim, the URL, optional page snapshot, context,
  reason, optional save ID and intent. Return a Model or `null`. Bridge
  activity refreshes its 30-second idle budget.
- A decline, ordinary error or invalid Model lets Luna try the next plugin,
  then preserves the URL as a plain link. Let `browser-deferred` propagate so Luna can pause
  the save for a browser step. Avoid blanket catches that return `null`.
- `page` may contain already-fetched HTML, including a Safari snapshot.
  Reuse it. When fetching, resolve relative links against the final response
  URL; `luna.fetch.doc` and `element.absoluteURL(attr)` do this for you.
- Media extractors should decline `intent === "transcribe"` so a transcript
  plugin can handle the request.

## Matching and precedence

Exact hosts match themselves. `"*.example.com"` matches both `example.com`
and its subdomains. Write hostnames without a scheme, port or path.
`{ "any": true }` is for plugins that recognize content from URL shape.

Host-specific plugins run before `match.any` plugins. Within each group,
higher `priority` runs first, then ID. Default priority is 0; bundled site
extractors use 100. Choose 101 when intentionally overriding an extractor
for the same host. The first usable Model ends the walk. Using the same ID
as another plugin replaces it rather than adding another candidate.

## Use the helpers

| Need | API |
| --- | --- |
| Parse a URL safely | `luna.parseURL(url, base?)` → parsed URL or `null`; `searchParams.get("id")` |
| Read JSON | `await luna.fetch.json(url, options?)` |
| Read an HTML document | `await luna.fetch.doc(url, options?)` — needs `fetch` and `html` |
| Select article text | Use DOM selectors or bundle `lib/web.js` into your plugin |
| Read structured data | `luna.html.jsonScripts(doc)` / `luna.html.jsonLD(doc)`; interpret it in your plugin |
| Clean text | `luna.text.clean` — price/date interpretation belongs in the plugin |
| Convert text / bytes | `luna.bytes.utf8Encode/utf8Decode/fromBase64/toBase64` |
| Inspect a failure | `luna.log(message, data?)`; `error.code` for bridge failures |

Declare each capability you call. Undeclared namespaces are absent. Declared
capabilities unavailable in a process reject `unavailable-here`. `register`,
`parseURL`, `log`, `bytes`, `env`, `LunaError` and `localize` are always present.

`luna.fetch` returns a response object with `text` as a string, not a
`.text()` method. `fetch.text/json/doc` reject non-success HTTP statuses.
Fetch `timeout` is in **seconds**; the CLI's `--timeout` is in **milliseconds**.

## Models and exports

- Article: `{ kind: "article", title, html }`, or use `document` (PDF/EPUB/etc.)
  or `transcription` (audio/video) as the body. A document and a transcription
  cannot appear together. HTML is optional when either supplies the body.
- Media: `{ kind: "media", assets: [{ url, type: "video" }] }`. A separate
  audio track belongs in that asset's `audioURL`, not a second video asset.
- Product: `{ kind: "product", name, price: { amount: "19.99", currency: "USD" } }`.
  Preserve the amount as a decimal string; never invent a missing currency.
- Export-only: omit `produces` and `match`. Declare `export: { kinds, input,
  title }` and register `export(input)`. For Markdown/text/HTML input, read
  `input.text`; for EPUB/PDF/DOCX/media files, read `input.file`. The export
  format must support every declared kind. Use the webhook starter or the
  full API's device/destination contract.

## References and tests

- [Full API and limits](api.md)
- [Compact reference for AI authoring](llm-api.md)
- [Type definitions](../../tools/plugin-sim/luna-plugin.d.ts)
- [Harness options and limitations](../../tools/plugin-sim/README.md)
- [Internal architecture](../../claudedocs/plugins.md)

Run `npm test --prefix tools/plugin-sim` to check the harness, shared manifest
and HTML cases, bundled registrations, starters, and their TypeScript types.
The simulator suite additionally checks native bridges, import/rollback,
concurrency, adoption, exports, and Safari behavior.

Core never supplies native extraction after plugins decline. The retired helpers
`luna.html.article/meta` and `luna.text.price/date` reject at runtime. Helpers in
`docs/plugins/lib/` are source to embed in a plugin, not implicit runtime globals.
For seller discovery handle `reason: "compare"` and return validated product sellers;
refresh uses the same owner with `reason: "refresh"`.
