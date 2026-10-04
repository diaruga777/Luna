> Core migration: `luna.html.article`, `luna.html.meta`, `luna.text.price`, and
> `luna.text.date` are retired in executing plugins. Bundle your interpretation
> code (see `docs/plugins/lib/web.js`) and use DOM/JSON primitives. An ingest hook
> may return `{rewriteURL: "https://…"}` for bounded host redispatch; do not return
> a model alongside a rewrite. See `claudedocs/plugins.md` for migration status.

# `luna.*` API reference

The authoritative typings are [`luna-plugin.d.ts`](../../tools/plugin-sim/luna-plugin.d.ts)
in this repo — reference it from your editor for autocomplete. This page adds
the things a `.d.ts` file cannot say: which process each namespace actually
works in, what error CODE each failure carries, and every constraint the
native code enforces that isn't visible from the type shape alone. Every
claim here is checked against the bridge source in
`LunaLibraries/Sources/LunaPluginRuntime/Bridges/`,
`LunaLibraries/Sources/LunaPluginUI/`, `LunaLibraries/Sources/LunaPluginExport/Bridges/`,
`LunaLibraries/Sources/LunaPluginTransport/`, and
`LunaSafari/Resources/plugin_host.js`.

For step-by-step authoring guidance, see [`README.md`](./README.md). For the
platform's internal design, see `claudedocs/plugins.md`.

## Availability at a glance

| Capability | app | share / action | Safari |
| --- | --- | --- | --- |
| (none — `register`/`parseURL`/`log`/`bytes`/`env`/`LunaError`/`localize`) | yes | yes | yes |
| `fetch` | yes | yes | relayed |
| `html` | yes (SwiftSoup) | yes (SwiftSoup) | yes (DOMParser); `article` relayed |
| `text` (installed with `html`, never declared) | yes | yes | yes |
| `page` | no | no | yes |
| `storage` | yes | yes | relayed |
| `secrets` | get/set/delete | get only | no |
| `files` | yes | yes | no |
| `crypto` | yes | yes | yes (SubtleCrypto) |
| `browser` | shows a modal | defers → save locks | defers → deep-links to the app |
| `downloads` | yes | yes | no |
| `settings` | get/set/all | get/all | `get` only (relayed, defaults included) |
| `ui` | yes | no | no |
| `mail` | yes | no | no |
| `notifications` | yes | no | no |
| `bluetooth` | yes | no | no |
| `wifi` | yes | no | no |
| `exports` | yes | no | no |

`luna.text` is the one namespace with no capability of its own: declaring
`html` installs both, because it is three pure string helpers with nothing to
grant. Declaring `"text"` in `capabilities` is an error — the manifest will not
parse.

A namespace your manifest didn't declare a capability for is `undefined` —
`typeof luna.mail === "undefined"`, not a stub. A namespace you DID declare,
in a process that can't serve it, exists but every call on it rejects with
code `unavailable-here`.

## Errors

