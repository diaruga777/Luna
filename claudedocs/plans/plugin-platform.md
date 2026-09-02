# Plan: the Luna plugin platform (ingest + export plugins)

Status: approved direction, staged execution. Written 2026-09-02 from five
codebase surveys (ingest pipeline, media/price/article ingest, export/send/
Xteink/Safari, locked-save and hand-off paths, and a salvage review of the
unmerged `stage1/integration` branch) plus a four-round owner interview.
This document is the reference for every implementation wave. Keep it
current as waves land; the feature doc that outlives it is
`claudedocs/plugins.md`.

## 0. Decisions locked with the owner (2026-09-02)

| # | Question | Decision |
| --- | --- | --- |
| 1 | The unmerged `stage1/integration` module platform (29k lines) | Salvage per file after a real review. Reuse the JavaScriptCore runtime, capability injection, promise plumbing, fetch service, kv/collection bridge, log bridge, manifest-parser style, module store, consent flow and import coordinator. Drop the WKWebView extraction worker, HTML card UI, module-declared kinds, `luna.saves`, `luna.files` (as designed there), Storage v2 and the one-app consolidation. |
| 2 | What ports to plugins | **Only social/video media resolution.** Article and product ingest stay Swift. |
| 3 | Which apps get plugins | **Central Luna only** (`com.hsanabria.luna`, its share/action extensions, its Safari extension). Reader, Downloader and Price Tracker are untouched. |
| 4 | Plugin authors | Power users import; LLMs author plugins outside the app from a `.d.ts` + authoring skill. No in-app generator. |
| 5 | JS host | **JavaScriptCore in every native process**, with a native, SwiftSoup-backed `luna.html` query API. No WKWebView worker. |
| 6 | Trust | Header-declared capabilities; one plain-language consent screen at import; undeclared namespaces are absent at runtime; an update that adds capabilities re-consents. |
| 7 | CAPTCHA browser | From an extension the save enters a **locked** state (the existing `needsCaptcha` lock treatment, never "failed"). In the app the plugin's browser request presents the same cover-until-challenge WKWebView modal the archive unlock uses. The hook is re-run after the browser step with the browser's result. |
| 8 | Ordering | **Plugins first**, by declared priority, host pre-filter required; the Swift classifier is the floor. A plugin can override a host Swift already claims. |
| 9 | Safari | Hooks run in the **content-script isolated world** (no CSP there). `luna.html` is DOMParser-backed there; `luna.fetch`, storage and log relay through native messaging. The Safari appex runs no plugin JS natively. |
| 10 | Export ports | **Kindle and Xteink both port** to bundled destination plugins in central Luna; their Swift wiring is removed from central Luna at parity. Luna Reader keeps its Swift copies. |
| 11 | Plugin UI | Declarative settings schema rendered natively, `luna.storage` kv + collections, `luna.secrets` (Keychain), simple prompts. No plugin-authored views. |
| 12 | Article / Product models from plugins | Article = cleaned HTML fragment + metadata; Product = snapshot + optional sellers. Core stores both through the existing Swift paths; product refresh re-runs the owning plugin's ingest hook. |
| 13 | Plugin management | A visible **Settings → Plugins** category in central Luna. Import from **Files and paste only** (no URL import, no update checking in this pivot). |
| 14 | Media packaging | **One bundled plugin per platform**, YouTube included. The durable download engine re-invokes the owning plugin when a CDN URL expires on resume. |
| 15 | Export auto-send | Export plugins may declare themselves **destinations**; the core keeps the queue, retry/backoff and auto-send-by-source policy and calls the plugin per queued item. |
| 16 | Kickoff | All phases, staggered agent waves. |

## 1. Goal and non-goals

Luna's central app grows a plugin runtime. A plugin is **one JavaScript file**
that extends two of the three core steps: **ingest** (URL → predefined Model)
and **export** (stored save → transformed file or delivery). **Render is not
pluggable**: the three predefined renderers (article reader, media card and
player, price tracker) stay native and consume the three predefined Models.

Non-goals for this pivot: plugin-authored UI, plugin-declared content kinds,
URL import or update checking, a data-model rewrite, any change to the three
sibling apps, an in-app LLM plugin generator.

## 2. Architecture overview

### 2.1 Processes and execution hosts

| Process | Runs plugin JS in | classify | ingest | export | onBluetooth | `luna.browser` |
| --- | --- | --- | --- | --- | --- | --- |
| Central Luna app | JavaScriptCore (`LunaPluginRuntime`) | yes | yes | yes | yes | presents the lock modal |
| `LunaShare` / `LunaAction` appex | JavaScriptCore | yes | yes | no | no | defers: locks the save |
| `LunaSafari` appex (native handler) | **none** — relays messages, serves sources, runs `PluginFetchService` | – | – | – | – | – |
| Safari content-script world | the page's isolated world (`plugin_host.js` shim) | yes | yes | no | no | defers: hands off to the app |
| Live Activity widget, App Clips | none | – | – | – | – | – |

### 2.2 Native module map (SwiftPM, `LunaLibraries/`)

New targets, bottom-up. Dependencies listed are the complete set.

| Target | Depends on | Purpose | Linked by |
| --- | --- | --- | --- |
| `LunaPluginKit` | LunaAppConfig, LunaModels, LunaStorage, LunaURLClassification | Foundation-only: `PluginManifest` + parser, `PluginStore` (App Group), `BundledPluginCatalog` reader, `PluginFetchService`, `PluginKVStore`, `PluginSecretsStore`, `PluginBrowserRequestStore`, `PendingPluginModelStore`, capability names/copy keys | Luna app, LunaShare, LunaAction, **LunaSafari** |
| `LunaPluginRuntime` | LunaPluginKit, SwiftSoup, JavaScriptCore | `PluginRuntime` (JSC host), `PluginContext`, `PluginExecutionQueue`, capability bridges (`fetch`, `html`, `storage`, `secrets`, `log`, `files`, `bytes`, `crypto`, `parseURL`), hook invocation + result decoding | Luna app, LunaShare, LunaAction |
| `LunaPluginIngest` | LunaPluginRuntime, LunaIngest, LunaFetch | `PluginIngestStage` (classify walk + ingest), `PluginModelDecoder`, `PluginModelAdopters` consumers, browser deferral, diagnostics binding, `PluginMediaResolver` | Luna app, LunaShare, LunaAction |
| `LunaPluginExport` | LunaPluginRuntime, LunaSend, LunaEpub, LunaMailAccount | `PluginExportStage`, `ExportInputProducer`, `PluginDestination: ArticleDestination`, mail + notifications bridges, share-row provider | Luna app |
| `LunaPluginTransport` | LunaPluginRuntime, LunaSend (lock only; see §10.4) | `luna.bluetooth` (CoreBluetooth central + AccessorySetupKit), `luna.wifi` (NEHotspotConfiguration), `PluginBluetoothSessionLock`, background leases | Luna app |
| `LunaPluginUI` | LunaPluginRuntime, LunaPluginIngest, LunaPluginExport, LunaDesignSystem, LunaSavesUI, LunaArchiveReader | Settings → Plugins, import (Files/paste), consent, settings-schema renderer, prompts, `PluginBrowserViewController`, stage catalog | Luna app |
| `LunaBundledPlugins` | none (resources only) | the bundled `*.js` plugins as `Bundle.module` resources | Luna app, LunaShare, LunaAction, LunaSafari |

Model types and adopter protocols go into **`LunaModels/Plugin/`** (bottom of
the stack) so kind modules can provide witnesses without depending on the
plugin platform (§7.3). Link edges are added by a new idempotent script,
`scripts/add_plugin_links.rb`, modeled on `add_price_compare_links.rb`.

### 2.3 Composition rule

`PluginPlatformComposition.install()` (in `LunaPluginIngest`) is the single
root call. It is made by exactly three roots — `KindWiring+Luna.swift`,
`ShareEntry+Luna.swift`, `ActionEntry+Luna.swift` — after the kind packs.
`KindCompositionRootTests` gains two assertions: the three central roots call
it, and no other root does. The Safari handler does not compose plugins; it
uses `LunaPluginKit` directly.

## 3. The plugin file

### 3.1 Shape

One UTF-8 `.js` file. ES2022 as JavaScriptCore on iOS 18 supports it (async/
await, optional chaining, classes, `Promise`, typed arrays, `TextEncoder`).
No `import`/`export`/`require`. The file has two parts:

1. **The header**: the first non-whitespace token is a block comment that
   starts with `luna-plugin` on its first line and contains one JSON object.
   The header is parsed natively **without evaluating the script**, so the
   consent screen and the store never run untrusted code.
2. **The body**, which must call `luna.register(hooks)` exactly once at top
   level. `register` is the only global the body sees before registration;
   capability namespaces are installed before the first hook call.

```js
/* luna-plugin
{
  "id": "app.luna.instagram",
  "name": "Instagram",
  "version": "1.0.0",
  "api": 1,
  "produces": ["media"],
  "match": { "hosts": ["instagram.com", "*.instagram.com"] },
  "priority": 100,
  "capabilities": ["fetch", "html", "storage"]
}
*/
luna.register({
  async classify({ url }) {
    const u = luna.parseURL(url);
    const m = u.pathname.match(/^\/(p|reel|reels|tv)\/([A-Za-z0-9_-]+)/);
    return m ? { kind: "media", itemId: m[2] } : false;
  },
  async ingest({ url, page }) {
    const html = page?.html ?? (await luna.fetch({ url, userAgent: "googlebot" })).text;
    const doc = luna.html.parse(html, url);
    // ... read the embedded JSON, build assets ...
    return { kind: "media", title, thumbnailURL, assets };
  },
});
```

