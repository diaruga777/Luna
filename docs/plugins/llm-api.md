# Luna plugin authoring contract

Deliver ONE ES2022 JavaScript file named `<name>.luna`. No imports, packages
or `require`. Luna runs the JavaScript and renders its data with native UI.
A plugin extracts articles, products or media from URLs, or exports saved items.

## File and manifest

The first non-whitespace token is a block comment with `luna-plugin` on its
first line and JSON on the following lines. Call `luna.register` once at top
level. Every supplied hook must be a function. Return JSON-compatible data;
cycles, BigInt, DOM objects and functions are not Models.

```js
/* luna-plugin
{
  "id": "user.example",
  "name": "Example",
  "version": "1.0.0",
  "api": 1,
  "produces": ["article"],
  "match": { "hosts": ["example.com", "*.example.com"] },
  "capabilities": ["fetch", "html"]
}
*/
luna.register({
  classify({ url }) {
    return /^\/articles\/[^/]+/.test(luna.parseURL(url)?.pathname || "")
      ? { kind: "article" } : false;
  },
  async ingest({ url, page }) {
    const source = page?.html ? {ok:true, text:page.html, url:page.url} : await luna.fetch(url);
    if (!source.ok) return null;
    const doc = luna.html.parse(source.text, source.url);
    const body = doc.querySelector('article'); // choose this site's actual body
    if (!body || body.textContent.length < 300) return null;
    return {kind:"article", title:doc.title || url, html:body.innerHTML, baseURL:source.url};
  },
});
```

Adapt the host, path rule and extraction to the request. Never invent text,
prices or media URLs. Keep the plugin ID stable across updates.

- `id`: lowercase `[a-z0-9.-]`, up to 100 characters, no empty dot segments.
- `name`: non-empty, up to 40 characters; `description`: optional, up to 200.
- `version`: `major.minor.patch`; `api`: `1`.
- Ingest requires non-empty `produces` (`article`, `media`, `product`) and
  `match`: exact hosts, `*.example.com` (apex and subdomains), or `{any:true}`.
  Write hosts without a scheme, port or path.
- Host-specific plugins precede `match.any`. Within each group, higher
  integer `priority` runs first, then ID. Default is 0; bundled extractors use
  100. Use 101 to override one for the same host. A usable Model stops the walk.
- `capabilities`: only namespaces used by the plugin. Undeclared namespaces
  are absent; declared but unavailable ones reject `unavailable-here`.
- Human-facing text may be a language map such as `{en:"Name",es:"Nombre"}`;
  every value must be a string and `en` is required.

## Hooks and flow

```ts
classify({url, page?, context, intent?}): false | {kind, itemId?}
ingest({url, claim, page?, context, reason, saveId?, intent?}): Model | null
export(input): {text:string} | {url:string} | {file:FileHandle} | DeliveryStatus | null
```

All hooks may be async. `context` is `app`, `share`, `action` or `safari`;
`page` may supply `{url, html?, title?, source}`. Reuse its HTML if present.
`reason` is `save`, `resume`, `refresh`, `compare`, `rescue` or `reresolve`. `classify` should decide cheaply
from the URL (8-second budget). Ingest has a 30-second idle budget refreshed
by bridge activity. Return `null` to decline; Luna tries the next plugin and
then preserves the URL as a plain link. Ordinary errors also fall through and are logged.

Let `browser-deferred` propagate. A blanket catch returning null loses the
browser handoff. Media extractors should return false when
`intent === "transcribe"`; transcript plugins may then return an article.
No polling loops, busy waits or timers.

## Models

```ts
Article = {
  kind:"article", title:string, html?:string,
  author?:string, publishedAt?:string, language?:string,
  leadImageURL?:string, excerpt?:string, baseURL?:string,
  document?:{url:string,type:"pdf"|"epub"|"docx"|"rtf"|"html"|"md"|"txt",headers?:Record<string,string>},
  transcription?:{url:string,type:"audio"|"video",audioURL?:string,headers?:Record<string,string>,expiresAt?:number}
}
Media = {
  kind:"media", title?:string, author?:string, platform?:string, itemId?:string,
  thumbnailURL?:string, expiresAt?:number,
  assets:{url:string,type:"video"|"image"|"gif"|"audio",audioURL?:string,
          thumbnailURL?:string,quality?:string,headers?:Record<string,string>}[]
}
Product = {
  kind:"product", name:string, price:{amount:string,currency:string},
  imageURL?:string, brand?:string, productId?:string,
  identifiers?:{gtin?:string,mpn?:string,sku?:string},
  sellers?:{url:string,name?:string,price?:{amount:string,currency:string}}[]
}
```

Articles need HTML, a document or a transcription. Documents and
transcriptions are mutually exclusive; optional HTML precedes a transcript.
Use a decimal string for price (`"19.99"`) and the actual currency (`"USD"`).
Caps: title/name 300 characters, short strings 200, excerpt 1000, URLs 4096,
HTML 4 MB, assets 1–50, sellers up to 20. Media/document/transcription headers
allow user-agent, referer, cookie, accept, accept-language, origin and range.
Expiry is epoch seconds. Relative Model URLs resolve against the saved URL;
use absolute URLs or an article's baseURL after redirects.

## Helpers

There is no global DOM, `fetch`, `URL`, `TextEncoder` or `TextDecoder` in the
app. Use these helpers; all names in this section except fetch/html/text are
always available:

