# Writing a Luna plugin

This guide is for a JavaScript developer with no iOS background. It walks
through writing, testing and importing a plugin for Luna, the iOS app.

A plugin is one `.js` file. It extends one of two things Luna does:

- **Ingest** — turn a URL into a Model Luna can save (an article, a media
  item, or a product). Only central Luna (the paid, all-kinds app) runs
  plugins; the three sibling apps do not.
- **Export** — turn a saved item into a file, or deliver it somewhere
  (email, a webhook, a Bluetooth reader).

Luna never runs a plugin-authored screen. It renders every Model with its
own built-in reader, media card, or product card. A plugin's job stops at
"here is the data"; Luna's job is showing it.

For the full API reference, see [`api.md`](./api.md) and
[`luna-plugin.d.ts`](../../tools/plugin-sim/luna-plugin.d.ts) in this repo.
For a deeper, code-cited account of how the platform works internally, see
`claudedocs/plugins.md`.

## 1. The file

A plugin file has two parts: a header comment, and a body.

```js
/* luna-plugin
{
  "id": "app.luna.reddit",
  "name": "Reddit",
  "version": "1.0.0",
  "api": 1,
  "produces": ["media"],
  "match": { "hosts": ["reddit.com", "*.reddit.com", "redd.it", "*.redd.it"] },
  "priority": 100,
  "capabilities": ["fetch"]
}
*/
luna.register({
  classify({ url }) { /* … */ },
  async ingest({ url, claim }) { /* … */ },
});
```

The header must be the very first thing in the file — the first
non-whitespace characters must be `/*`, and the comment's first line
(trimmed) must read `luna-plugin`. Everything after that line, up to the
closing `*/`, is parsed as one JSON object. Luna reads this header WITHOUT
running any of your code — this is what lets it show a safe "here's what
this plugin can do" screen before installing anything.

The most important header fields:

| Field | Meaning |
| --- | --- |
| `id` | A reverse-DNS string, lowercase letters/digits/`.`/`-` only, e.g. `"app.luna.reddit"`. This is your plugin's permanent identity — it is also a folder name on disk, so keep it stable across versions. |
| `name` | Shown in Settings and on the install screen. ≤ 40 characters. |
| `version` | `major.minor.patch`, e.g. `"1.0.0"`. |
| `api` | Always `1` right now. |
| `produces` | For an ingest plugin: which Model kinds it can return — any of `"article"`, `"media"`, `"product"`. Omit this entirely for an export-only plugin. |
| `match` | For an ingest plugin: `{ "hosts": [...] }` (exact hostnames or `"*.example.com"` wildcards) or `{ "any": true }` for a plugin that inspects the URL shape rather than the host. |
| `priority` | A number; higher runs first among plugins that match the same URL. Bundled plugins ship at `100`. |
| `capabilities` | The `luna.*` namespaces this plugin needs (§4). An undeclared namespace simply does not exist on `luna` — there is no way to reach it by accident. |

The body must call `luna.register({ ... })` **exactly once**, at the top
level of the file. `register` is the only thing on `luna` before that call.

A user-visible field — `name`, `description`, `export.title`, and a
`settings[]` field's `label`/`help`/`placeholder`/`options[].label` — may be
a table instead of a plain string, keyed by BCP-47 language tag, which MUST
include `"en"`:

```json
"label": { "en": "Kindle address", "es": "Dirección de Kindle" }
```

Luna resolves this to one string when it imports the plugin, matching the
device's own preferred languages (an exact tag, then that tag's language —
`"pt-BR"` falls back to `"pt"` — then `"en"`). Your own code can apply the
same rule to a table it builds at runtime with `luna.localize(table)`.



## 2. Writing an ingest plugin, step by step

We'll build the bundled Reddit plugin
(`LunaLibraries/Sources/LunaBundledPlugins/Plugins/reddit.js`) up from
nothing. Its job: given a Reddit post URL, find the hosted video.

### Step 1 — `classify`: is this URL yours?

```js
luna.register({
  classify({ url }) {
    const parsed = luna.parseURL(url);
    const id = postID(parsed);           // your own logic
    if (id) return { kind: "media", itemId: id };
    return false;
  },
});
```

