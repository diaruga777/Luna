# Luna plugin API (for writing an ingest plugin)

Luna is an iOS app that saves links: articles, products with a price, and
media files. A plugin is ONE JavaScript file (ES2022, no `import`/`export`/
`require`, no libraries) that turns a URL into a **Model** Luna saves. Luna
renders the Model itself; a plugin never draws UI.

Deliver the plugin as a file named `<name>.luna`.

## 1. File shape

```js
/* luna-plugin
{
  "id": "user.example.com",
  "name": "Example",
  "version": "1.0.0",
  "api": 1,
  "produces": ["article"],
  "match": { "hosts": ["example.com", "*.example.com"] },
  "priority": 0,
  "capabilities": ["fetch", "html"]
}
*/
luna.register({
  classify({ url }) { /* fast: decide from the URL alone */ },
  async ingest({ url, claim }) { /* fetch, parse, return a Model or null */ },
});
```

The header comment is the first thing in the file. Its first line is exactly
`luna-plugin`; the rest of the comment is one JSON object. Luna reads the
header without running the code. The body calls `luna.register` exactly once
at top level.

| Field | Rule |
| --- | --- |
| `id` | lowercase `[a-z0-9.-]`, ≤ 100 chars, stable across versions |
| `name` | ≤ 40 chars |
| `version` | `major.minor.patch` |
| `api` | `1` |
| `produces` | non-empty subset of `"article"`, `"media"`, `"product"` |
| `match` | `{ "hosts": [...] }` exact hosts or `"*.host"` wildcards, or `{ "any": true }` for URL-shape plugins |
| `priority` | integer, higher runs first; default 0 |
| `capabilities` | only the `luna.*` namespaces the code calls (`fetch`, `html`, `storage`, `settings`, `secrets`, `files`, `crypto`, `browser`, …). An undeclared namespace is `undefined`. |
| `description` | optional, ≤ 200 chars |

## 2. Hooks

Each hook receives exactly one JSON argument.

```ts
classify({ url, page?, context }): false | { kind: "article"|"media"|"product", itemId?: string }
ingest({ url, claim: { kind, itemId? }, page?, reason, context }): Promise<Model | null>
```

- `classify` runs for every matching plugin, in priority order, on every
  save. Budget 8 s; it should need none of it. Decide from the URL's path and
  query. Return `false` for anything that is not this content. The first
  plugin to claim wins.
- `ingest` runs for the plugin that claimed. Budget 30 s of idle time (each
  `luna.fetch` resets it). Return `null` when the page turns out to have no
  such content; Luna continues with its own extraction. Throwing an error
  is logged and treated like `null`.
- `page` is present only when the save started from Safari with the page
  already open: `{ url, html?, title?, source }`. Use it when present to avoid
  a fetch. `context` is `"app" | "share" | "action" | "safari"`.

## 3. Models

Strings are capped (title/name 300 chars, others 200, excerpt 1000, URLs
4096, article `html` 4 MB). A relative URL is resolved against the page URL.
Never invent a value; omit an optional field you cannot read.

```ts
interface ArticleModel {
  kind: "article"; title: string; html: string;     // html: the COMPLETE body as clean HTML
  author?: string; publishedAt?: string;            // ISO 8601
  language?: string; leadImageURL?: string; excerpt?: string; baseURL?: string;
  document?: { url: string; type: "pdf"|"epub"|"docx"|"rtf"|"html"|"md"|"txt" };  // a file Luna parses instead of html
}
interface ProductModel {
  kind: "product"; name: string;
  price: { amount: string; currency: string };      // amount "129.99" (digits and a dot), currency ISO 4217
  imageURL?: string; brand?: string; productId?: string;
  identifiers?: { gtin?: string; mpn?: string; sku?: string };
  sellers?: { url: string; name?: string; price?: { amount: string; currency: string } }[];
}
interface MediaModel {
  kind: "media"; title?: string; author?: string; thumbnailURL?: string; itemId?: string;
  assets: { url: string; type: "video"|"image"|"gif"|"audio";
            thumbnailURL?: string; audioURL?: string; quality?: string;
            headers?: Record<string,string> }[];    // 1–50 direct file URLs; headers only user-agent, referer, cookie, accept, accept-language, origin, range
  expiresAt?: number;                               // epoch seconds, for signed URLs
}
```