Every rejection is a `LunaError` — `error instanceof luna.LunaError`, with
`.code` and `.message`. `error.details` is **not preserved across a plugin's
own thrown errors caught by the runtime** — only `code` and `message`
survive (this is why `export`'s terminal-failure signal is a code, `"hard"`,
not a `details` flag — see [`README.md`](./README.md#7-export-plugins)).

Codes you will see, and where they come from:

| Code | Where it comes from | Meaning |
| --- | --- | --- |
| `bad-argument` | almost every bridge | a required argument was missing or the wrong shape |
| `unavailable-here` | any bridge, for a capability this process can't serve | you're calling something the current process (extension/Safari) doesn't support — check the availability table above |
| `capability-not-declared` | Safari's native handler, on every relayed `plugins.*` message | the manifest never declared this capability — the content script is not trusted to enforce its own grants, so native re-checks on every call |
| `bridge-failed` | the default `PluginPromiseBox.fail` code | an unclassified native-side failure |
| `runtime` | `luna.crypto.randomBytes` | the system random source refused |
| `cancelled` | `luna.ui.*`, `luna.mail.send` (no `to` given, user dismissed the picker), `luna.browser.open` (the modal was dismissed) | the person cancelled a prompt/picker/browser step |
| `browser-deferred` | `luna.browser.open`, outside the app | not really an error to handle — let it propagate out of `ingest`; Luna locks the save and finishes later (see README §6) |
| `not-found` | `luna.files.read`, `luna.fetch` with a multipart `file` part | the scratch file behind that `FileHandle` is gone (its generation was reaped) |
| `not-text` | `luna.files.read` without `"base64"` | the file is not UTF-8 text; read it with `"base64"` |
| `too-large` | `luna.storage.set`, `luna.storage.collection(...).put`, `luna.files.write`, a multipart `file` part | the value is over the 256 KB per-key/per-row cap, or the file over 8 MB |
| `quota-exceeded` | `luna.files.write`, `luna.fetch` with `as: "file"` | this plugin has filled its current 256-file / 32 MB scratch allowance |
| `write-failed` | `luna.files.write`, `luna.fetch` with `as: "file"` | the scratch write failed |
| `not-configured` | `luna.mail.send` | no email account is connected — the documented `send-failed` branch never fires for this, the most common failure |
| `send-failed` | `luna.mail.send` | the mail transport itself failed |
| `fetch-failed` | `luna.fetch`, generic | the request failed for a reason with no more specific code |
| `network-refused` | `luna.fetch` | `LiveNetworkPolicy` refused the request before it was sent |
| `disconnected` | a `BluetoothSession` call, after the peripheral disconnects | every queued/in-flight call on that session rejects with this |
| `bluetooth-unavailable` | `luna.bluetooth.*` | the radio is off, unauthorized, or the manager could not be built |
| `timed-out` | `luna.bluetooth.connect`, a session's `next`, a session's `write` waiting for controller room | the operation's own timeout elapsed |
| `already-connecting` | `luna.bluetooth.connect` | a connect to that device is already waiting for its link — the first call's promise still stands, so await that one |
| `background` | `luna.wifi.join` | iOS only joins a network while Luna is in the foreground; catch this and prompt the person to open Luna instead of failing silently |
| `join-failed` | `luna.wifi.join` | the hotspot configuration itself failed to apply |
| `already-registered` / `invalid-hooks` | `luna.register` called again after the plugin loaded (every backing), or with something other than an object (Safari and the harness throw; the app fails the load) | a bug in your plugin, not a runtime condition to handle |

`throw new luna.LunaError(code, message)` from your own plugin code to
produce a specific code your `ingest`/`export`/etc. caller can read back
(`error.code`).

## `luna.register(hooks)`

```ts
luna.register(hooks: PluginHooks): void;
```

Call this exactly once, at the top level. Supplied hooks must be functions;
Luna captures their values once at registration. Results must be JSON-compatible;
serialization errors are reported as hook failures. **Every hook is called with
exactly one JSON argument** — this is why `onBluetooth` takes `event` alone
(read the live session with the separate, synchronous
`luna.bluetooth.session()`) and `onAction` takes `{ key, action? }` rather than a bare
string.

```ts
interface PluginHooks {
  classify?(input: ClassifyInput): ClassifyResult | Promise<ClassifyResult>;
  ingest?(input: IngestInput): Promise<PluginModel | null>;
  export?(input: ExportInput): Promise<ExportResult>;
  onBluetooth?(event: BluetoothEvent): Promise<void>;
  onSettingsChanged?(changes: Record<string, unknown>): Promise<void>;
  onAction?(input: { key: string; action?: "pair" | "unpair" }): Promise<void>;
}
```

An ingest plugin (`produces` non-empty) must define both `classify` and
`ingest`, or the plugin fails to load. An `export` declaration requires
`export`; a `bluetooth` declaration requires `onBluetooth`.

```ts
interface ClassifyInput { url: string; page?: PageSnapshot; context: "app"|"share"|"action"|"safari"; intent?: "transcribe" }
interface IngestInput {
  url: string; claim: { kind: PluginModelKind; itemId?: string }; page?: PageSnapshot;
  reason: "save"|"resume"|"refresh"|"reresolve"|"rescue"; context: "app"|"share"|"action"|"safari";
  saveId?: string; intent?: "transcribe";
}
```

`intent` is present ONLY when the user chose one of the app's Transcribe
actions; on a plain save, in the share and action extensions, and in Safari
the key is absent. A plugin that would store the media (`produces:
["media"]`) returns `false` from `classify` when `intent === "transcribe"`,
so the walk reaches a lower-priority plugin that reads the same URL as an
`article` — either text it already has (captions) or a `transcription` file
for Luna to transcribe (see [Models](#models)). A transcribe intent that no
plugin serves fails the save; it never falls through to a download.

## Always present

```ts
luna.parseURL(url: string, base?: string): ParsedURL | null;
luna.log(message: string, data?: unknown): void;
luna.bytes: {
  fromBase64(s: string): Uint8Array;
  toBase64(b: Uint8Array): string;
  utf8Encode(s: string): Uint8Array;
  utf8Decode(b: Uint8Array): string;
};
luna.env: { context: "app"|"share"|"action"|"safari"; api: 1; pluginId: string; version: string; locale: string; languages: string[] };
class luna.LunaError extends Error { code: string; message: string }
luna.localize(table: string | Record<string, string>): string;
```

`luna.log` writes to Luna's own diagnostics under a category named
`plugin.<your-id>` — visible from Settings → Diagnostics (five taps in blank
space on the top-level Settings screen), which is the primary way to debug a
plugin running inside the real app.

`env.languages` is the device's preferred language list, most-preferred
first, as BCP-47 tags (`env.locale` is always `env.languages[0]`).
`luna.localize` resolves a table you build at runtime — `{ en: "…", es:
"…" }` — against that same list: an exact tag, then that tag's language
(`pt-BR` → `pt`), then `en`. A manifest's own user-visible fields
(`name`, `description`, `export.title`, a `settings[]` field's `label`/
`help`/`placeholder`, an `options[].label`) accept the identical table
shape and are resolved the same way, once, at import time — see
[`README.md` §1](./README.md#1-the-file).

## `luna.fetch` (capability `fetch`)

```ts
luna.fetch(request: string | FetchRequest): Promise<FetchResponse>;
interface FetchRequest {
  url: string;
  method?: "GET" | "POST" | "HEAD" | "PUT";                 // default GET
  headers?: Record<string, string>;                          // Host/Content-Length are stripped
  userAgent?: "safari" | "googlebot" | "googlebot-mobile" | "bingbot" | "facebookbot" | string;
  body?: string | { base64: string } | { form: Record<string,string> } | { json: unknown }
       | { multipart: MultipartPart[] };
  cookies?: "shared" | "ephemeral" | "none";                  // default "shared"
  redirect?: "follow" | "manual" | "headThenGet";             // default "follow"
  maxBytes?: number;
  timeout?: number;                                           // seconds, default 20, IDLE-based
  as?: "text" | "base64" | "file";                            // default "text"; "file" needs the "files" capability
}
interface FetchResponse {
  ok: boolean; status: number; url: string; redirected: boolean;
  headers: Record<string, string>; text?: string; base64?: string; file?: FileHandle;
  truncated: boolean; bytes: number;
}

// The same call with the three answers you nearly always want:
luna.fetch.text(url, opts?): Promise<string>;
luna.fetch.json(url, opts?): Promise<unknown>;
luna.fetch.doc(url, opts?): Promise<HTMLDocument>;
interface MultipartPart {
  name: string; filename?: string; mime?: string;
  text?: string; base64?: string; file?: FileHandle;         // one of the three
}
```

A multipart part may carry a `FileHandle` instead of bytes, so a downloaded
or exported file uploads without a base64 round trip through your plugin.
`filename` and `mime` default to the handle's own. It needs the `files`
capability, so it works in the app and the share/action extensions and never
in Safari; a handle whose generation is gone rejects `not-found` and one over
8 MB rejects `too-large`, both before the request leaves.

`luna.fetch` is a function that also carries `text`, `json` and `doc`. Each is
a GET — `opts` is the ordinary request minus `url`, and `as` is forced to
`"text"` — and each rejects `fetch-failed` on a non-2xx status, with the method,
the URL and the status in the message. `json` rejects `fetch-failed` again when
the body does not parse. `doc` runs `luna.html.parse` over the body with the
base set to the FINAL url, so a relative link on a redirected page resolves
where the page actually came from; it needs the `html` capability as well and
rejects `capability-not-declared` without it.

The `shared` cookie jar persists for this plugin only; another plugin cannot
observe or reuse it. `ephemeral` creates a fresh, non-persistent jar for each
request, while `none` neither stores nor sends cookies (including a supplied
`Cookie` header). There is no cookie policy for the page's own session: read
`cookieHeader` off a `luna.browser.open` result and set the header yourself
when using the default `shared` policy. Any `cookies` value other than the
three rejects `bad-argument`. Every request is logged to your plugin's
diagnostics category and to the save's own trace.

## `luna.html` (capability `html`)

```ts
luna.html.parse(html: string, baseURL?: string): HTMLDocument;
luna.html.text(html: string): string;                          // strips tags, decodes entities, skips <script>/<style>
luna.html.jsonScripts(doc: HTMLDocument, type?: string): unknown[];
luna.html.jsonLD(doc: HTMLDocument): object[];                 // ld+json only, @graph flattened, bad JSON skipped
luna.html.meta(doc: HTMLDocument): PageMetadata;
luna.html.article(html: string, baseURL?: string): Promise<ExtractedArticle | null>;
interface PageMetadata {
  title?: string; description?: string; canonical?: string; image?: string;
  author?: string; published?: string; siteName?: string; language?: string; type?: string;
}
interface ExtractedArticle {
  title: string; html: string; text: string;
  author?: string; publishedAt?: string; leadImageURL?: string; excerpt?: string;
}
interface HTMLElement {
  querySelector(css: string): HTMLElement | null;
  querySelectorAll(css: string): HTMLElement[];                 // a real Array
  readonly textContent: string;    // skips <script>/<style> subtrees, matching SwiftSoup's Element.text()
  readonly innerHTML: string;
  readonly outerHTML: string;
  readonly children: HTMLElement[];
  readonly parentElement: HTMLElement | null;
  readonly tagName: string;                                     // upper-case
  getAttribute(name: string): string | null;
  hasAttribute(name: string): boolean;
  readonly attributes: Record<string, string>;
  matches(css: string): boolean;
  closest(css: string): HTMLElement | null;
  readonly baseURI: string;
  absoluteURL(attr: string): string | null;                     // resolves href/src against baseURI
}
interface HTMLDocument extends HTMLElement {
  readonly title: string; readonly documentElement: HTMLElement;
  readonly body: HTMLElement | null; readonly head: HTMLElement | null;
}
```

Selectors are limited to what SwiftSoup supports: type, class, id, attribute
(`=`, `^=`, `$=`, `*=`), descendant/child combinators, `:not()`,
`:first-child`, `:nth-child`. `LunaTests/Fixtures/Plugins/html-subset.spec.js`
(108 cases) is the exact specification — it is run against all three backings
(SwiftSoup, `plugin_host.js`'s DOMParser, and the node harness's `linkedom`)
and any disagreement is a bug in one of the three, never something you need
to special-case.

`jsonLD` reads only `application/ld+json` (use `jsonScripts` for a page's other
JSON blocks). A top-level array is spread, one `@graph` array inside an object
is spread, a block that does not parse is skipped, and the answer is always an
array.

`meta` reads the page's own account of itself and omits a key nothing states.
Per key, the first source that says anything wins:

| Key | Sources, in order |
| --- | --- |
| `title` | `og:title`, `twitter:title`, `<title>`, JSON-LD `headline`, JSON-LD `name` |
| `description` | `og:description`, `twitter:description`, `<meta name=description>` |
| `canonical` | `og:url`, `<link rel=canonical>` |
| `image` | `og:image`, `og:image:url`, `twitter:image`, `twitter:image:src`, JSON-LD `image` |
| `author` | `<meta name=author>`, `article:author`, JSON-LD `author` |
| `published` | `article:published_time`, `<meta name=date>`, `<meta name=pubdate>`, `itemprop=datePublished`, JSON-LD `datePublished` |
| `siteName` | `og:site_name`, `<meta name=application-name>` |
| `language` | `<html lang>`, `<meta http-equiv=content-language>`, JSON-LD `inLanguage` |
| `type` | `og:type` |

Only JSON-LD objects whose `@type` is `Article`, `NewsArticle`, `BlogPosting`
or `Product` answer for the document. A JSON-LD `author` may be a string, an
object with a `name`, or a list of either; an `image` may be a string, an
`ImageObject` with a `url`, or a list (the first entry wins). Every value is
whitespace-collapsed and trimmed, and `image`/`canonical` are resolved against
the document's base. `<meta property=X>` and `<meta name=X>` are both read for
the same key, because pages write OpenGraph and Twitter cards either way.

`article` runs Luna's own main-content extraction — the same pass Luna's
article ingest runs — and answers `null` when the page has no article body,
which is your cue to `return null` and let Luna continue. `html` carries only
the tags an `ArticleModel` keeps; `publishedAt` is already normalized through
`luna.text.date`. **It answers a Promise in every process**, including the app:
Safari has no readability pass of its own and relays the call to Luna, so a
synchronous shape could not hold everywhere. `await` it. A page over ~1.5 MB
rejects `too-large` in Safari, where the HTML has to cross the native message
channel.

## `luna.text` (installed with the `html` capability)

```ts
luna.text.price(s: string): { amount: string; currency?: string } | null;
luna.text.date(s: string): string | null;
luna.text.clean(s: string): string;
```

`price` reads the first run of digits in the string with Luna's own separator
rules: when both `.` and `,` appear the LATER one is the decimal point
(`"1.299,00"` → `1299.00`), and a lone comma is a decimal point only before one
or two digits (`"23,50"` → `23.50`, `"1,234"` → `1234`). `amount` keeps the
fraction digits the page wrote, which is what `price.amount` on a `ProductModel`
wants. `currency` is filled only from what TOUCHES the number — one of `$` `£`
`€` `¥`, or a three upper-case letter code immediately before or after it — so
a sentence full of capitals does not name a currency. A string with no digits
answers `null`.

`date` answers ISO 8601: `2024-03-04T09:30:00Z` when the string carried a time
(converted to UTC; a time with no zone is read as UTC), and `2024-03-04` when it
did not — the day the page named, not a guess at its hour. It reads ISO 8601,
`YYYY-MM-DD HH:mm`, `YYYY/MM/DD`, `Month D, YYYY`, `D Month YYYY` and RFC 2822.
A relative phrase ("2 hours ago") and a day that does not exist answer `null`.

`clean` decodes entities, drops tags the way `luna.html.text` does, collapses
every whitespace run — a `&nbsp;` run included — to one space, and trims.

`luna.html`'s and `luna.text`'s exact answers are specified case by case in
`LunaTests/Fixtures/Plugins/html-subset.spec.js` and run against all three
backings.

## `luna.page` (capability `page`, Safari only)

```ts
luna.page.document(): HTMLDocument;   // the LIVE page, wrapped in the §html subset
luna.page.url(): string;
luna.page.title(): string;
luna.page.html(): string;             // first 200,000 chars of documentElement.outerHTML
luna.page.truncated(): boolean;       // true when html() omitted the document tail
```

## `luna.storage` (capability `storage`)

```ts
luna.storage.get(key: string): Promise<unknown | undefined>;   // undefined for a key that holds nothing
luna.storage.set(key: string, value: unknown): Promise<void>;   // JSON, ≤ 256 KB
luna.storage.delete(key: string): Promise<void>;
luna.storage.keys(prefix?: string): Promise<string[]>;
luna.storage.collection(name: string): Collection;
interface Collection {
  put(id: string, doc: object, index?: { k1?: string; k2?: string }): Promise<void>;
  get(id: string): Promise<object | undefined>;
  delete(id: string): Promise<void>;
  find(where?: { k1?: string; k2?: string }, opts?: { limit?: number; offset?: number }): Promise<{ id: string; doc: object }[]>;
  count(where?: { k1?: string; k2?: string }): Promise<number>;
}
```

Scoped per plugin id automatically — two plugins may reuse the same key or
collection name and never see each other's data. Backed by `saves.sqlite`'s
`plugin_kv`/`plugin_collections` tables, visible from every process your
plugin runs in (Safari relays through native messaging).

Aggregate limits are also per plugin: 1,024 keys / 5 MiB of KV JSON and
10,000 rows / 10 MiB of collection JSON. Each individual value or document
remains capped at 256 KiB. An atomic write that would cross a limit rejects
with `quota-exceeded`; unavailable App-Group storage and failed writes reject
as `storage-unavailable` and `write-failed` instead of looking like a missing
key or a successful delete.

## `luna.secrets` (capability `secrets`)

```ts
luna.secrets.get(key: string): Promise<string | undefined>;
luna.secrets.set(key: string, value: string): Promise<void>;   // app only
luna.secrets.delete(key: string): Promise<void>;               // app only
```

Keychain-backed, one item per `(pluginId, key)`. `set`/`delete` from an
extension reject `unavailable-here`.

## `luna.files` (capability `files`)

```ts
interface FileHandle { readonly id: string; readonly name: string; readonly size: number; readonly mime?: string }
luna.files.write(name: string, data: string | { base64: string }, mime?: string): Promise<FileHandle>;
luna.files.read(handle: FileHandle, as: "text" | "base64"): Promise<string>;
luna.files.size(handle: FileHandle): Promise<number>;
```

A `FileHandle` lives in your plugin's scratch directory. One generation of
that directory is open while ANY call of your plugin is in flight, so a file
written inside a nested call survives until the outer one ends too; it is
reaped when the last of them does. An `export` hook's file result is copied
into the share's own directory before that happens, so the share sheet still
reads it. Reading a handle after its generation is reaped rejects
`not-found`, and `read` without `"base64"` on bytes that are not UTF-8
rejects `not-text`.

Plugin-created scratch data is capped at 256 files and 32 MB per plugin. The
check and write are serialized, so a rejected write leaves no partial file.
Files Luna adopts from an existing save for an `export` hook are exempt: those
host-owned inputs can legitimately be much larger and are still reaped with the
same generation.

## `luna.crypto` (capability `crypto`)

```ts
luna.crypto.sha256(data: string | { base64: string }): Promise<string>;              // base64 digest
luna.crypto.hmacSHA256(key: { base64: string } | string, data: string | { base64: string }): Promise<string>;
luna.crypto.randomBytes(count: number): Promise<string>;                             // base64
```

## `luna.browser` (capability `browser`)

```ts
luna.browser.open(request: BrowserRequest): Promise<BrowserResult>;
interface BrowserRequest {
  url: string;
  saveId?: string;                              // only when several ingest calls are in flight
  userAgent?: "device-safari" | string;         // default: the device-matched Safari UA
  headers?: Record<string, string>;             // only Referer / Accept-Language
  cookies?: "persistent" | "ephemeral";         // default "persistent"
  detect: string;                               // evaluated every 350ms; must answer "wait"|"challenge"|"done"|"error"
  title?: string;
  timeout?: number;                             // seconds the modal may stay open, default 300
}
interface BrowserResult {
  url: string; html: string; title: string; cookieHeader: string;
  cookies: { name: string; value: string; domain: string }[];
}
```

See [`README.md` §6](./README.md#6-the-browser-step-and-why-a-hook-re-runs)
for what actually happens per process. `result.html` is capped at 6 MB. A
browser step belongs to a save: Luna uses the one your plugin is ingesting.
Pass `saveId` when your plugin has several `ingest` calls in flight at once —
without it that case rejects `bad-argument`.

## `luna.downloads` (capability `downloads`)

```ts
luna.downloads.jobs(): Promise<DownloadJob[]>;
luna.downloads.job(saveId: string): Promise<DownloadJob | null>;
interface DownloadJob {
  saveId: string | null;      // null once the save that started this download is gone
  sourceUrl: string;
  title: string;
  phase: "resolving" | "downloading" | "waiting" | "suspended" | "saving" | "finished" | "failed";
  progress: number;
  receivedBytes: number | null;
  expectedBytes: number | null;
  failure: string | null;
  pluginId: string | null;
  quality: string | null;
}
```

Read-only: a job's own destination plugin resolves it through the `ingest`
hook's `reason: "reresolve"` (§6.9 of `claudedocs/plugins.md`), never through
this bridge. `job(saveId)` rejects `bad-argument` for a `saveId` that isn't a
UUID and answers `null` for a save with no active or recent job. `phase` is
the download engine's own state names, not a translated status. App, share
and action alike — the bridge reads the shared saves database directly, not
the download manager. Absent in Safari.

## `luna.settings` (capability `settings`)

```ts
luna.settings.get(key: string): Promise<unknown>;      // a secret field reads back as "" once set, never the value
luna.settings.set(key: string, value: unknown): Promise<void>;   // app only; validated against your schema
luna.settings.all(): Promise<Record<string, unknown>>;
```

`set` also accepts a key starting with `_` even though your manifest can
never DECLARE one — `_status` is reserved for a destination plugin's own
share-row status dot (write `"live"` to light it, anything else to dim it).

## `luna.ui` (capability `ui`, app only)

```ts
luna.ui.prompt(opts: { title: string; message?: string; placeholder?: string; keyboard?: "default"|"email"|"url"|"number"; secure?: boolean; default?: string }): Promise<string | null>;
luna.ui.confirm(opts: { title: string; message?: string; ok?: string; cancel?: string; destructive?: boolean }): Promise<boolean>;
luna.ui.choose(opts: { title: string; options: { id: string; label: string; detail?: string }[] }): Promise<string | null>;
luna.ui.toast(message: string): Promise<void>;
luna.ui.shareSheet(items: (FileHandle | { url: string } | { text: string })[]): Promise<void>;
```

## `luna.mail` (capability `mail`, app only)

```ts
luna.mail.send(message: MailMessage): Promise<{ status: "sent" }>;
interface MailMessage {
  to?: string[];              // omit for a native recipient picker; a cancel rejects with code "cancelled"
  subject: string; text?: string; html?: string;
  attachments?: { file: FileHandle; name?: string; mime?: string }[];   // ≤ 25 MB total
}
luna.mail.isConfigured(): Promise<boolean>;
```

Native builds the MIME message; your plugin never sees raw headers or the
account's credentials.

## `luna.notifications` (capability `notifications`, app only)

```ts
luna.notifications.post(n: { title: string; body?: string; identifier?: string; deepLink?: string }): Promise<{ posted: boolean }>;
luna.notifications.clear(identifier?: string): Promise<void>;
```

Never requests notification authorization itself — `posted: false` when the
user hasn't granted it. Luna's own launch design never asks for this
permission on your plugin's behalf either; if your plugin genuinely needs
notifications, the user must have already granted them some other way.

## `luna.bluetooth` (capability `bluetooth`, app only)

```ts
luna.bluetooth.state(): Promise<"poweredOn"|"poweredOff"|"unauthorized"|"unsupported"|"unknown">;
luna.bluetooth.pair(): Promise<BluetoothDevice | null>;
luna.bluetooth.pairedDevices(): Promise<BluetoothDevice[]>;
luna.bluetooth.unpair(deviceId: string): Promise<void>;
luna.bluetooth.connect(deviceId: string, opts?: { timeout?: number }): Promise<BluetoothSession>;
luna.bluetooth.session(): BluetoothSession | null;    // SYNCHRONOUS — see below
interface BluetoothSession {
  readonly device: BluetoothDevice;
  readonly mtu: number;
  discover(serviceUUID: string): Promise<{ characteristics: string[] }>;
  read(characteristicUUID: string): Promise<string>;                                     // base64
  write(characteristicUUID: string, base64: string, opts?: { response?: boolean }): Promise<void>;
  subscribe(characteristicUUID: string): Promise<void>;
  next(characteristicUUID: string, opts?: { timeout?: number }): Promise<string>;         // base64
  disconnect(): Promise<void>;
}
```

`session()` answers the LIVE session for the connection your manifest's
`bluetooth` declaration owns, if one exists right now — it never blocks and
never throws; a null answer just means "no session," which is different
from "you'll have to wait." It stays valid across a nested `export` call
your `onBluetooth` handler triggers via `luna.exports.deliverQueued()`.
`connect` is the foreground path (pairing/manual connection flows);
`onBluetooth("connected")` plus `session()` is the background rendezvous
path. `luna.bluetooth.pair()` needs `bluetooth.pairing: "accessorySetupKit"`
in your manifest.

## `luna.wifi` (capability `wifi`, app only)

```ts
luna.wifi.join(opts: { ssid: string; passphrase?: string; joinOnce?: boolean }): Promise<{ joined: boolean }>;
luna.wifi.forget(ssid: string): Promise<void>;
luna.wifi.isReachable(host: string, port: number, opts?: { timeout?: number }): Promise<boolean>;
```

`join` rejects with code `background` when Luna is not in the foreground —
iOS only applies a hotspot join then. Upload the actual bytes with
`luna.fetch({ method: "POST", body: { multipart: [{ name: "file", file }] } })`
— there is no separate transfer API.

## `luna.exports` (capability `exports`, destination plugins, app only)

```ts
luna.exports.deliverQueued(): Promise<{ delivered: number; remaining: number }>;
luna.exports.queued(): Promise<{ saveId: string; title: string; queuedAt?: string }[]>;
luna.exports.markSent(saveId: string): Promise<void>;
luna.exports.pendingDeletes(): Promise<{ saveId: string; title: string; remoteName: string }[]>;
luna.exports.markRemoteDeleted(saveId: string): Promise<void>;
luna.exports.markReadOnDevice(saveId: string): Promise<void>;
```

`deliverQueued` runs your `export` hook once per item Luna has queued for
this destination, ignoring the normal backoff delay — call it from
`onBluetooth`/`onSettingsChanged` when a device becomes reachable.
`markSent` is for reconciliation: tell Luna an item is delivered when the
DEVICE reports it (rather than your `export` hook itself), e.g. an
e-reader that reports which books it already has on its next connection.

The last three are for a device that tracks reading of its own.
`markReadOnDevice` says the DEVICE finished the save: Luna marks it read,
scores it complete and files it away, and records that the device already
holds it so no delete is asked for. `pendingDeletes` lists the saves you
delivered whose reading finished IN Luna, each with the `remoteName` your
`export` reported — delete those on the device, then `markRemoteDeleted` each
one. Answer `remoteName` from `export` or Luna has no name to give back.

## Models

See [`README.md` §2](./README.md#2-writing-an-ingest-plugin-step-by-step) for
worked examples of each. Every string/URL field has a cap enforced at
decode time (`PluginModelCaps` in
`LunaLibraries/Sources/LunaModels/Plugin/PluginModel.swift`): titles/names
300 characters, most other strings 200, an excerpt 1000, a URL string 4096
(long enough for a signed CDN URL carrying its whole signature in the
query), an article's `html` 4 MB, `assets` 1–50 entries, `sellers` up to 20.
A relative URL is resolved against the page's own URL for you; only an
ABSOLUTE URL with a non-http(s) scheme is refused. Asset/document/
transcription `headers` are filtered to `user-agent`, `referer`, `cookie`,
`accept`, `accept-language`, `origin`, `range` — any other header name is a
decode error.

An `article` Model has three body sources, tried in this order by Luna:
`document` (a file Luna parses), `transcription` (an audio or video file Luna
downloads, transcribes on device and deletes; the save waits as pending until
the transcript is written), then `html`. `html` is required only when neither
file spec is set; beside `transcription` it is optional text that precedes
the transcript. `document` and `transcription` together are a decode error.
A transcript plugin should offer the cheapest source it can: text the site
already publishes (captions) as plain `html`, else an audio-only file, else
the video.

```ts
type PluginModelKind = "article" | "media" | "product";

interface MediaAssetSpec {
  url: string; type: "video" | "image" | "gif" | "audio";
  audioURL?: string; dashManifestURL?: string; thumbnailURL?: string;
  estimatedBytes?: number; headers?: Record<string, string>;
  timeRange?: { start: number; end: number }; quality?: string;
}
interface MediaModel {
  kind: "media"; title?: string; author?: string; thumbnailURL?: string;
  platform?: string; itemId?: string; assets: MediaAssetSpec[]; expiresAt?: number;
}

interface ArticleDocumentSpec { url: string; type: "pdf"|"epub"|"docx"|"rtf"|"html"|"md"|"txt"; headers?: Record<string,string> }
interface ArticleTranscriptionSpec {
  url: string; type: "audio" | "video";
  audioURL?: string;                 // a separate audio leg for a video: only this is fetched
  headers?: Record<string,string>;   // same allowed names as an asset's headers
  expiresAt?: number;                // epoch seconds; stale → ingest re-runs with reason "reresolve"
}
interface ArticleModel {
  kind: "article"; title: string; author?: string; publishedAt?: string;
  html?: string;                     // required unless document or transcription is set; text precedes a transcript
  baseURL?: string; leadImageURL?: string; excerpt?: string;
  language?: string;                 // BCP-47; also the transcription language when set
  document?: ArticleDocumentSpec;    // never together with transcription
  transcription?: ArticleTranscriptionSpec;
}

interface Price { amount: string; currency: string }   // amount is a decimal STRING
interface ProductModel {
  kind: "product"; name: string; price: Price; imageURL?: string; brand?: string;
  productId?: string; identifiers?: { gtin?: string; mpn?: string; sku?: string; brand?: string };
  sellers?: { url: string; name?: string; price?: Price }[];
}
```

## Manifest reference

See [`README.md` §1](./README.md#1-the-file) for the field table with
authoring guidance, and `docs/plugins/examples/` for two complete,
tested files. The full `PluginManifest`/`SettingField`/`ExportDeclaration`/
`BluetoothDeclaration` shapes are typed in
[`luna-plugin.d.ts`](../../tools/plugin-sim/luna-plugin.d.ts).