### 3.2 Manifest schema (`api: 1`)

| Key | Type | Required | Rules |
| --- | --- | --- | --- |
| `id` | string | yes | Reverse-DNS, `[a-z0-9.-]`, ≤ 100 chars. Identity across versions; storage, settings, secrets and save ownership key on it. |
| `name` | string | yes | ≤ 40 chars, shown in Settings and consent. |
| `version` | string | yes | `M.m.p`. Import of a lower or equal version over an installed one asks "Replace?". |
| `api` | integer | yes | Must equal `PluginAPIVersion.current` (1). Higher refuses import. |
| `description` | string | no | ≤ 200 chars. |
| `produces` | `("article"\|"media"\|"product")[]` | yes for ingest plugins | A returned Model of a kind not listed is a `malformedResult`. Central Luna accepts all three. |
| `match` | `{ hosts?: string[], any?: boolean }` | yes for ingest plugins | `hosts` are exact or `*.` wildcard suffixes, matched on the unwrapped URL's host; `any: true` plugins run only after every host-matched plugin has passed, whatever their `priority`. Empty `hosts` without `any` is an error. |
| `priority` | integer | no | Default 0. Higher runs first among matched plugins. Bundled plugins ship at 100 so an imported override at 101 wins. |
| `capabilities` | string[] | no | From §6. Unknown names refuse import. Omitted = none (only `parseURL`, `log`-less `register`). |
| `export` | `ExportDeclaration` | no | §9.1. |
| `settings` | `SettingField[]` | no | §11.1. |
| `bluetooth` | `BluetoothDeclaration` | no | §10.1. Requires capability `bluetooth`. |
| `background` | boolean | no | Default false. True lets `onBluetooth`/`export` run when the app is woken in the background. Shown on consent. |

Parsing is hand-written (`PluginManifestParser`), every error names the field
and line, as the prior branch's `ModuleManifestParser` did.

### 3.3 Hooks (`luna.register(hooks)`)

```ts
interface PluginHooks {
  classify?(input: ClassifyInput): ClassifyResult | Promise<ClassifyResult>;
  ingest?(input: IngestInput): Promise<Model | null>;
  export?(input: ExportInput): Promise<ExportResult>;
  onBluetooth?(event: BluetoothEvent, session: BluetoothSession | null): Promise<void>;
  onSettingsChanged?(changes: Record<string, unknown>): Promise<void>;
  onAction?(key: string): Promise<void>;   // settings buttons of type "action"
}
```

`register` validates: an ingest plugin (`produces` present) must define both
`classify` and `ingest`; an export plugin must define `export`; a `bluetooth`
declaration requires `onBluetooth`. A file that registers twice, never
registers, or throws at top level fails to load and is reported in Settings.

## 4. Ingest hooks

### 4.1 `classify`

```ts
interface ClassifyInput {
  url: string;                 // unwrapped, canonicalized by the core
  page?: PageSnapshot;         // present when the caller already has the page (Safari, share ext with HTML)
  context: "app" | "share" | "action" | "safari";
}
interface PageSnapshot {
  url: string;                 // the page's final URL
  html?: string;               // absent in Safari when the DOM is live; use luna.page
  title?: string;
  source: "safari" | "fetch" | "browser";
}
type ClassifyResult = false | { kind: "article" | "media" | "product"; itemId?: string; confidence?: number };
```

Rules: the runtime calls `classify` only for plugins whose `match` accepts
the host. `classify` may call `luna.fetch`/`luna.html` (the spec grants page
access to both hooks) but nothing else; any other namespace throws
`LunaError("not-available-in-classify")`. Budget 8 s wall (§7.5). The first
claim in priority order wins and the walk stops. All matched plugins pass →
the Swift `Classifier` runs unchanged.

### 4.2 `ingest`

```ts
interface IngestInput {
  url: string;
  claim: { kind: ModelKind; itemId?: string };   // what this plugin's classify returned
  page?: PageSnapshot;
  reason: "save" | "resume" | "refresh" | "reresolve" | "rescue";
  context: "app" | "share" | "action" | "safari";
  saveId?: string;             // present on resume/refresh/reresolve
}
```

| `reason` | Caller | Expectation |
| --- | --- | --- |
| `save` | a new save | Return the Model or `null` to decline. |
| `resume` | the app, after the lock modal | Same code path; `luna.browser.open` now returns the stored result (§8.3). |
| `refresh` | `PluginPriceFetcher` on a plugin-owned tracker store | Return a `product` Model; only `price` is read. |
| `reresolve` | `LiveMediaDownloadManager` when an asset URL fails (403/410/expired) | Return a `media` Model; assets are matched by `type`+`quality` and the job's URLs are replaced. |
| `rescue` | URL Rescue's `forceArticle` re-entry | As `save`. |

Returning `null` means "declined after reading the page": the walk continues
with the next matched plugin, then the Swift classifier. This closes the
prior plan's "claimed, then declined" blocker. Budget: the pipeline's 30 s
**idle** watchdog (`IdleTimeLimit`); every bridge call touches it.

### 4.3 The long-running download is declarative

The download is triggered by the **returned Model**, never by a call inside
the hook. A `media` Model's `assets` are what the durable engine downloads; an
`article` Model's optional `document` is a file the core fetches and imports
through `DocumentParser`. Reasons: the download must outlive the JS context
and the process (the engine already persists jobs and resumes them), the
Safari world cannot start one at all (it hands the Model to the app), and the
storage policy (in Luna vs Photos, Wi-Fi gating, auto-download by source)
is the user's setting, not the plugin's. `luna.downloads` exists only to
**read** job state (§6.9).

## 5. Models

TypeScript is the contract; `PluginModelDecoder` (Swift) validates strictly
and rejects unknown `kind`, missing required fields, non-http(s) URLs and
strings over the caps below. All URLs are resolved against `IngestInput.url`
when relative.

### 5.1 `MediaModel`

```ts
interface MediaModel {
  kind: "media";
  title?: string;              // ≤ 300 chars
  author?: string;
  thumbnailURL?: string;
  platform?: string;           // free text; the core maps known names onto ContentPlatform, else keeps the plugin id
  itemId?: string;
  assets: MediaAssetSpec[];    // 1…50, display order
  expiresAt?: number;          // epoch seconds; the engine re-resolves after this
}
interface MediaAssetSpec {
  url: string;
  type: "video" | "image" | "gif" | "audio";
  audioURL?: string;           // separate audio leg (Reddit/DASH style)
  dashManifestURL?: string;
  thumbnailURL?: string;
  estimatedBytes?: number;
  headers?: Record<string, string>;   // sent on the download request; allowlist: User-Agent, Referer, Cookie, Accept, Accept-Language, Origin, Range
  timeRange?: { start: number; end: number };
  quality?: string;            // "1080p", "audio-128k"; used to match legs on reresolve
}
```

Maps onto `MediaAsset` (LunaModels). One additive change: `MediaAsset` gains
`requestHeaders: [String: String]` (default empty); `LiveMediaDownloadManager`
applies it to each `URLSessionDownloadTask` and persists it in
`media_download_jobs` (§12).

### 5.2 `ArticleModel`

```ts
interface ArticleModel {
  kind: "article";
  title: string;
  author?: string;
  publishedAt?: string;        // ISO 8601
  html: string;                // the cleaned body fragment, ≤ 4 MB
  baseURL?: string;            // for relative links/images; default IngestInput.url
  leadImageURL?: string;
  excerpt?: string;
  language?: string;
  document?: { url: string; type: "pdf" | "epub" | "docx" | "rtf" | "html" | "md" | "txt"; headers?: Record<string, string> };
}
```

Adoption (`ArticleModelAdopter`, in LunaArticleIngest): `ArticleExtractor`
gains `convertTrusted(fragmentHTML:baseURL:title:author:) -> ArticleContent`
— the block conversion with readability scoring and boilerplate removal
skipped (the plugin already chose the body). Images are downloaded and the
thumbnail chosen by the existing code. With `document` present the file is
fetched (headers allowlisted as above) and imported like a shared document.
Result is `Outcome.article`, so `SurfaceSupport`, the store write and the
presenters are unchanged.

### 5.3 `ProductModel`

```ts
interface ProductModel {
  kind: "product";
  name: string;
  price: { amount: string; currency: string };   // amount as a decimal string, never a float
  imageURL?: string;
  brand?: string;
  productId?: string;
  identifiers?: { gtin?: string; mpn?: string; sku?: string; brand?: string };
  sellers?: { url: string; name?: string; price?: { amount: string; currency: string } }[];   // ≤ 20
}
```

Adoption (`ProductModelAdopter`, in LunaPriceIngest): builds `ProductInfo`
(`ProductCandidate` + `ProductPrice` + `ProductSellerInfo[]`) and returns
`Outcome.product`. The tracker's first store gets `plugin_id` set (§12) so
`PriceRefresher` routes that store through `PluginPriceFetcher`, which calls
the plugin's `ingest` with `reason: "refresh"` and reads `price`. When
`sellers` is present the Swift seller fan-out is skipped for that tracker
(the plugin owns comparison); when absent it runs as today.

### 5.4 Model → save ownership

Every save produced from a plugin Model carries `saves.plugin_id`. It routes
refresh and reresolve, lets Settings show "saved by <plugin>", and lets the
deck show the unknown-plugin notice when the owner is disabled or deleted
(the save still renders; only refresh/reresolve are unavailable).

## 6. The bridge (`luna.*`)