Article `html` keeps `p`, `h2`–`h4`, `blockquote`, `ul`/`ol`/`li`, `pre`,
`img` (absolute `src`), `a` (absolute `href`), `figure`/`figcaption`, and
drops navigation, ads, related links, comments and scripts.

## 4. Always available

```ts
luna.register(hooks)
luna.parseURL(url, base?): { href, protocol, hostname, pathname, search, searchParams: Record<string,string>, hash } | null
luna.log(message, data?)                   // Luna's diagnostics log
luna.env: { context, api: 1, pluginId, version, locale, languages }
luna.LunaError                             // throw new luna.LunaError("code", "message")
luna.bytes: { fromBase64, toBase64, utf8Encode, utf8Decode }
```

## 5. `luna.fetch` (capability `fetch`)

```ts
luna.fetch(url | { url, method?, headers?, userAgent?, body?, cookies?, redirect?, maxBytes?, timeout?, as? })
  : Promise<{ ok, status, url, redirected, headers, text?, base64?, truncated, bytes }>
// method GET|POST|HEAD|PUT; body string | {json} | {form} | {base64}; cookies "shared"|"ephemeral"|"none";
// redirect "follow"|"manual"; timeout seconds (idle, default 20); as "text"|"base64"
// userAgent: "safari" | "googlebot" | "googlebot-mobile" | "bingbot" | "facebookbot" | a literal UA string

luna.fetch.text(url, opts?): Promise<string>        // GET, rejects "fetch-failed" on a non-2xx status
luna.fetch.json(url, opts?): Promise<unknown>       // GET + JSON.parse
luna.fetch.doc(url, opts?): Promise<HTMLDocument>   // GET + luna.html.parse with baseURL set to the final URL
```

Fetch only the page's own site (and its CDN for media). A blocked page
sometimes opens with `userAgent: "googlebot"` or with the `Referer` of the
site's front page.

## 6. `luna.html` (capability `html`)

```ts
luna.html.parse(html, baseURL?): HTMLDocument
luna.html.text(html): string                          // tags stripped, entities decoded, script/style dropped
luna.html.jsonScripts(doc, type?): unknown[]          // parsed <script type="application/ld+json"> (default) contents
luna.html.jsonLD(doc): object[]                       // same, with @graph flattened and bad JSON skipped
luna.html.meta(doc): { title?, description?, canonical?, image?, author?, published?, siteName?, language?, type? }
                                                      // <title>, OpenGraph, Twitter cards, meta author, article:published_time, link canonical, html lang, JSON-LD
luna.html.article(html, baseURL?): { title, html, text, author?, publishedAt?, leadImageURL?, excerpt? } | null
                                                      // Luna's own main-content extraction; null when the page has no article body
```

`HTMLDocument` / `HTMLElement`:

```ts
querySelector(css), querySelectorAll(css) → Array, closest(css), matches(css)
textContent, innerHTML, outerHTML, children, parentElement, tagName (upper-case)
getAttribute(name), hasAttribute(name), attributes, absoluteURL(attr)   // resolves href/src against the base
doc.title, doc.documentElement, doc.head, doc.body
```

Selectors: type, `.class`, `#id`, `[attr]`, `[attr=v]`, `^=`, `$=`, `*=`,
descendant and `>` child combinators, `:not()`, `:first-child`, `:nth-child()`.
No `:has()`, no `:contains()`.

## 7. `luna.text` (with capability `html`)

```ts
luna.text.price(s): { amount: string; currency?: string } | null   // "$1,299.00" → {amount:"1299.00",currency:"USD"}; "1.299,00 €" → {amount:"1299.00",currency:"EUR"}
luna.text.date(s): string | null                                    // common absolute dates → ISO 8601; relative dates → null
luna.text.clean(s): string                                          // entities decoded, whitespace collapsed, trimmed
```

## 8. Other namespaces (declare only if used)

- `storage` — `luna.storage.get/set/delete/keys`, per-plugin JSON key/value, ≤ 256 KB a value.
- `settings` — `luna.settings.get(key)`; values a user typed into Settings for fields the manifest declares under `"settings": [{ "key", "label", "type": "text"|"secret"|"toggle"|"choice" }]`.
- `secrets` — `luna.secrets.get/set/delete`, Keychain-backed.
- `crypto` — `sha256`, `hmacSHA256`, `randomBytes` (base64 in and out).
- `browser` — `luna.browser.open({ url, detect })` shows the page to the user to pass a login or challenge, then returns `{ html, cookieHeader }`. Only for pages that truly need a person.
- `files`, `downloads`, `ui`, `mail`, `notifications`, `bluetooth`, `wifi`, `exports` exist for export plugins and device integrations; an ingest plugin does not need them.

