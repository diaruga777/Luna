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
| (none — `register`/`parseURL`/`log`/`bytes`/`env`/`LunaError`) | yes | yes | yes |
| `fetch` | yes | yes | relayed |
| `html` | yes (SwiftSoup) | yes (SwiftSoup) | yes (DOMParser) |
| `page` | no | no | yes |
| `storage` | yes | yes | relayed |
| `secrets` | get/set/delete | get only | no |
| `files` | yes | yes | no |
| `crypto` | yes | yes | yes (SubtleCrypto) |
| `browser` | shows a modal | defers → save locks | defers → deep-links to the app |
| `downloads` | **no bridge exists** | **no bridge exists** | no |
| `settings` | get/set/all | get/all | get only, relayed |
| `ui` | yes | no | no |
| `mail` | yes | no | no |
| `notifications` | yes | no | no |
| `bluetooth` | yes | no | no |
| `wifi` | yes | no | no |
| `exports` | yes | no | no |

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
| `bridge-failed` | the default `PluginPromiseBox.fail` code | an unclassified native-side failure |
| `cancelled` | `luna.ui.*`, `luna.mail.send` (no `to` given, user dismissed the picker), `luna.browser.open` (the modal was dismissed) | the person cancelled a prompt/picker/browser step |
| `browser-deferred` | `luna.browser.open`, outside the app | not really an error to handle — let it propagate out of `ingest`; Luna locks the save and finishes later (see README §6) |
| `not-found` | `luna.files.read`/`.size` | the scratch file behind that `FileHandle` is gone (its invocation already settled and was reaped) |
| `too-large` | `luna.storage.collection(...).put` | the document is over the 256 KB per-row cap |
| `write-failed` | `luna.files.write` | the scratch write failed |
| `send-failed` | `luna.mail.send` | the mail transport itself failed |
| `fetch-failed` | `luna.fetch`, generic | the request failed for a reason with no more specific code |
| `network-refused` | `luna.fetch` | `LiveNetworkPolicy` refused the request before it was sent |
| `disconnected` | a `BluetoothSession` call, after the peripheral disconnects | every queued/in-flight call on that session rejects with this |
| `bluetooth-unavailable` | `luna.bluetooth.*` | the radio is off, unauthorized, or the manager could not be built |
| `timed-out` | `luna.bluetooth.connect`, a session's `next` | the operation's own timeout elapsed |
| `background` | `luna.wifi.join` | iOS only joins a network while Luna is in the foreground; catch this and prompt the person to open Luna instead of failing silently |
| `already-registered` / `invalid-hooks` | Safari's `luna.register`, if called twice or with something other than an object | a bug in your plugin, not a runtime condition to handle |

`throw new luna.LunaError(code, message)` from your own plugin code to
produce a specific code your `ingest`/`export`/etc. caller can read back
(`error.code`).

## `luna.register(hooks)`

```ts
luna.register(hooks: PluginHooks): void;
```

Call this exactly once, at the top level. **Every hook is called with
exactly one JSON argument** — this is why `onBluetooth` takes `event` alone
(read the live session with the separate, synchronous
`luna.bluetooth.session()`) and `onAction` takes `{ key }` rather than a bare
string.

```ts
interface PluginHooks {
  classify?(input: ClassifyInput): ClassifyResult | Promise<ClassifyResult>;
  ingest?(input: IngestInput): Promise<PluginModel | null>;
  export?(input: ExportInput): Promise<ExportResult>;
  onBluetooth?(event: BluetoothEvent): Promise<void>;
  onSettingsChanged?(changes: Record<string, unknown>): Promise<void>;
  onAction?(input: { key: string }): Promise<void>;
}
```

An ingest plugin (`produces` non-empty) must define both `classify` and
`ingest`, or the plugin fails to load. An `export` declaration requires
`export`; a `bluetooth` declaration requires `onBluetooth`.

## Always present

```ts
luna.parseURL(url: string, base?: string): ParsedURL;
luna.log(message: string, data?: unknown): void;
luna.bytes: {
  fromBase64(s: string): Uint8Array;
  toBase64(b: Uint8Array): string;
  utf8Encode(s: string): Uint8Array;
  utf8Decode(b: Uint8Array): string;
};
luna.env: { context: "app"|"share"|"action"|"safari"; api: 1; pluginId: string; version: string; locale: string };
class luna.LunaError extends Error { code: string; message: string }
```