Everything is under one frozen `luna` object. Each namespace is a capability;
an undeclared one is **absent** (`luna.mail === undefined`), never a stub.
Always present without declaration: `luna.register`, `luna.parseURL`,
`luna.log`, `luna.bytes`, `luna.env`, `luna.LunaError`. Every async call
returns a Promise settled on the runtime's own queue (`PluginPromiseBox`,
salvaged). Binary data crosses the bridge as **base64 strings**; `luna.bytes`
converts.

| Capability | Namespace | app | share/action | Safari world | Notes |
| --- | --- | --- | --- | --- | --- |
| (none) | `parseURL`, `log`, `bytes`, `env`, `register` | ✓ | ✓ | ✓ | |
| `fetch` | `luna.fetch` | ✓ | ✓ | relayed | |
| `html` | `luna.html` | SwiftSoup | SwiftSoup | DOMParser | parity suite §13.3 |
| `page` | `luna.page` | – | – | ✓ live DOM | Safari only; elsewhere `PageSnapshot.html` |
| `storage` | `luna.storage` | ✓ | ✓ | relayed | |
| `secrets` | `luna.secrets` | ✓ | read-only | – | Keychain, App Group access group |
| `files` | `luna.files` | ✓ | ✓ | – | plugin-scoped scratch dir |
| `crypto` | `luna.crypto` | ✓ | ✓ | ✓ (SubtleCrypto) | sha256, hmacSHA256, randomBytes |
| `browser` | `luna.browser` | modal | defers → lock | defers → app | §8 |
| `downloads` | `luna.downloads` | ✓ read | ✓ read | – | |
| `settings` | `luna.settings` | ✓ | ✓ read | relayed read | |
| `ui` | `luna.ui` | ✓ | – | – | prompts, toast, share sheet |
| `mail` | `luna.mail` | ✓ | – | – | transport wired only in the app |
| `notifications` | `luna.notifications` | ✓ | – | – | never prompts |
| `bluetooth` | `luna.bluetooth` | ✓ | – | – | |
| `wifi` | `luna.wifi` | ✓ | – | – | |
| `exports` | `luna.exports` | ✓ | – | – | destination plugins only |

Calling a namespace that exists but is unavailable in the current process
rejects with `LunaError` code `unavailable-here`; the consent copy does not
promise otherwise.

### 6.1 Always present

```ts
luna.register(hooks: PluginHooks): void;
luna.parseURL(url: string, base?: string): ParsedURL;   // {href, protocol, host, hostname, port, pathname, search, hash, searchParams: {get, getAll, has, entries}}
luna.log(message: string, data?: unknown): void;         // DiagnosticLog category "plugin.<id>" + the bound SaveDiagnostics recorder
luna.bytes: { fromBase64(s): Uint8Array; toBase64(b: Uint8Array): string; utf8Encode(s): Uint8Array; utf8Decode(b): string };
luna.env: { context: "app"|"share"|"action"|"safari"; api: 1; pluginId: string; version: string; locale: string };
class luna.LunaError extends Error { code: string; details?: unknown }
```

### 6.2 `luna.fetch` (capability `fetch`)

Salvaged from `ModuleFetchService` and renamed `PluginFetchService`; it sits
directly on `URLSession`, not on `ArticleFetcher`.

```ts
luna.fetch(request: string | FetchRequest): Promise<FetchResponse>;
interface FetchRequest {
  url: string;
  method?: "GET" | "POST" | "HEAD" | "PUT";
  headers?: Record<string, string>;         // any header except Host/Content-Length; Cookie allowed
  userAgent?: "safari" | "googlebot" | "googlebot-mobile" | "bingbot" | "facebookbot" | string;   // named identities map to the CrawlerAgent strings and, for Google, the matching X-Forwarded-For
  body?: string | { base64: string } | { form: Record<string,string> } | { json: unknown } | { multipart: MultipartPart[] };
  cookies?: "shared" | "ephemeral" | "none" | "browser";   // browser = WKWebsiteDataStore.default() cookies (what the lock modal earned)
  redirect?: "follow" | "manual" | "headThenGet";
  maxBytes?: number;                         // ≤ WebFetchConstants.maxBytes
  timeout?: number;                          // seconds, default 20; idle-based
  as?: "text" | "base64" | "file";           // file → FileHandle in response.file (needs `files`)
}
interface MultipartPart { name: string; filename?: string; mime?: string; text?: string; base64?: string; file?: FileHandle }
interface FetchResponse { ok: boolean; status: number; url: string; redirected: boolean; headers: Record<string,string>; text?: string; base64?: string; file?: FileHandle; truncated: boolean; bytes: number }
```

`LiveNetworkPolicy.check` runs before every request; each request is written
to the plugin's diagnostic category and to the bound save trace.

### 6.3 `luna.html` (capability `html`)

A deliberately **small DOM subset** so three backings agree: SwiftSoup (JSC in
app/extensions), `DOMParser` (Safari world), and `linkedom` (the node dev
harness, §13.4). The parity suite runs one JS assertion file against all
three.

```ts
luna.html.parse(html: string, baseURL?: string): HTMLDocument;
interface HTMLNode {
  querySelector(css: string): HTMLElement | null;
  querySelectorAll(css: string): HTMLElement[];       // an Array, not a NodeList
  readonly textContent: string;
  readonly innerHTML: string;
  readonly outerHTML: string;
  readonly children: HTMLElement[];
  readonly parentElement: HTMLElement | null;
  readonly tagName: string;                            // upper-case
  getAttribute(name: string): string | null;
  hasAttribute(name: string): boolean;
  readonly attributes: Record<string, string>;
  matches(css: string): boolean;
  closest(css: string): HTMLElement | null;
  readonly baseURI: string;
  absoluteURL(attr: string): string | null;           // resolves href/src against baseURI (SwiftSoup absUrl; DOM: new URL)
}
interface HTMLDocument extends HTMLNode { readonly title: string; readonly documentElement: HTMLElement; readonly body: HTMLElement | null; readonly head: HTMLElement | null }
luna.html.text(html: string): string;                  // decode entities + strip tags
luna.html.jsonScripts(doc: HTMLDocument, type?: string): unknown[];   // parsed <script type="application/ld+json"|"application/json"> bodies, bad JSON skipped
```

Selectors are limited to the CSS level SwiftSoup supports (type, class, id,
attribute with `=`, `^=`, `$=`, `*=`, descendant/child combinators,
`:not()`, `:first-child`, `:nth-child`); the parity suite is the
specification. In JSC, the handle is a native object; the document is
released when the hook resolves.

### 6.4 `luna.page` (capability `page`, Safari only)

```ts
luna.page.document(): HTMLDocument;   // the live page wrapped in the same subset
luna.page.url(): string;
luna.page.title(): string;
luna.page.html(): string;              // documentElement.outerHTML snapshot
```

### 6.5 `luna.storage` (capability `storage`)

Salvaged `ModuleStorageBridge`. Plugin-scoped, App-Group SQLite, visible to
every process (Safari relays).

```ts
luna.storage.get(key: string): Promise<unknown | undefined>;
luna.storage.set(key: string, value: unknown): Promise<void>;     // JSON, ≤ 256 KB per value
luna.storage.delete(key: string): Promise<void>;
luna.storage.keys(prefix?: string): Promise<string[]>;
luna.storage.collection(name: string): Collection;
interface Collection {
  put(id: string, doc: object, index?: { k1?: string; k2?: string }): Promise<void>;
  get(id: string): Promise<object | undefined>;
  delete(id: string): Promise<void>;
  find(where: { k1?: string; k2?: string }, opts?: { limit?: number; offset?: number }): Promise<{ id: string; doc: object }[]>;
  count(where?: { k1?: string; k2?: string }): Promise<number>;
}
```

### 6.6 `luna.secrets` (capability `secrets`)

Keychain, App Group access group, item per `(pluginId, key)`.

```ts
luna.secrets.get(key: string): Promise<string | undefined>;
luna.secrets.set(key: string, value: string): Promise<void>;   // app only
luna.secrets.delete(key: string): Promise<void>;               // app only
```

### 6.7 `luna.files` (capability `files`)

A per-invocation scratch directory under the App Group
(`Plugins/scratch/<pluginId>/<invocationId>/`), reaped when the hook settles
unless a handle is returned from `export`.

```ts
interface FileHandle { readonly id: string; readonly name: string; readonly size: number; readonly mime?: string }
luna.files.write(name: string, data: string | { base64: string }, mime?: string): Promise<FileHandle>;
luna.files.read(handle: FileHandle, as: "text" | "base64"): Promise<string>;
luna.files.size(handle: FileHandle): Promise<number>;
```

### 6.8 `luna.crypto`

```ts
luna.crypto.sha256(data: string | { base64: string }): Promise<string>;                  // base64 digest
luna.crypto.hmacSHA256(key: { base64: string } | string, data: string | { base64: string }): Promise<string>;
luna.crypto.randomBytes(count: number): Promise<string>;                                  // base64
```

CryptoKit in JSC; SubtleCrypto in the Safari world.

### 6.9 `luna.downloads` (capability `downloads`, read only)

```ts
luna.downloads.jobs(): Promise<DownloadJob[]>;
luna.downloads.job(saveId: string): Promise<DownloadJob | undefined>;
interface DownloadJob { saveId: string; sourceURL: string; title?: string; phase: "queued"|"resolving"|"downloading"|"finished"|"failed"|"deferredUntilWiFi"; progress: number; receivedBytes: number; expectedBytes?: number; failure?: string }
```

Read from `media_download_jobs` via `LiveMediaDownloadManager`'s snapshot
API.

### 6.10 `luna.browser` (capability `browser`)