## 9. Errors

Every rejection is a `luna.LunaError` with `.code`: `bad-argument`,
`fetch-failed`, `network-refused` (blocked host), `too-large`,
`unavailable-here` (a namespace this process cannot serve), `cancelled`.
Catch what you can recover from; otherwise return `null` from `ingest`.

## 10. Complete examples

Article, using the metadata and content helpers:

```js
/* luna-plugin
{"id":"user.example.com","name":"Example","version":"1.0.0","api":1,"produces":["article"],"match":{"hosts":["example.com","*.example.com"]},"capabilities":["fetch","html"]}
*/
luna.register({
  classify({ url }) {
    const u = luna.parseURL(url);
    return u && /^\/\d{4}\/\d{2}\/[^/]+/.test(u.pathname) ? { kind: "article" } : false;
  },
  async ingest({ url }) {
    const doc = await luna.fetch.doc(url);
    const meta = luna.html.meta(doc);
    const article = luna.html.article(doc.outerHTML, url);
    if (!article) return null;
    return {
      kind: "article",
      title: meta.title || article.title,
      html: article.html,
      author: meta.author || article.author,
      publishedAt: luna.text.date(meta.published || article.publishedAt || ""),
      leadImageURL: meta.image || article.leadImageURL,
      language: meta.language,
    };
  },
});
```

Product, from JSON-LD with a DOM fallback:

```js
/* luna-plugin
{"id":"user.shop.example","name":"Example Shop","version":"1.0.0","api":1,"produces":["product"],"match":{"hosts":["shop.example"]},"capabilities":["fetch","html"]}
*/
luna.register({
  classify({ url }) {
    return /\/products\/[^/]+/.test(luna.parseURL(url)?.pathname || "") ? { kind: "product" } : false;
  },
  async ingest({ url }) {
    const doc = await luna.fetch.doc(url);
    const ld = luna.html.jsonLD(doc).find((o) => o["@type"] === "Product");
    if (ld && ld.offers) {
      const offer = Array.isArray(ld.offers) ? ld.offers[0] : ld.offers;
      return { kind: "product", name: ld.name, brand: ld.brand?.name || ld.brand,
               imageURL: Array.isArray(ld.image) ? ld.image[0] : ld.image,
               price: { amount: String(offer.price), currency: offer.priceCurrency } };
    }
    const name = doc.querySelector("h1")?.textContent;
    const price = luna.text.price(doc.querySelector(".price")?.textContent || "");
    if (!name || !price?.currency) return null;
    return { kind: "product", name: luna.text.clean(name), price, imageURL: luna.html.meta(doc).image };
  },
});
```

Media, from a JSON API the page's site exposes:

```js
/* luna-plugin
{"id":"user.clips.example","name":"Clips","version":"1.0.0","api":1,"produces":["media"],"match":{"hosts":["clips.example"]},"capabilities":["fetch"]}
*/
luna.register({
  classify({ url }) {
    const id = luna.parseURL(url)?.pathname.match(/^\/v\/([A-Za-z0-9_-]+)/)?.[1];
    return id ? { kind: "media", itemId: id } : false;
  },
  async ingest({ claim }) {
    const info = await luna.fetch.json(`https://clips.example/api/v/${claim.itemId}`);
    if (!info?.mp4) return null;
    return { kind: "media", title: info.title, thumbnailURL: info.poster,
             assets: [{ url: info.mp4, type: "video", thumbnailURL: info.poster }] };
  },
});
```

## 11. Checklist before answering

- Header parses as JSON; `id`, `name`, `version`, `api`, `produces`, `match` present.
- Every `luna.*` namespace the code calls is in `capabilities`; nothing extra.
- `classify` returns `false` for other pages on the same site.
- `ingest` returns only kinds listed in `produces`, with the required fields
  (`article`: `title`, `html`; `product`: `name`, `price.amount`,
  `price.currency`; `media`: `assets[].url`, `assets[].type`), or `null`.
- No invented text, prices or URLs. No loops that wait. Errors caught.