`luna.log` writes to Luna's own diagnostics under a category named
`plugin.<your-id>` — visible from Settings → Diagnostics (five taps in blank
space on the top-level Settings screen), which is the primary way to debug a
plugin running inside the real app.

## `luna.fetch` (capability `fetch`)

```ts
luna.fetch(request: string | FetchRequest): Promise<FetchResponse>;
interface FetchRequest {
  url: string;
  method?: "GET" | "POST" | "HEAD" | "PUT";                 // default GET
  headers?: Record<string, string>;                          // Host/Content-Length are stripped
  userAgent?: "safari" | "googlebot" | "googlebot-mobile" | "bingbot" | "facebookbot" | string;
  body?: string | { base64: string } | { form: Record<string,string> } | { json: unknown }
       | { multipart: MultipartPart[] };                     // MultipartPart has NO `file` field
  cookies?: "shared" | "ephemeral" | "none" | "browser";      // default "shared"
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
```

`cookies: "browser"` needs `luna.browser` to have run first in this
invocation — outside the app it rejects `unavailable-here` (there is no web
view to read cookies from). Every request is logged to your plugin's
diagnostics category and to the save's own trace.

## `luna.html` (capability `html`)

```ts
luna.html.parse(html: string, baseURL?: string): HTMLDocument;
luna.html.text(html: string): string;                          // strips tags, decodes entities, skips <script>/<style>
luna.html.jsonScripts(doc: HTMLDocument, type?: string): unknown[];
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
(60 cases) is the exact specification — it is run against all three backings
(SwiftSoup, `plugin_host.js`'s DOMParser, and the node harness's `linkedom`)
and any disagreement is a bug in one of the three, never something you need
to special-case.

## `luna.page` (capability `page`, Safari only)

```ts
luna.page.document(): HTMLDocument;   // the LIVE page, wrapped in the §html subset
luna.page.url(): string;
luna.page.title(): string;
luna.page.html(): string;             // documentElement.outerHTML
```

## `luna.storage` (capability `storage`)

```ts
luna.storage.get(key: string): Promise<unknown | undefined>;
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

A `FileHandle` lives in a per-invocation scratch directory reaped when the
hook that made it settles — unless an `export` hook returns it, in which
case Luna retains it long enough for the share sheet to read it. Reading a
handle after that window closes rejects `not-found`.

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
for what actually happens per process. `result.html` is capped at 6 MB.

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
`luna.fetch({ method: "POST", body: { multipart: [...] } })` — there is no
separate transfer API.

## `luna.exports` (capability `exports`, destination plugins, app only)

```ts
luna.exports.deliverQueued(): Promise<{ delivered: number; remaining: number }>;
luna.exports.queued(): Promise<{ saveId: string; title: string; queuedAt: string }[]>;
luna.exports.markSent(saveId: string): Promise<void>;
```

`deliverQueued` runs your `export` hook once per item Luna has queued for
this destination, ignoring the normal backoff delay — call it from
`onBluetooth`/`onSettingsChanged` when a device becomes reachable.
`markSent` is for reconciliation: tell Luna an item is delivered when the
DEVICE reports it (rather than your `export` hook itself), e.g. an
e-reader that reports which books it already has on its next connection.

## Models

See [`README.md` §2](./README.md#2-writing-an-ingest-plugin-step-by-step) for
worked examples of each. Every string/URL field has a cap enforced at
decode time (`PluginModelCaps` in
`LunaLibraries/Sources/LunaModels/Plugin/PluginModel.swift`): titles/names
300 characters, most other strings 200, an excerpt 1000, a URL string 4096
(long enough for a signed CDN URL carrying its whole signature in the
query), an article's `html` 4 MB, `assets` 1–50 entries, `sellers` up to 20.
A relative URL is resolved against the page's own URL for you; only an
ABSOLUTE URL with a non-http(s) scheme is refused. Asset/document `headers`
are filtered to `user-agent`, `referer`, `cookie`, `accept`,
`accept-language`, `origin`, `range` — any other header name is a decode
error.

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
interface ArticleModel {
  kind: "article"; title: string; author?: string; publishedAt?: string;
  html: string; baseURL?: string; leadImageURL?: string; excerpt?: string;
  language?: string; document?: ArticleDocumentSpec;
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