```ts
luna.browser.open(request: BrowserRequest): Promise<BrowserResult>;
interface BrowserRequest {
  url: string;
  userAgent?: "device-safari" | string;      // default: the device-matched Safari UA the archive unlock uses
  headers?: Record<string, string>;          // Referer, Accept-Language only
  cookies?: "persistent" | "ephemeral";      // default persistent (WKWebsiteDataStore.default())
  detect: string;                            // JS source evaluated in the page every 350 ms; must evaluate to "wait" | "challenge" | "done" | "error"
  title?: string;                            // modal title, default plugin name
  timeout?: number;                          // seconds the modal may stay open, default 300
}
interface BrowserResult { url: string; html: string; title: string; cookieHeader: string; cookies: { name: string; value: string; domain: string }[] }
```

Semantics per process are in §8. `detect` runs in the page's main world via
`evaluateJavaScript`; a plugin never receives a live DOM here, only the final
`html`. The result's `html` is capped at 6 MB.

### 6.11 `luna.settings` (capability `settings`)

```ts
luna.settings.get(key: string): Promise<unknown>;      // typed per schema; secrets return "" when set, never the value
luna.settings.set(key: string, value: unknown): Promise<void>;   // app only, validated against the schema
luna.settings.all(): Promise<Record<string, unknown>>;
```

### 6.12 `luna.ui` (capability `ui`, app only)

```ts
luna.ui.prompt(opts: { title: string; message?: string; placeholder?: string; keyboard?: "default"|"email"|"url"|"number"; secure?: boolean; default?: string }): Promise<string | null>;
luna.ui.confirm(opts: { title: string; message?: string; ok?: string; cancel?: string; destructive?: boolean }): Promise<boolean>;
luna.ui.choose(opts: { title: string; options: { id: string; label: string; detail?: string }[] }): Promise<string | null>;
luna.ui.toast(message: string): Promise<void>;
luna.ui.shareSheet(items: (FileHandle | { url: string } | { text: string })[]): Promise<void>;
```

Presented from the app's top presenter; rejects with `unavailable-here` in
extensions and when the app is in the background.

### 6.13 `luna.mail` (capability `mail`, app only)

```ts
luna.mail.send(message: MailMessage): Promise<{ status: "sent" }>;
interface MailMessage {
  to?: string[];              // omitted → native recipient picker (FriendsStore / RecipientPickerViewController); user cancel rejects with code "cancelled"
  subject: string;
  text?: string;
  html?: string;
  attachments?: { file: FileHandle; name?: string; mime?: string }[];   // ≤ 25 MB total
}
luna.mail.isConfigured(): Promise<boolean>;   // EmailAccountStore.shared.isReady
```

Native builds the MIME (`EmailMIMEBuilder`); JS never supplies raw headers.
The transport comes from `ArticleEmailTransportProvider.make`, so a send in
an extension rejects with `unavailable-here`.

### 6.14 `luna.notifications` (capability `notifications`, app only)

```ts
luna.notifications.post(n: { title: string; body?: string; identifier?: string; deepLink?: string }): Promise<{ posted: boolean }>;
luna.notifications.clear(identifier?: string): Promise<void>;
```

Never requests authorization (the launch invariant); `posted: false` when
not authorized.

### 6.15 `luna.bluetooth` and `luna.wifi` — §10.

### 6.16 `luna.exports` (capability `exports`, destination plugins, app only)

```ts
luna.exports.deliverQueued(): Promise<{ delivered: number; remaining: number }>;   // runs ArticleSendCoordinator.deliverQueuedSends(toDestinationID: pluginId), ignoring backoff
luna.exports.queued(): Promise<{ saveId: string; title: string; queuedAt: string }[]>;
luna.exports.markSent(saveId: string): Promise<void>;   // for reconciliation (e.g. the reader reports a book already present)
```

## 7. Native design: runtime and ingest integration

### 7.1 `LunaPluginRuntime`

Salvaged and renamed from `LunaJSRuntime` (`JSModuleRuntime` →
`PluginRuntime`, `ModuleContext` → `PluginContext`, `ModuleExecutionQueue` →
`PluginExecutionQueue`, `ModuleCapability*` → `PluginCapability*`,
`ModuleClaim`/`ModuleVerdict` → `PluginClaim`/`ClassifyVerdict`,
`ModuleParsedURL` → `PluginParsedURL`, `ModuleJSFailure` → `PluginJSFailure`,
`ModuleBridgeSupport` → `PluginBridgeSupport`). Keep: one `JSVirtualMachine`
per runtime (process-wide scope in the app; the share extension uses the same
scope — one process anyway), one `JSContext` per loaded plugin built at load,
the abandon-on-timeout serial queue with `isWedged`, the three-timeouts
disable rule, the `Object.keys(luna)` grant read-back, exception capture.

```swift
public final class PluginRuntime {
    public init(store: PluginStore, bundled: BundledPluginCatalog, capabilities: PluginCapabilityRegistry, context: PluginProcessContext, reporter: PluginExceptionReporting?)
    public func loadAll() -> [PluginLoadReport]                       // enabled bundled + user plugins, sorted by (anyHost, -priority, id)
    public func reload(pluginID: String) -> PluginLoadReport
    public func unload(pluginID: String)
    public var loaded: [LoadedPlugin] { get }                          // descriptor + manifest + hook presence
    public var disabled: [String: PluginDisableReason] { get }         // wedged, loadFailed(PluginJSFailure), userDisabled
    public func matchedPlugins(forHost host: String) -> [LoadedPlugin] // pre-filter, host-matched first then any-host
    public func call<T: Decodable>(_ hook: PluginHook, pluginID: String, argument: Encodable, timeout: TimeInterval, decode: T.Type) async -> Result<T, PluginJSFailure>
}
public enum PluginHook: String { case classify, ingest, export, onBluetooth, onSettingsChanged, onAction }
public struct PluginProcessContext { public let kind: Kind; public enum Kind { case app, share, action } ; public let idleLimit: IdleLimitTouching? }
```