```js
luna.parseURL(url, base) // parsed fields or null; searchParams.get/getAll/has/entries
luna.log(message, data)
luna.localize({en:"Name",es:"Nombre"})
luna.env // {context,api,pluginId,version,locale,languages}
new luna.LunaError("code", "message")
luna.bytes.utf8Encode(text) // Uint8Array
luna.bytes.utf8Decode(bytes) // string, replaces malformed UTF-8
luna.bytes.fromBase64(text) // Uint8Array
luna.bytes.toBase64(bytes) // string
```

Declare `fetch`:

```js
const r = await luna.fetch(url); // or request object below
// r: {ok,status,url,redirected,headers,text?,base64?,truncated,bytes}
// text is a string, NOT a .text() method
await luna.fetch.text(url, options); // rejects non-2xx
await luna.fetch.json(url, options); // parses JSON, rejects invalid JSON
await luna.fetch.doc(url, options);  // needs html too; uses final URL as base
```

Requests: `{url, method?, headers?, userAgent?, body?, cookies?, redirect?,
maxBytes?, timeout?, as?}`. Timeout is seconds (default 20, capped at 120).
Body: string, `{json: value}`, `{form: fields}`, `{base64: text}`, or multipart.
Cookies: `shared` (default), `ephemeral`, `none`. Redirect: `follow` (default),
`manual`, `headThenGet`. Response form: `text` or `base64`.
User agents: `safari`, `googlebot`, `googlebot-mobile`, `bingbot`, `facebookbot`
or a literal string. Helpers accept the same request options except `url`/`as`.

Declare `html` (includes `luna.text`):

```js
const doc = luna.html.parse(html, baseURL);
doc.querySelector(css); doc.querySelectorAll(css); // element or null; array
// elements: textContent, innerHTML, outerHTML, children, parentElement, tagName,
// getAttribute, hasAttribute, attributes, matches, closest, absoluteURL(attr)
// documents also have title, documentElement, head and body
// Select metadata explicitly with doc.querySelector(...).
luna.html.jsonLD(doc); // objects; flattens @graph, skips bad JSON
luna.html.jsonScripts(doc, type); // default: application/ld+json
// Select the body with DOM/CSS, or bundle docs/plugins/lib/web.js.
luna.html.text(html);
luna.text.clean(text);
// Parse prices and dates in your plugin; return declared decimal/ISO values.

```

Selectors support tags, classes, IDs, attributes, descendant/child
combinators, `:not`, `:first-child`, `:nth-child`; no `:has` or `:contains`.
Omit unknown optional fields. Use `element.absoluteURL("src")` or
`luna.parseURL(value, finalURL)?.href` for relative media URLs.

## Exports and settings

An export-only plugin omits `produces`/`match` and registers `export`:

```js
/* luna-plugin
{"id":"user.copy-markdown","name":"Copy Markdown","version":"1.0.0","api":1,
 "export":{"kinds":["article"],"input":"markdown","title":"Copy Markdown"}}
*/
luna.register({ export(input) { return {text:input.text}; } });
```

Available input formats: article → url/epub/pdf/docx/markdown/text/html/json;
media → url/json/file; product → url/json. Every declared kind must support
`input`. Text formats use `input.text`; files use `input.file`; JSON uses
`input.json`. Input also includes kind, format, saveId, url and title.
Return exactly one of `text`, `url`, `file` or `status`; null means no share
output. Delivery statuses are `sent`, `failed` or `retry`, with optional
message/hard/remoteName. A queued destination additionally declares
`export.destination:true` and requires the full destination/device contract.

Declare capabilities before using them:

- `settings`: `await luna.settings.get(key)`, `.all()`, `.set(key,value)`.
  Schema: `settings:[{key:"endpoint",type:"url",label:"Endpoint",required:true}]`.
  Types: text/email/url/password/number/toggle/choice/pairedDevice/action/info.
  Choice needs `options:[{id,label}]`. Keys use ASCII letters/digits/underscore,
  no leading underscore or duplicates. Booleans must be true/false.
- `secrets`: `await luna.secrets.get/set/delete`. For a token, declare a
  password field with `secret:true` and read it through secrets.get.
  settings.get masks stored secrets as `""`. Secret writes are app-only.
- `storage`: await get/set/delete/keys; JSON values up to 256 KB per key.
- `browser`: await open({url,saveId?,detect}); returns HTML and cookieHeader.
  detect is JS text returning wait/challenge/done/error. Extensions defer.
- `files`, `crypto`, `downloads`, `ui`, `mail`, `notifications`, `bluetooth`,
  `wifi`, `exports`: specialized APIs; consult the full API and bundled
  Kindle/Xteink implementations before writing device/delivery code.

## Verify

Check the JSON header, capabilities, hook names, path matching and Model
fields. Return false on unrelated paths and null on missing content. Keep
browser deferrals intact. Use saved fixtures when running the Node harness;
passing validation is not proof of live extraction or delivery. Test in Luna.

Core never supplies native extraction after plugins decline. The retired helpers
`luna.html.article/meta` and `luna.text.price/date` reject at runtime. Helpers in
`docs/plugins/lib/` are source to embed in a plugin, not implicit runtime globals.
For seller discovery handle `reason: "compare"` and return validated product sellers;
refresh uses the same owner with `reason: "refresh"`.