`classify` runs for every matched plugin, in priority order, the moment a
URL is saved. It must be fast and cheap — Luna gives it 8 seconds, and it
normally needs none of that: reading the URL's own shape (path, query) is
almost always enough. Return `false` when the URL is not yours. Return
`{ kind, itemId? }` when it is — `kind` must be one of the values you listed
in `produces`.

`classify` CAN call `luna.fetch`/`luna.html` if it genuinely needs to look at
the page (say, a redirecting share link with no id in it), but most plugins
never need to. It should not call anything else — `luna.storage`, `luna.ui`
and the rest are for `ingest` and later, not this quick a decision — mainly
because of the budget: `classify` gets 8 seconds total, and a call that waits
on a modal or a slow write eats into the same window every other matched
plugin's `classify` also has to fit inside.

The FIRST plugin to claim a URL wins; Luna does not ask any lower-priority
plugin after that. If every matched plugin declines, Luna's own built-in
classifier decides — your plugin adds new sites, it never has to replace
existing ones.

### Step 2 — `ingest`: build the Model

Once your plugin has claimed the URL, Luna calls `ingest` with that same
claim:

```js
async ingest({ url, claim }) {
  const id = claim.itemId;
  const listing = await getJSON({
    url: "https://www.reddit.com/comments/" + id + ".json",
    headers: { Accept: "application/json" },
  });
  const post = sourcePost(listing);
  if (!post) return null;                 // see "declining", below

  const video = post.secure_media?.reddit_video;
  if (!video) return null;

  return {
    kind: "media",
    platform: "reddit",
    itemId: id,
    assets: [{ url: video.fallback_url, type: "video" }],
  };
},
```

`ingest` gets a generous budget: 30 seconds of **idle** time (every
`luna.fetch`/`luna.html` call resets the clock, so a slow server is fine as
long as your plugin is actually waiting on it, not stuck).

### Step 3 — declining

Sometimes `classify` claims a URL, and `ingest` then discovers the page has
nothing usable (a deleted post, a gallery with no video, whatever). Return
`null` — not `false`, not an error:

```js
if (!video) return null;
```

`null` tells Luna "I looked, and there's nothing here for me." Luna moves on
to the next matched plugin, and finally to its own built-in classifier. A
plugin that THROWS an error, times out, or returns something malformed also
falls through the same way — one broken plugin can never stop Luna from
saving a page some other path could still handle.

### Step 4 — the Model shapes

Your `ingest` hook returns one of three shapes, matching what you listed in
`produces`:

**`media`** (see full shape in [`api.md`](./api.md#mediamodel)):

```js
return {
  kind: "media",
  title: "…",                 // optional
  platform: "reddit",         // free text; Luna maps known names to its own icons
  itemId: "…",
  assets: [
    { url: "https://…/video.mp4", type: "video" },
    // a separate audio track, for sites (like Reddit) that split them:
    { url: "https://…/audio.mp4", type: "audio", audioURL: "…" },
  ],
};
```

`assets` is 1–50 entries, shown in that order. Luna's own download engine
fetches these — your plugin never downloads anything itself.

**`article`**:

```js
return {
  kind: "article",
  title: "…",
  html: "<p>the cleaned body, as a fragment</p>",   // ≤ 4 MB
  author: "…",                                      // optional
  publishedAt: "2026-01-01T00:00:00Z",               // optional, ISO 8601
};
```

Luna's reader renders `html` almost as-is (no readability scoring — your
plugin already chose the body). Point `document` at a URL instead of/beside
`html` when the real content is a PDF/EPUB/DOCX file Luna should download and
open as a document.

**`product`**:

```js
return {
  kind: "product",
  name: "…",
  price: { amount: "19.99", currency: "USD" },   // amount is a STRING — never a float
  imageURL: "…",                                  // optional
};
```

Add `sellers: [{ url, name?, price? }]` (up to 20) if your plugin already
knows about alternative sellers — Luna then skips its own seller search for
that item.

Every field has a size cap (titles 300 characters, a URL string 4096
characters, and so on) — see `PluginModelCaps` in `api.md`. A URL you write
may be a relative path; Luna resolves it against the page's own URL for you.

## 3. `luna.html` — reading a page

```js
const doc = luna.html.parse(html, url);
const title = doc.querySelector("h1.title")?.textContent;
const image = doc.querySelector('meta[property="og:image"]')?.getAttribute("content");
```

`luna.html` is a deliberately SMALL subset of the DOM — `querySelector`/
`querySelectorAll` (CSS selectors: type, class, id, attribute matches,
`:not()`, `:first-child`, `:nth-child`, descendant/child combinators),
`textContent`/`innerHTML`/`outerHTML`, `children`/`parentElement`,
`getAttribute`/`hasAttribute`/`attributes`, `matches`/`closest`, and
`absoluteURL(attr)` (resolves a `href`/`src` against the page's own URL for
you). This is on purpose: the SAME subset runs identically on three
completely different engines — SwiftSoup inside the app, the browser's own
`DOMParser` inside Safari, and `linkedom` in the offline dev tool — so a
plugin author never has to think about which one is running underneath.
`luna.html.text(html)` strips tags and decodes entities in one call;
`luna.html.jsonScripts(doc)` parses every embedded
`<script type="application/ld+json">`/`"application/json">` block for you.

## 4. `luna.fetch` — reaching the network

```js
const response = await luna.fetch({
  url: "https://example.com/api/post/123",
  headers: { Accept: "application/json" },
  userAgent: "googlebot",     // a named identity, or write your own literal string
});
if (response.ok) {
  const data = JSON.parse(response.text);
}
```

Named `userAgent` identities: `"safari"`, `"googlebot"`, `"googlebot-mobile"`,
`"bingbot"`, `"facebookbot"` — these send the matching literal `User-Agent`
(and, for the Google ones, a matching `X-Forwarded-For`). Anything else you
write is sent as-is.

`cookies` controls whose cookie jar the request uses: `"shared"` (default —
the site's normal, logged-out consent state), `"ephemeral"` (a fresh jar,
nothing remembered), or `"none"`. To reuse the session a `luna.browser` step
just earned (§6), set the `Cookie` header from the result's `cookieHeader`;
any other `cookies` value rejects `bad-argument`. `redirect` is `"follow"`
(default), `"manual"` (stop at the 3xx and read `Location` yourself), or
`"headThenGet"`.

A POST body can be a plain string, `{ base64: "…" }`, `{ form: {...} }`,
`{ json: {...} }`, or `{ multipart: [...] }` (each part is `{ name, filename?,
mime?, text?, base64?, file? }` — `file` takes a `FileHandle` and uploads the
bytes straight off disk, defaulting `filename` and `mime` to the handle's own;
it needs the `files` capability, so it works everywhere except Safari). Luna
sets `Content-Type` for `form`/`json`/`multipart` bodies for you.

## 5. Storage, secrets, and settings

- **`luna.storage`** — a simple key/value store (`get`/`set`/`delete`/`keys`),
  plus named "collections" for querying a small number of documents by up to
  two indexed fields (`luna.storage.collection("name").put(id, doc, { k1,
  k2 })`, then `.find({ k1: "…" })`). Values are JSON, capped at 256 KB each.
  This is App Group storage — every process your plugin runs in shares it.
- **`luna.secrets`** — one Keychain-backed string per key
  (`get`/`set`/`delete`). Only the app can `set`/`delete`; the share/action
  extensions can only `get` what the app already stored. Use this for a
  token, not `luna.storage` — it is never returned to JavaScript in cleartext
  from an extension.
- **`luna.settings`** — reads/writes the values your manifest's `settings`
  schema declares (see "Settings schema" below). `get`/`all` work
  everywhere; `set` is app-only (Settings itself is where a user edits
  values; a plugin usually only reads them).

### Settings schema

A manifest's `settings` array is what draws your plugin's row in
Settings → Plugins → *your plugin*, one field per entry:

```json
"settings": [
  { "key": "apiKey", "type": "password", "label": "API Key", "secret": true,
    "required": true, "help": "From your account's Developer page." },
  { "key": "mode", "type": "choice", "label": "Mode", "default": "auto",
    "options": [{ "id": "auto", "label": "Automatic" }, { "id": "manual", "label": "Manual" }] }
]
```

Each entry is `{ key, type, label, help?, placeholder?, options?, default?,
required?, secret? }`. `key` is ASCII letters, digits and `_` only, and may
never start with `_` — that prefix is reserved for keys Luna itself writes
(`_status`, the dot a destination plugin's own share row shows). `type` is
one of:

| `type` | What the detail screen renders |
| --- | --- |
| `text`, `email`, `url`, `password`, `number` | An inline text field, with the matching keyboard; `password` masks input |
| `toggle` | A switch row |
| `choice` | A row that pushes a picker over `options`, and redraws once one is chosen |
| `pairedDevice` | A row with Pair/Unpair buttons, calling `onAction({ key, action: "pair" \| "unpair" })` |
| `action` | A plain button row calling `onAction({ key })` |
| `info` | Read-only text — no stored value, just `label`/`help` |

Every type shows `help` under its label when you set it. `default` is the
value `luna.settings.get(key)` answers before anything is stored — JSON, so
a string default still needs its own quotes in the manifest
(`"default": "auto"`, not `"default": auto`). `secret: true` masks a stored
value back to `""` in `luna.settings.get`/`.all` — the plaintext only ever
reaches your plugin through `luna.secrets`, never through the settings you
declared here. `required: true` means Luna treats your plugin as
unconfigured — no export row, no auto-send — until this field holds a
value; naming the same key in your `export`'s own `requiresSettings` (§7)
checks it a second time, for a field an export needs but a settings screen
does not otherwise require.

## 6. The browser step, and why a hook re-runs

Some pages need a real browser — a CAPTCHA, a login wall, an age gate. For
that, declare the `browser` capability and call:

```js
async ingest({ url }) {
  if (looksBlocked(await luna.fetch({ url }))) {
    const result = await luna.browser.open({
      url,
      detect: "document.title.includes('Verify') ? 'challenge' : 'done'",
    });
    // result.html is the FINAL page's HTML, after the challenge cleared.
  }
}
```

`detect` is a tiny script Luna evaluates inside the real browser every
350 ms; it must answer one of `"wait"`, `"challenge"`, `"done"`, or
`"error"`. Luna keeps its own loading cover up until `detect` says
`"challenge"` — the moment the person actually needs to do something — then
hides it, shows the real page, and closes it once `detect` says `"done"`.

**What actually happens depends on where your plugin is running.** In the
app itself, Luna can show that browser directly. In the share extension, the
action extension, or Safari, there is no room (and no time) to show a modal
browser — so `luna.browser.open` immediately rejects, the save is marked
"locked," and the user is told to open Luna to finish it. When they do, Luna
re-runs your `ingest` hook from the top with `reason: "resume"` — and this
time, when your plugin calls `luna.browser.open` with the SAME URL, Luna
hands back the stored result instantly, with no browser shown at all. Write
your plugin so this replay is safe: check the browser's result before
re-fetching anything you already have.

## 7. Export plugins

An export plugin has no `produces`/`classify`/`ingest` at all — just an
`export` declaration and hook:

```json
"export": {
  "kinds": ["article"],
  "input": "epub",
  "title": "Send to Kindle",
  "symbol": "book.closed",
  "destination": true,
  "requiresSettings": ["kindleAddress"]
}
```

`input` says what Luna hands your hook: `"url"`, `"epub"`, `"pdf"`, `"docx"`,
`"markdown"`, `"text"`, `"html"`, `"json"`, or `"file"` (not every kind
supports every format — Luna refuses to import a declaration asking for one
it can't build). Your `export` hook receives that content and does something
with it:

```js
async export(input) {
  const address = await luna.settings.get("kindleAddress");
  await luna.mail.send({
    to: [address],
    subject: input.title,
    attachments: [{ file: input.file, name: input.file.name, mime: "application/epub+zip" }],
  });
  return { status: "sent" };
},
```

(This is `kindle.js` — `LunaLibraries/Sources/LunaBundledPlugins/Plugins/kindle.js`
— nearly verbatim.) Return `null` when your plugin delivered the content
itself and there is nothing more to show; return `{ file }`/`{ text }`/
`{ url }` to hand something to the system share sheet instead;
`destination: true` plugins additionally return `{ status: "sent" |
"failed" | "retry", message?, hard?, remoteName? }` — Luna's own send queue,
retry backoff, and per-source auto-send settings apply to a `destination`
plugin exactly as they do to Luna's own Kindle/Xteink code. `retry` is a
DEFERRAL: it costs no failure count and no backoff, which is what makes an
"enqueue until the device wakes" destination workable. `remoteName` is the
name the receiver filed the save under; report it and Luna can ask the
receiver to delete that exact file later (see `luna.exports` in `api.md`).
Add `"dequeueOnRead": true` to the `export` block when your receiver tracks
reading of its own: Luna then drops a queued send whose save was finished in
Luna before the send went out, rather than delivering a book its owner has
already moved past. `requiresSettings`
gates when the share row is even offered — Luna checks those keys have a
value before showing "Send to Kindle" at all.

**A thrown error is retried by default.** Only `throw new
luna.LunaError("hard", "the address is wrong")` or `{ status: "failed", hard:
true }` tells Luna to stop retrying — everything else is treated as "might
work next time."

## 8. Bluetooth and Wi-Fi plugins

`xteink.js` (`LunaLibraries/Sources/LunaBundledPlugins/Plugins/xteink.js`) is
the full worked example — a plugin that talks BLE to a pocket e-reader and
falls back to Wi-Fi for a large file. The shape:

```json
"capabilities": ["bluetooth", "wifi", "fetch", "files", "crypto", "secrets"],
"bluetooth": {
  "services": ["6F9F0A00-9B1D-4D1F-9F53-5B6B8B3D0F10"],
  "pairing": "accessorySetupKit",
  "standingConnect": true,
  "role": "central"
}
```

```js
luna.register({
  async onBluetooth(event) {
    if (event.type !== "connected") return;
    const session = luna.bluetooth.session();   // NOT a second hook argument
    // … talk to the device over session.discover/read/write/subscribe/next …
  },
});
```

**A hook always takes exactly one argument.** `onBluetooth` receives the
`event` object; the live session — if there is one — comes from the
SYNCHRONOUS `luna.bluetooth.session()` call, not from a second parameter.
That session stays valid for the whole `onBluetooth` call, including any
`export` call your own code triggers through
`luna.exports.deliverQueued()` — so a device you've already authenticated in
`onBluetooth` doesn't need re-authenticating inside `export`.

`luna.bluetooth.pair()` shows the system's Bluetooth picker, scoped to the
service UUIDs you declared. Uploads over Wi-Fi are just `luna.fetch` with a
`multipart` body — there is no separate upload API.

## 9. Testing with `tools/plugin-sim`

You do not need Xcode, a simulator, or even a Mac with Luna installed to
iterate on a plugin. `tools/plugin-sim/` is a small Node.js harness that
implements the same `luna.*` API (`undici` for `luna.fetch`, `linkedom` for
`luna.html`, in-memory storage) so you can run your plugin from the command
line and see its answer in under a second.

```sh
cd tools/plugin-sim
npm install
```

Then, from the repo root:

```sh
node tools/plugin-sim/run.mjs docs/plugins/examples/minimal-media.js \
  "https://clipvault.example/clip/abc123" \
  --fixture docs/plugins/examples/fixtures/clipvault
```

prints:

```
plugin: docs.example.minimal-media v1.0.0 (api 1)
classify: {
  "kind": "media",
  "itemId": "abc123"
}
ingest: {
  "kind": "media",
  "title": "A short clip",
  "itemId": "abc123",
  "assets": [
    {
      "url": "https://cdn.clipvault.example/videos/abc123.mp4",
      "type": "video"
    }
  ]
}
```

`--fixture <dir>` answers every `luna.fetch` call from a file in that
directory instead of the real network — save a page once (`curl` it into the
directory under a name matching either its URL's last path segment or its
full host+path with `/`/`?`/`&`/`=` turned into `_`), then iterate offline.
Drop `--fixture` to hit the real network instead. Add `--hook classify` or
`--hook ingest` to run just one hook.

`run.mjs` only exercises `classify` and `ingest` — it never calls `export`,
`onBluetooth`, `onAction`, or `onSettingsChanged`. To check an export
plugin's logic before importing it into Luna, write a short standalone
script against `tools/plugin-sim/bridge.mjs`'s `createBridge`, the way
`export-webhook.js` was verified for this guide:

```js
import { createBridge } from "./tools/plugin-sim/bridge.mjs";
const luna = createBridge({
  pluginId: "docs.example.export-webhook", capabilities: ["fetch", "settings"],
  fetchImpl: async (url, opts) => { /* record opts.body, answer { ok: true, … } */ },
});
await luna.settings.set("webhookUrl", "https://hooks.example.com/receive");
const hooks = new Function("luna", source + "\nreturn luna.__registeredHooks;")(luna);
const result = await hooks.export({ kind: "article", format: "markdown", text: "…", /* … */ });
```

Running that against `docs/plugins/examples/export-webhook.js` with
`webhookUrl` set to `"https://hooks.example.com/receive"` and a fake
`fetchImpl` produces `export result: null` and a captured request of
`POST https://hooks.example.com/receive` with the article's Markdown as the
body — confirming the plugin does exactly what its description says.

Also run the `luna.html` parity check whenever you touch selector-heavy code:

```sh
node tools/plugin-sim/spec.mjs
```

This runs the same 60-case specification
(`LunaTests/Fixtures/Plugins/html-subset.spec.js`) that Luna's own test
suite runs against its two OTHER `luna.html` backings (SwiftSoup in the app,
`DOMParser` in Safari) — if your plugin depends on `luna.html` behavior this
spec doesn't cover, it may behave differently inside the real app than it
did in this harness.

Reference the typings from your editor for autocomplete and type-checking:

```js
/// <reference path="../../tools/plugin-sim/luna-plugin.d.ts" />
```

## 10. Importing into Luna

Open Luna → Settings → Plugins → **Add** → either **Import from Files…**
(pick a `.js` file) or **Paste source** (paste the whole file into a text
box). Luna parses the header, shows a consent screen — your plugin's name,
version, what kinds it produces, its export declaration if any, and every
capability you declared in one plain-language sentence each ("Read pages you
save," "Send email on your behalf," and so on) — and installs only after the
user taps Import. Declining installs nothing.

If you update an already-installed plugin with NEW capabilities it did not
have before, Luna shows consent again for just the added ones. A plugin
sharing an id with a bundled one (say, you ship your own `app.luna.kindle`)
REPLACES the bundled copy while installed, and reverts to it if you delete
your version.

**Luna's consent screen says, plainly: "Luna limits what a plugin can reach,
but cannot stop a plugin that does not finish."** JavaScriptCore has no way
to forcibly interrupt running code. A hook that gets stuck in an infinite
loop keeps the whole plugin runtime tied up until it either finishes or the
process is killed — after three timeouts in a row, Luna stops calling that
plugin at all and shows "Stopped" in Settings, but it cannot reach in and
stop the stuck call itself. Write hooks that always terminate: bound your
loops, and let `luna.fetch`'s own `timeout` option do the waiting for you
rather than polling in a `while` loop with no exit.

## 11. Budgets

| Hook | Time given | What happens past that |
| --- | --- | --- |
| `classify` | 8 seconds (wall clock) | abandoned; treated as "did not claim" |
| `ingest` | 30 seconds, but the clock resets on every `luna.fetch`/`luna.html`/etc. call | abandoned; Luna moves to the next matched plugin |
| `export` | 120 seconds (wall clock) | reported as a soft failure |
| `onBluetooth` | 25 seconds per event | the session is closed |
| `onAction` / `onSettingsChanged` | 10 seconds | reported in Settings |

Three timeouts in a row disable the plugin until the user re-enables it.

## 12. What's different in Safari

Your plugin's `classify`/`ingest` also run inside the Safari extension's
content script — the isolated JavaScript world Safari gives a web
extension, sitting alongside the real page. There, `luna.html` is backed by
the browser's own `DOMParser` (same subset, same behavior — see §3), and an
additional namespace, `luna.page`, gives you the LIVE document
(`luna.page.document()`) without needing to fetch anything. Everything else
that touches the network or storage (`luna.fetch`, `luna.storage`,
`luna.settings.get`) is relayed to the native extension and back — this adds
latency but changes nothing about your code. `luna.secrets`, `luna.files`,
`luna.ui`, `luna.mail`, `luna.notifications`, `luna.bluetooth`, and
`luna.wifi` do not exist in Safari at all; declaring one of those
capabilities is harmless (Safari simply serves the other capabilities you
also declared), but any call on one there rejects.

`luna.browser.open` in Safari always rejects immediately — there's no
"locked save" concept before a save exists. Instead, Luna shows a "Finish in
Luna" link that opens the app and starts the save from scratch, which is
where §6's resume flow takes over.