`call` encodes the argument to a JS value, invokes the hook, awaits a
returned Promise through `PluginPromiseBox`, and decodes the settled value
with `JSONDecoder` from `JSON.stringify` (never walks `JSValue` trees).
Timeouts are wall-clock for `classify`/`export`/`onBluetooth` and idle-based
for `ingest` (the bridge's `touch()`).

### 7.2 Capability bridges

```swift
public protocol PluginCapabilityInstalling { var capabilityName: PluginCapabilityName { get }; func install(into namespace: PluginCapabilityNamespace, for plugin: LoadedPlugin) }
public final class PluginCapabilityRegistry { public func register(_ installer: PluginCapabilityInstalling); public func installer(for name: PluginCapabilityName) -> PluginCapabilityInstalling? }
public enum PluginCapabilityName: String, CaseIterable { case fetch, html, page, storage, secrets, files, crypto, browser, downloads, settings, ui, mail, notifications, bluetooth, wifi, exports }
```

Bridges in `LunaPluginRuntime`: `PluginFetchBridge` (over
`PluginFetchService` in Kit), `PluginHTMLBridge` (SwiftSoup; a native
`PluginHTMLNodeHandle` class exported with `JSExport`), `PluginStorageBridge`
(over `PluginKVStore`), `PluginSecretsBridge`, `PluginFilesBridge`,
`PluginCryptoBridge`, `PluginLogBridge`, `PluginParsedURLBridge`. Bridges in
higher modules (browser, downloads, settings, ui, mail, notifications,
bluetooth, wifi, exports) register into the same registry from their module's
composition; an unavailable-here bridge installs a namespace whose every
method rejects with `unavailable-here` **only when the manifest declares it**
(so grants stay honest and `Object.keys(luna)` still matches).

### 7.3 Model types and adopters (`LunaModels/Plugin/`)

```swift
public enum PluginModel: Decodable { case media(MediaModel), article(ArticleModel), product(ProductModel) }   // strict decoding, caps enforced
public struct MediaModel: Decodable { title, author, thumbnailURL, platform, itemId, assets: [MediaAssetSpec], expiresAt }
public struct ArticleModel: Decodable { title, author, publishedAt, html, baseURL, leadImageURL, excerpt, language, document }
public struct ProductModel: Decodable { name, price: PluginPrice, imageURL, brand, productId, identifiers, sellers }

public protocol MediaModelAdopting  { func adopt(_ model: MediaModel,  url: URL, pluginID: String) async -> Outcome }
public protocol ArticleModelAdopting{ func adopt(_ model: ArticleModel, url: URL, page: CapturedPage, pluginID: String) async -> Outcome }
public protocol ProductModelAdopting{ func adopt(_ model: ProductModel, url: URL, pluginID: String) async -> Outcome }
public enum PluginModelAdopters { public static var media: MediaModelAdopting?; public static var article: ArticleModelAdopting?; public static var product: ProductModelAdopting? }
```

`Outcome` lives in LunaIngest, above LunaModels; the adopter protocols
therefore return a small `PluginAdoptedOutcome` in LunaModels that
`PluginIngestStage` maps onto `Outcome` (`.media(MediaAsset[], platform,
itemID)`, `.article(ArticleContent, html)`, `.product(ProductInfo)`,
`.declined`, `.failed(reason)`). Witnesses: `MediaKindComposition.install()`
sets `PluginModelAdopters.media = MediaModelAdopter()`;
`ArticleKindComposition` and `ProductKindComposition` set theirs. The kind
packs are shared by all apps and the assignment is harmless where no plugin
platform runs; the kind-pack rule holds because roots still write nothing.

### 7.4 `PluginIngestStage`

Inserted into `IngestPipeline.runUnbounded` **after unwrap, before
`Classifier.classify`**, through a seam:

```swift
public protocol PluginIngestStaging { func run(_ input: IngestInput, fetcher: HTMLFetching) async -> PluginIngestVerdict }
public enum PluginIngestVerdict { case passed; case outcome(Outcome); case locked(PluginBrowserRequestRecord) }
extension IngestPipeline { public static var pluginStage: PluginIngestStaging? }   // installed by PluginPlatformComposition; nil in the three sibling apps
```

Flow inside `run`:

1. `runtime.matchedPlugins(forHost:)` — none → `.passed`.
2. For each, `call(.classify)` with `ClassifyInput` (page from
   `IngestInput.page` when `.fetched`/`.unlockedCapture`). Failure or
   `false` → next. First claim → step 3.
3. `call(.ingest, reason: .save)`. `null` → continue the walk (step 2 with
   the next plugin). Model → the adopter → `.outcome`. A `PluginJSFailure`
   whose code is `browser-deferred` → `.locked(record)`. Any other failure
   → record the trace line, continue the walk (a broken plugin must not
   fail a save the Swift floor could handle).
4. Every step writes `SaveDiagnostics.record(…, category: "plugin")`.

`IngestPipeline` handles `.locked` by returning a new
`Outcome.locked(pluginID:)`, which `SurfaceSupport.owningApp` maps to
`.luna` (central), `SavesIngestor.applyResult` stores via
`SavesStore.markNeedsCaptcha` plus `PluginBrowserRequestStore.put`, and the
presenters show the locked card (§8). `Outcome` is exhaustive; every
presenter's switch gains the case.

### 7.5 Budgets and failure policy

| Hook | Budget | On timeout |
| --- | --- | --- |
| `classify` | 8 s wall | abandoned; plugin passes for this URL; 3 in a row disable the plugin |
| `ingest` | pipeline 30 s idle (bridge calls touch) | as classify, then the walk continues |
| `export` | 120 s wall | destination soft failure |
| `onBluetooth` | 25 s wall per event, inside a background task lease | session closed; event recorded |
| `onSettingsChanged`/`onAction` | 10 s wall | reported in Settings |

A disabled-for-wedge plugin shows "Stopped: the plugin did not finish" in
Settings with a Re-enable button. The consent copy states plainly that a
running plugin cannot be interrupted (the prior branch's honesty rule).

### 7.6 `PluginMediaResolver` and the media port

`LunaPluginIngest.PluginMediaResolver: SocialMediaResolving` runs the plugin
walk for a URL and returns `[MediaAsset]` from the `media` Model. Central
Luna's `PluginPlatformComposition.install()` installs it as
`URLRescueWiring.mediaResolverFactory` and as the resolver `MediaShellWiring`
hands to `LiveMediaDownloadManager` and the Safari hand-off drain. The Swift
`SocialMediaResolver` stays in `LunaMediaResolve` for the Downloader app and
the three sibling Safari appexes; central Luna simply stops calling it (the
suite pins that with a source-text test on `KindWiring+Luna`).

The durable engine's per-platform re-resolution (`startNextInstagramResolve`
and the Facebook twin) is replaced, for jobs with `plugin_id`, by one seam:

```swift
public protocol MediaReresolving { func reresolve(sourceURL: URL, pluginID: String, saveID: String) async -> [MediaAsset]? }
extension LiveMediaDownloadManager { public static var reresolver: MediaReresolving? }
```

The engine calls it when a task fails with 401/403/410, when a job's
`expires_at` has passed before start, and once on `resumeUnfinishedDownloads`
for jobs older than 6 h. Assets are matched by `(kind, quality)`; the job's
URLs and headers are replaced and the task restarted with the persisted
resume data discarded.

Bundled media plugins (`LunaBundledPlugins/Resources/`): `direct-media.js`
(priority 90: a URL that IS an image/video/audio file), `x.js` (fxtwitter,
long-form text posts are declined so `XPostIngestProcessor` keeps them),
`instagram.js` (the three-stage ladder), `tiktok.js`, `facebook.js`,
`reddit.js` (video + audio legs), `youtube.js` (player JS + signature
dance). Each ports its Swift twin's fixtures (`SocialMediaResolverTests`,
`YouTubeMediaResolverTests`) into the JS fixture runner (§13.2). The
`platform` string each returns maps to `ContentPlatform` so cards, Live
Activity phases and the Safari overlay are unchanged.

## 8. The browser lock flow

### 8.1 Storage

```sql
CREATE TABLE plugin_browser_requests (
  save_id TEXT PRIMARY KEY REFERENCES saves(id) ON DELETE CASCADE,
  plugin_id TEXT NOT NULL,
  request_json TEXT NOT NULL,     -- BrowserRequest
  result_json TEXT,               -- BrowserResult once the modal completed; NULL = still locked
  created_at REAL NOT NULL, completed_at REAL
);
```

`PluginBrowserRequestStore` (Kit): `put(saveID:pluginID:request:)`,
`pending(for saveID:) -> BrowserRequest?`, `complete(saveID:result:)`,
`takeResult(saveID:) -> BrowserResult?` (single use), `clear(saveID:)`.

### 8.2 In an extension or the Safari world

`luna.browser.open` writes the request through the store (or, in Safari,
sends `plugins.browserDeferred` to native, which writes it) and rejects with
`LunaError("browser-deferred")`. The plugin lets the rejection propagate.
The stage returns `.locked`; the save is written with `state = .needsCaptcha`
and `plugin_id`, and the share/action UI shows the locked treatment
(`LockedCardOverlayView`) with the line "Open Luna to finish". In Safari no
save exists yet: the pill offers "Finish in Luna", which deep-links
`<scheme>://save?url=<url>` (new `LunaDeepLink.saveURL`); the app ingests
from scratch and reaches §8.3 with the user present.

### 8.3 In the app

`PluginBrowserViewController` (LunaPluginUI) generalizes the archive unlock's
cover-until-challenge mechanics: an always-live `WKWebView` under an opaque
`loadingOverlay`, a 350 ms `Timer` poll that evaluates the plugin's `detect`
source, the overlay lifted only while `detect` returns `"challenge"`, closed on
`"done"`, an error state on `"error"`, and the escape-to-Safari leg. It is
built as a **new** class that shares extracted helpers with
`ArchiveWebReaderViewController` (`ChallengeCover`, `DOMProbePoller`,
`deviceSafariUserAgent`) moved into `LunaArchiveReader`; the archive reader
keeps its own probe and stage machine. On `"done"` it captures
`documentElement.outerHTML`, the final URL, title, and the data store's
cookies for the URL's domain, then `complete(saveID:result:)`.

Two entry points present it: a tap on a locked plugin-owned card (any kind:
`ArticleCardPresenter`, `MediaCardPresenter`, `ProductCardPresenter` all
already check `.needsCaptcha` and call `chrome.presentUnlockFlow`; the flow
consults `PluginBrowserRequestStore.pending` first and routes to the plugin
modal), and the in-app ingest itself when `luna.browser.open` is called with
the app in the foreground — the bridge presents immediately and awaits.

After completion the app re-runs `ingest` with `reason: "resume"` and
`saveId`; when the plugin calls `luna.browser.open` again with a request whose
`url` matches, the bridge returns `takeResult` without presenting. The Model
then flows through the normal adopter, replacing the locked placeholder (the
save keeps its id).

## 9. Export hooks

### 9.1 Declaration

```ts
interface ExportDeclaration {
  kinds: ("article" | "media" | "product")[];
  input: ExportInputFormat;
  inputOptions?: { epub?: { images?: boolean; profile?: "standard" | "compact" } };   // compact = EpubBuilder.Profile.xteink
  title: string;                 // share-row label, e.g. "Send to Kindle"
  symbol?: string;               // SF Symbol name
  destination?: boolean;         // participates in auto-send (§9.4)
  requiresSettings?: string[];   // keys that must be set before the row is enabled ("isConfigured")
}
type ExportInputFormat = "url" | "epub" | "pdf" | "docx" | "markdown" | "text" | "html" | "json" | "file";
```

Input availability per kind, produced by `ExportInputProducer`
(LunaPluginExport) from existing builders:

| Kind | `url` | `epub` | `pdf` | `docx` | `markdown` | `text` | `html` | `json` | `file` |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| article | ✓ | `EpubBuilder` | `ArticlePDFBuilder` | `ArticleDOCXBuilder` | `ArticleMarkdownBuilder` | `ArticlePlainTextBuilder` | reader source HTML | `ArticleContent` JSON | – |
| media | ✓ | – | – | – | – | – | – | `SavedMediaItem` + assets JSON | the downloaded file (`localFile`) |
| product | ✓ | – | – | – | – | – | – | `PriceTracker` JSON (stores, price points) | – |

A declaration naming an unavailable pair refuses import.

### 9.2 Hook contract

```ts
interface ExportInput {
  kind: "article" | "media" | "product";
  saveId: string;
  url: string;
  title: string;
  format: ExportInputFormat;
  file?: FileHandle;           // epub/pdf/docx/file
  text?: string;               // markdown/text/html
  json?: unknown;              // json
  auto: boolean;               // true when the coordinator is delivering a queued send
  source?: string;             // CaptureSource raw value
  queuedRemaining?: number;
}
type ExportResult =
  | null                                                     // handled by the plugin (sent itself, or nothing to do)
  | { file: FileHandle; name?: string; mime?: string }      // → share sheet
  | { text: string; name?: string; mime?: string }          // → share sheet as a file
  | { url: string }                                          // → share sheet
  | { status: "sent" | "failed" | "retry"; message?: string; hard?: boolean };   // destination bookkeeping
```

`PluginExportStage.run(pluginID:saveID:)` produces the input off-main (images
prepared first, as `ArticleExportService.writePreparingImages` does), calls
the hook, and sinks the result: a file/text/url result presents
`UIActivityViewController` from the invoking view; `null` and `status`
results present nothing. A thrown `LunaError` with `details.hard === true`
or a `hard: true` status is a terminal failure for destinations.

### 9.3 Share rows

`PluginShareRowProvider` contributes one `ReaderShareSheet.Row` per export
plugin whose `kinds` include the item's kind and whose `requiresSettings` are
satisfied, spliced where `ereaderRows` are today (`AppReaderShareProvider`
gains `pluginRows(for:)`). Media and product cards gain the same row source
through their presenters' share menus. A destination plugin's row shows the
status dot the Xteink row shows today, fed by `luna.exports`'s
`PluginDestination.statusDotColor` (a plugin sets it via
`luna.settings.set("_status", "live"|"off")` — reserved key).

### 9.4 Destinations

`PluginDestination: ArticleDestination` (LunaPluginExport), one instance per
loaded plugin with `destination: true`:

```swift
final class PluginDestination: ArticleDestination {
    var id: String { plugin.id }                              // send_states, SourceSendSettings and datesSent key on it unchanged
    var displayName: String { plugin.manifest.export.title }
    var isConfigured: Bool                                    // requiresSettings satisfied, plugin enabled
    func sendMode(for item: SavedItem) -> ArticleSendMode     // SourceSendSettings for this id, as today
    var epubBuildProfile: EpubBuilder.Profile                 // from inputOptions
    func send(epubData: Data, fileName: String, title: String, context: ArticleSendContext) async throws
}
```

`ArticleDestination` today is EPUB-shaped; it gains a default-implemented
`func deliver(item: SavedItem, context: ArticleSendContext) async throws`
that the coordinator prefers when a destination implements it, so a plugin
destination receives its declared input format rather than EPUB bytes.
`ArticleSendCoordinator.configuredDestinations()` includes plugin
destinations; `retryPendingSends`, backoff (`RetryPolicy`), double-save and
auto-send-by-source all apply unchanged. `luna.exports.deliverQueued()` maps
to `deliverQueuedSends(toDestinationID:)`. Destinations for `media`/`product`
kinds are out of scope for auto-send (the coordinator is article-shaped);
they get manual rows only, and the plan records that as the one asymmetry.

### 9.5 Kindle plugin (`kindle.js`, bundled)

Settings: `kindleAddress` (email, required), `senderNote` (toggle). Export:
`{ kinds: ["article"], input: "epub", title: "Send to Kindle", destination: true, requiresSettings: ["kindleAddress"] }`.
Hook: `luna.mail.send({ to: [address], subject: title, text: "…", attachments: [{ file, name: fileName, mime: "application/epub+zip" }] })`
→ `{ status: "sent" }`. `isConfigured` also requires `luna.mail.isConfigured()`,
so the destination shows as unconfigured without a connected account,
matching `KindleSendSettings.isConfigured`. Central Luna's `KindWiring+Luna`
stops registering `KindleDestination`; `KindleSendSettings`'s stored address
is migrated once into the plugin's `kindleAddress` setting at first launch.
`LunaReader` keeps the Swift destination.

## 10. Bluetooth, Wi-Fi and the Xteink plugin

### 10.1 Declaration and events

```ts
interface BluetoothDeclaration {
  services: string[];                 // GATT service UUIDs the plugin talks to; ASK discovery descriptors + background restoration scope
  pairing: "accessorySetupKit" | "none";
  standingConnect?: boolean;          // keep a pending connect to paired peripherals (background wake)
  role: "central";                    // the only role in this pivot
}
type BluetoothEvent =
  | { type: "connected"; device: BluetoothDevice; restored: boolean }
  | { type: "disconnected"; device: BluetoothDevice; error?: string }
  | { type: "paired"; device: BluetoothDevice }
  | { type: "unpaired"; device: BluetoothDevice }
  | { type: "stateChanged"; state: "poweredOn" | "poweredOff" | "unauthorized" | "unsupported" };
interface BluetoothDevice { id: string; name?: string; serviceUUIDs: string[] }
```

`onBluetooth(event, session)` receives a live `BluetoothSession` only for
`connected`. The core owns one `CBCentralManager` per declaring plugin with
restoration identifier `plugin.<id>`, `bluetooth-central` background mode
(already in `Luna/Info.plist`), and `NSAccessorySetupKitSupports`.

### 10.2 `luna.bluetooth` (capability `bluetooth`, app only)

```ts
luna.bluetooth.state(): Promise<"poweredOn" | "poweredOff" | "unauthorized" | "unsupported" | "unknown">;
luna.bluetooth.pair(): Promise<BluetoothDevice | null>;                   // ASAccessorySession.showPicker scoped by the declared services; releases/rebuilds the manager around it (ASErrorDomain 550)
luna.bluetooth.pairedDevices(): Promise<BluetoothDevice[]>;
luna.bluetooth.unpair(deviceId: string): Promise<void>;
luna.bluetooth.connect(deviceId: string, opts?: { timeout?: number }): Promise<BluetoothSession>;   // foreground use; onBluetooth("connected") is the background path
interface BluetoothSession {
  readonly device: BluetoothDevice;
  readonly mtu: number;                                                    // maximumWriteValueLength(.withoutResponse)
  discover(serviceUUID: string): Promise<{ characteristics: string[] }>;
  read(characteristicUUID: string): Promise<string>;                       // base64
  write(characteristicUUID: string, base64: string, opts?: { response?: boolean }): Promise<void>;   // response=false paces by canSendWriteWithoutResponse
  subscribe(characteristicUUID: string): Promise<void>;
  next(characteristicUUID: string, opts?: { timeout?: number }): Promise<string>;    // next notification value (base64), queued since subscribe
  disconnect(): Promise<void>;
}
```

All session calls serialize on one queue per connection; a `disconnected`
event rejects every pending call with `LunaError("disconnected")`.

### 10.3 `luna.wifi` (capability `wifi`, app only)

```ts
luna.wifi.join(opts: { ssid: string; passphrase?: string; joinOnce?: boolean }): Promise<{ joined: boolean }>;   // NEHotspotConfiguration; entitlement already held by Luna
luna.wifi.forget(ssid: string): Promise<void>;
luna.wifi.isReachable(host: string, port: number, opts?: { timeout?: number }): Promise<boolean>;             // NWConnection probe; needs NSLocalNetworkUsageDescription (present)
```

Uploads themselves are `luna.fetch` with a `multipart` body.

### 10.4 Two apps, one GATT link

Luna Reader keeps Swift Xteink and runs its own `XteinkBLECentral`. Both
processes must never sweep the same connection concurrently, and today that
is `XteinkRendezvousSweepLock` (an App-Group `flock`). The plugin bridge
holds `PluginBluetoothSessionLock` — the **same lock file path**, derived
from the service UUID — across every `onBluetooth("connected")` invocation
and every `luna.exports.deliverQueued()`. `XteinkRendezvousSweepLock` moves
down to `LunaStorage` as `BluetoothServiceLock(serviceUUID:)` and the Reader's
Swift path adopts the same key in the same commit, so the two keep excluding
each other.

### 10.5 Xteink plugin (`xteink.js`, bundled)

Capabilities: `bluetooth`, `wifi`, `fetch`, `files`, `crypto`, `secrets`,
`storage`, `settings`, `notifications`, `exports`, `ui`. Settings:
`enabled` (toggle), `device` (pairedDevice, shows the ASK picker via
`onAction("pair")`), `unpair` (action). Export:
`{ kinds: ["article"], input: "epub", inputOptions: { epub: { profile: "compact" } }, title: "Send to Xteink", destination: true, requiresSettings: ["device"] }`.

Behavior, mirroring `claudedocs/xteink.md`:

- `export` with no active session → `{ status: "retry", message: "Waiting for the reader" }` (the enqueue-only semantics of today's `.unavailable`).
- `onBluetooth({type:"connected"}, session)`: discover the CrossPoint service; hello with HMAC-SHA256 over `nonce|host_id|1` using the pairing secret from `luna.secrets`; read status; reconcile (`luna.exports.markSent` for books the reader reports; drain the plugin's own `pendingDeletes` collection); then `await luna.exports.deliverQueued()`. The core holds the service lock for the whole invocation.
- Inside `export` during a session: size the compact EPUB (`file.size ≤ 200 KiB` → BLE frames paced to the reader's `ckpt` stride via `session.write(..., {response:false})` and `session.next(status)`; larger → request Wi-Fi over control, read the `XteinkWiFiOffer`, `luna.wifi.join` for AP offers, then `luna.fetch({ method: "POST", url: "http://<host>/upload?path=/Books", body: { multipart: [...] } })`). Background AP offers post `luna.notifications.post`.
- `luna.settings.set("_status", …)` mirrors the rendezvous dot.

At parity (checklist from `claudedocs/xteink.md`), central Luna's
`KindWiring+Luna` stops installing `XteinkDestination`/`XteinkBLECentral`
and the Xteink settings category; `LunaSend`'s Swift stays for the Reader.
The pairing secret's Keychain item is migrated once into
`luna.secrets` (`pairingSecret`) so users are not asked to re-pair.

## 11. Settings, storage, secrets

### 11.1 Settings schema

```ts
interface SettingField {
  key: string;                     // [a-zA-Z0-9_]; keys starting "_" are reserved
  type: "text" | "email" | "url" | "password" | "number" | "toggle" | "choice" | "pairedDevice" | "action" | "info";
  label: string; help?: string; placeholder?: string;
  options?: { id: string; label: string }[];   // choice
  default?: unknown;
  required?: boolean;               // feeds isConfigured / requiresSettings
  secret?: boolean;                 // stored in Keychain; read back as "" by luna.settings.get
}
```

`PluginSettingsScreen` (LunaPluginUI, a `NavHeaderTableController`) renders
the schema: text-like types as inline editors, `toggle` via `makeToggle`,
`choice` as a picker, `pairedDevice` as a row showing the paired name with
Pair/Unpair calling `onAction`, `action` as a button row, `info` as read-only
text. Values persist in `plugin_kv` under `settings.<key>` (secrets in
Keychain). A change calls `onSettingsChanged`.

### 11.2 Settings → Plugins

A `SettingsCategory("Plugins", symbol: "puzzlepiece.extension")` in
`KindWiring+Luna.settingsCategories()` only. `PluginsSettingsScreen` lists
bundled and imported plugins (name, version, produces/export summary, status:
Enabled / Off / Stopped / Load failed), with per-plugin: enable switch,
capabilities list, the settings screen, "Show source" (read-only), Delete
(imported only; bundled can only be disabled). An **Add** header button
offers "Import from Files…" (`UIDocumentPickerViewController`, `.javaScript`
+ `.plainText`) and "Paste source" (a sheet with a text view). Both go
through `PluginImportCoordinator` → parse header → consent
(`PluginConsentViewController`, salvaged) → `PluginStore.install` →
`runtime.reload`.

### 11.3 Storage layout

```
<AppGroup>/Plugins/
  user/<id>/<version>/plugin.js        installed verbatim
  user/<id>/state.json                 { enabled, installedAt, origin: "files"|"paste", consentedCapabilities: [...] }
  state/<bundledId>.json               { enabled } for bundled plugins (absent = enabled)
  scratch/<id>/<invocation>/           luna.files, reaped
```

`BundledPluginCatalog` reads `Bundle.module` of `LunaBundledPlugins`; a user
plugin with the same `id` as a bundled one **replaces** it while installed
(the bundled copy is the fallback after deletion). Consent for bundled
plugins is implicit (they ship with the app) but their capabilities are still
listed.

## 12. Store schema changes (`SavesSchema`, one `user_version` bump)

```sql
ALTER TABLE saves ADD COLUMN plugin_id TEXT;                        -- owner plugin, NULL for Swift-ingested saves
ALTER TABLE tracker_stores ADD COLUMN plugin_id TEXT;               -- refresh routing
ALTER TABLE media_download_jobs ADD COLUMN plugin_id TEXT;          -- reresolve routing
ALTER TABLE media_download_jobs ADD COLUMN request_headers_json TEXT;
ALTER TABLE media_download_jobs ADD COLUMN expires_at REAL;
CREATE TABLE plugin_kv (plugin_id TEXT NOT NULL, key TEXT NOT NULL, json TEXT NOT NULL, updated_at REAL NOT NULL, PRIMARY KEY (plugin_id, key));
CREATE TABLE plugin_collections (plugin_id TEXT NOT NULL, collection TEXT NOT NULL, id TEXT NOT NULL, k1 TEXT, k2 TEXT, json TEXT NOT NULL, updated_at REAL NOT NULL, PRIMARY KEY (plugin_id, collection, id));
CREATE INDEX plugin_collections_k1 ON plugin_collections (plugin_id, collection, k1);
CREATE INDEX plugin_collections_k2 ON plugin_collections (plugin_id, collection, k2);
CREATE TABLE plugin_browser_requests (…);                            -- §8.1
CREATE TABLE pending_plugin_models (id TEXT PRIMARY KEY, url TEXT NOT NULL, model_json TEXT NOT NULL, plugin_id TEXT NOT NULL, created_at REAL NOT NULL, return_to_source_until REAL);   -- Safari → app hand-off
```

No CHECK constraints (four apps share the file; the siblings never read these
tables but must not fail on them). `send_states` is unchanged; a plugin
destination id is just another key.

## 13. Safari

### 13.1 Mechanics

`content.js` (central Luna's copy; the four appexes share the source, gated
by a new `supportsPlugins` flag in `buttonContext`, true only for the central
host) at `document_idle`:

1. `browser.storage.local` holds a cached `{ stamp, plugins: [{ id, match, priority, produces, capabilities }] }`. Native answers `plugins.catalog` with the current stamp (a hash of installed ids+versions+enabled flags); a mismatch refreshes the cache. One native round trip per page at most.
2. If a plugin's `match` accepts `location.host`, request `plugins.source` (id) — the file as a string (≤ 1.5 MB, else the plugin is skipped in Safari and logged) — and evaluate `plugin_host.js` + the source with `new Function` in the isolated world. Repeated per page; the isolated world is per document.
3. `plugin_host.js` implements the bridge: `luna.html.parse` → `DOMParser`, wrapped in the §6.3 subset; `luna.page` → the live `document`; `luna.fetch`/`storage`/`log`/`settings.get` → `browser.runtime.sendMessage({type:"plugins.<ns>", …})`, **sequenced** through one promise chain (WebKit's in-flight message guard); `luna.browser.open` → `plugins.browserDeferred` then reject; `luna.crypto` → `crypto.subtle`; everything else absent.
4. `classify` decides the pill ("Save to Luna" for article/product claims, the video overlay for media). Tapping Download or Save runs `ingest`; a `media` Model plays in the existing overlay (assets are playable URLs) and Download posts `plugins.queueModel` → `PendingPluginModelStore` → deep link `<scheme>://pluginmodel?ret=safari`; the app drains it into the adopter (`KindWiring.drainPendingPluginModels`, mirroring `drainPendingResolvedMedia`). Article/product Models are also handed over the same way so the app writes the save without re-fetching.

The native handler adds message types `plugins.catalog`, `plugins.source`,
`plugins.fetch`, `plugins.storage.{get,set,delete,keys}`,
`plugins.collection.*`, `plugins.log`, `plugins.settings.get`,
`plugins.browserDeferred`, `plugins.queueModel` — each validated by shape as
today, each scoped by the plugin id the content script names (the handler
checks the id is installed and enabled and the capability declared before
serving; the content script is not trusted to enforce grants).

### 13.2 Test harness for plugin JS

`LunaTests/PluginJSFixtureRunner.swift` (salvaged `ModuleJSFixtureRunner`):
stages a plugin file, builds a real `PluginRuntime` on an isolated VM with a
`StubPluginFetcher` that answers from recorded fixtures (the existing
`SocialMediaResolverTests` HTML/JSON fixtures move to
`LunaTests/Fixtures/Plugins/<platform>/`), runs hooks, and decodes Models.
Every bundled plugin gets a `<Platform>PluginTests` class with the same cases
its Swift twin has; parity is asserted **by behavior** (same asset URLs for
the same fixture), never by source text.

### 13.3 `luna.html` parity suite

`PluginHTMLParityTests` runs `LunaTests/Fixtures/Plugins/html-subset.spec.js`
(a list of `{ html, script, expected }` cases) against the SwiftSoup bridge in
JSC and against `plugin_host.js`'s DOMParser backing inside the shared
`SafariJSTestHarness` web view; the same file runs under node in the dev
harness. Disagreements fail the suite; the fix is narrowing the subset or the
backing, never a per-backing expectation.

### 13.4 Node dev harness (`tools/plugin-sim/`)

`node tools/plugin-sim/run.mjs <plugin.js> <url> [--fixture dir]` loads the
plugin under a node implementation of the bridge (`undici` fetch, `linkedom`
for `luna.html`, in-memory storage, `browser` unsupported) and prints the
classify result and the Model. It exists so plugin authors and implementation
agents iterate in seconds rather than through `xcodebuild`; it is not a gate.
`tools/plugin-sim/luna-plugin.d.ts` is the typings file shipped with the docs.

## 14. Docs, strings, staging

- `claudedocs/plugins.md` — the feature doc (architecture, processes, budgets, schema).
- `docs/plugins/README.md` — authoring guide for humans; `docs/plugins/api.md` — the bridge reference; `docs/plugins/luna-plugin.d.ts`; two examples (`examples/minimal-media.js`, `examples/export-to-webhook.js`).
- `skills/luna-plugin-author/SKILL.md` — LLM authoring skill embedding the `.d.ts` and the manifest schema.
- Strings: every new user-visible string is a `_Luna` key in the one strings file; capability copy keys `PluginCapability_<name>_Luna`.
- Stages: `plugins.settings.list`, `plugins.settings.detail`, `plugins.consent`, `plugins.import.paste`, `plugins.browser.lock` (frozen mid-challenge), `plugins.locked.card` — in `Stage/StageCatalog+Plugins.swift`, compiled only into central Luna.
- CLAUDE.md gains a "Plugins" section pointing at `claudedocs/plugins.md` and the composition rule; the `LunaSafari` floor paragraph is updated (the central appex also links `LunaPluginKit` and `LunaBundledPlugins`).

## 15. Trust and consent

Consent screen (salvaged `ModuleConsentViewController`) shows name, version,
`produces`, the export declaration, each capability in plain language
(`PluginCapabilityCopy`), the `background` flag, and the fixed containment
sentence: "Luna limits what a plugin can reach, but cannot stop a plugin
that does not finish." Decline → not installed. Re-import of the same id with
new capabilities → consent again. Capability enforcement is in the bridge
(absent namespaces) and, for Safari, in the native handler (a message for an
undeclared capability is refused).

## 16. Waves

Every wave: own worktrees off `main`, agents pinned to the scaffolding SHA
and told to `git reset --hard` to it first, small commits, no edits to
`Package.swift`/`project.pbxproj` by agents (the orchestrator scaffolds), no
merging by agents. Merge in dependency order; full `scripts/run_tests.sh
--fresh` green before each merge to `main`. Model choice: Opus where a design
has to be made or a hairy port judged; Sonnet for ports with fixtures, UI
tables, docs and harnesses.

### Wave 0 — scaffolding (orchestrator, main checkout via worktree)

Package targets from §2.2 with placeholder files, `scripts/add_plugin_links.rb`
run, `LunaModels/Plugin/` types + adopter protocols + `PluginAdoptedOutcome`,
`SavesSchema` bump with §12 tables, `MediaAsset.requestHeaders`, this plan,
memory note. Exit: `build-for-testing` green.

### Wave 1 — platform (three agents in parallel)

| Agent | Model | Owns | Deliverable |
| --- | --- | --- | --- |
| 1A runtime | Opus | `LunaPluginKit`, `LunaPluginRuntime`, `LunaTests/Plugin*` runtime tests | Salvage + rename the JSC runtime; manifest parser for §3.2; `PluginStore`/`BundledPluginCatalog`; bridges fetch/html/storage/secrets/files/crypto/log/parseURL; `PluginJSFixtureRunner`; `luna.html` SwiftSoup backing + the subset spec file. |
| 1B ingest | Opus | `LunaPluginIngest`, `IngestPipeline.pluginStage`, `Outcome.locked`, `PluginPlatformComposition`, the three `KindWiring/ShareEntry/ActionEntry+Luna` edits, `KindCompositionRootTests`, adopters in the three kind modules | Classify walk, ingest, Model decoding + adoption, browser deferral storage, diagnostics, `PluginMediaResolver`, `MediaReresolving` seam, `saves.plugin_id` threading, `PluginPriceFetcher`. Codes against 1A's public API as written in §7.1–7.2. |
| 1C UI | Sonnet | `LunaPluginUI` (settings screens, import, consent, settings-schema renderer, prompts), strings, stages | Settings → Plugins, Files + paste import, consent, per-plugin settings, `luna.ui` + `luna.settings` bridges. |

**1B landed, with four placements the dependency graph forced.** The package
edges run LunaPluginIngest → LunaIngest, and no further, so a witness the
plugin side must install into a kind module reaches it through a registry at
the BOTTOM of the stack instead: `PluginMediaSeams` (LunaModels) holds the
resolver URL Rescue takes and the `MediaReresolving` witness
`LiveMediaDownloadManager.reresolver` proxies; `PluginPriceSeams` (LunaModels)
holds the refresh route, because `PriceFetching` takes a URL and cannot carry
an owner. `PluginBrowserRequestStore` and `PendingPluginModelStore` are in
LunaStorage, not LunaPluginKit: their rows live in `saves.sqlite` and one
process opens one connection to that file. `ArticleModelAdopter` is in
LunaReaderUI, not LunaArticleIngest, because a `document` Model needs
`DocumentParser` and LunaArticleIngest does not link LunaDocuments.

**Carried into Wave 2.** `MediaAsset` gained `quality`, `pluginID` and
`expiresAt` so the resolver's answer reaches the job; `media_download_jobs`
keeps the quality from Wave 2A on, and still keeps no creation time, so
staleness is read off the job's own files. A media or product save in
`.needsCaptcha` draws no locked overlay yet — 2B routes the three card
presenters.

Merge order 1A → 1B → 1C. Exit: an imported toy plugin claims a URL, returns
a `media` Model, the download starts, the save renders on the existing media
card, and the plugin appears in Settings; the three sibling apps build and
pass unchanged.

### Wave 2 — media port, lock flow, Safari (three agents)

| Agent | Model | Owns | Deliverable |
| --- | --- | --- | --- |
| 2A media plugins | Opus | `LunaBundledPlugins` media files, `LunaTests/Fixtures/Plugins`, `<Platform>PluginTests`, `MediaShellWiring`/`URLRescueWiring` resolver installs, engine reresolve | The seven plugins with fixture parity; central Luna off `SocialMediaResolver`; `LiveMediaDownloadManager` reresolve + headers + expiry. |
| 2B lock flow | Opus | `PluginBrowserViewController`, `LunaArchiveReader` helper extraction, locked-card routing in the three card presenters, `LunaDeepLink.saveURL`, resume path | §8 end to end, in app and from the share/action extensions. |
| 2C Safari | Sonnet | `LunaSafari/plugin_host.js`, `content.js`/`background.js` additions, handler message types, `PendingPluginModelStore` drain, `PluginHTMLParityTests`, `tools/plugin-sim` | §13.1, §13.3, §13.4. |

**Wave 2A landed**, with five design points worth carrying forward.

1. **`PluginPlatformComposition.install` builds the platform.** Its signature is
   `install(processKind:bundledPluginsBundle:additionalBridges:store:keyValueStore:)`
   — the resource bundle is INJECTED because LunaPluginIngest sits below
   LunaBundledPlugins in the link graph, and the two stores are defaulted so a
   test can boot the whole platform on a scratch container. `swiftMediaResolver`
   is gone: `PluginMediaResolver` holds no fallback, and the three central roots
   build no `SocialMediaResolver`.
2. **`MediaAssetResolution` (LunaMediaDownload) answers "which resolver".**
   `MediaShellWiring` is shared by central Luna and the Downloader, so the file
   cannot name either answer; it asks the media module, which reads
   `PluginMediaSeams.resolver` and falls back to `SocialMediaResolver`.
   `PluginPlatformBootTests` pins that neither `KindWiring+Luna` nor
   `MediaShellWiring` names a Swift resolver.
3. **No bundled media plugin sets `headers`.** `LiveMediaDownloadManager`
   already sends the per-platform User-Agent and Referer those CDNs ask for,
   keyed off the save's own URL, and a plugin's headers OVERRIDE those. The
   `headers` field stays for a CDN the engine's defaults miss.
4. **Schema 13**: `media_download_jobs.quality`, so `MediaReresolveMatching`
   matches on (kind, quality) rather than on kind plus display order. One TEXT
   column, not a JSON list — a job persists exactly one asset.
   `PluginModelCaps` also gained a URL cap of its own (4096); a signed YouTube
   stream URL carries its whole signature in the query and failed the
   1000-character prose cap the decoder was reusing.
5. **`match.any` for `direct-media.js`**, with `priority: 90` declared as the
   plan says. An any-host plugin runs after every host-matched plugin whatever
   its priority, which is the ordering a URL-shape fallback wants: a platform's
   own plugin keeps a post page whose path happens to end in `.mp4`.

Not reached: a bundled plugin's ingest now runs at SAVE time, so saving a
YouTube, TikTok or Facebook link costs its resolver's round trips inside the
walk (the Swift path decided the kind from the URL alone and resolved later).
A failure still falls through to the Swift classifier, so the cost is latency
rather than correctness. `KindCompositionRootTests
.testNoCompositionRootWritesThePluginRegistriesDirectly` fails on the merged
1B+1C base: `Luna/Settings/PluginsSettingsCategory.swift` READS
`PluginPlatformServices`, and the check greps for the name rather than for a
write.

Exit: media-download parity checklist (from `claudedocs/media-download.md`)
green on the simulator via `-LunaStage` + a device check for Safari; the
Downloader app still uses Swift resolvers and passes its suite.

### Wave 3 — export, transport, docs (three agents)

| Agent | Model | Owns | Deliverable |
| --- | --- | --- | --- |
| 3A export | Opus | `LunaPluginExport`, `ArticleDestination.deliver`, `AppReaderShareProvider.pluginRows`, media/product share rows, mail + notifications bridges, `kindle.js`, Kindle migration + removal from central wiring | §9 end to end; Kindle parity (`claudedocs/send-to-kindle.md`). |
| 3B transport | Opus | `LunaPluginTransport`, `BluetoothServiceLock` move + Reader adoption, `xteink.js`, Xteink migration + removal from central wiring | §10 end to end; Xteink parity (`claudedocs/xteink.md`), including the two-app lock. |
| 3C docs | Sonnet | `claudedocs/plugins.md`, `docs/plugins/*`, `skills/luna-plugin-author`, CLAUDE.md section, `.d.ts` kept in sync with the bridges | §14. |

Exit: full suite green; parity checklists signed off; stage screenshots
captured; docs current.

## 17. Risks

| Risk | Mitigation |
| --- | --- |
| Two `luna.html` backings drift | The subset is small and the parity spec file is the definition; the node harness runs the same file. |
| A runaway plugin wedges the shared VM | Abandon-on-timeout, three-strikes disable, honest consent copy; classify never runs on the main thread. |
| Central Luna's media resolvers diverge from the Downloader's Swift ones | Accepted by decision 3; the JS fixtures are copies of the Swift fixtures so a fix can be mirrored. Recorded as a standing item. |
| Safari 1.5 MB message cap vs plugin source and page HTML | Sources over the cap are skipped in Safari with a log line; `luna.page` avoids sending HTML at all; `luna.fetch` responses are truncated with `truncated: true`. |
| The lock modal generalization destabilizes the archive unlock | The archive reader keeps its own stage machine; only stateless helpers move. `ArchiveUnlockFlow` tests stay. |
| Xteink plugin and Reader Swift both sweep one link | Same lock file, moved down and adopted by both in one commit; a test asserts the two derive the same path for the CrossPoint service UUID. |
| Export coordinator is article-shaped | Media/product destinations are manual rows only in this pivot; recorded in §9.4. |
| `ArticleDestination.deliver` changes a shared protocol used by the Reader | Default implementation keeps every existing conformer source-compatible. |

## 18. Open items for the owner

1. Whether the Downloader app should later adopt the plugin platform too (decision 3 says no for this pivot).
2. Whether media/product export destinations should gain auto-send (needs a kind-neutral coordinator).
3. URL import and update checking (deferred by decision 13).
