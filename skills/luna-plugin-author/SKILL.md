---
name: luna-plugin-author
description: Write, fix, or review a Luna plugin (the JavaScript ingest/export plugin platform for the Luna iOS app). Trigger on "Luna plugin", "write a plugin for <site>", "add a Luna plugin", or a request to fix a `.js` file with a `/* luna-plugin ... */` header.
---

# Writing a Luna plugin

A Luna plugin is one JavaScript file that extends central Luna's ingest
pipeline (URL → Model) or its export pipeline (save → delivered file). Full
docs: `docs/plugins/README.md` (authoring guide), `docs/plugins/api.md`
(reference), `tools/plugin-sim/luna-plugin.d.ts` (typings),
`docs/plugins/examples/*.js` (two complete, tested files),
`claudedocs/plugins.md` (internal design, cited to source). This skill is
the cheat sheet; read those files when this one is not enough.

## The one hard rule

**A hook is called with exactly one JSON argument.** `onBluetooth` receives
`event` alone (read the live link with the SEPARATE, synchronous
`luna.bluetooth.session()`); `onAction` receives `{ key }`, never a bare
string. Nothing in `luna.*` ever hands your code a native object as a second
hook parameter.

## File shape

```js
/* luna-plugin
{ "id": "app.example.mysite", "name": "MySite", "version": "1.0.0", "api": 1,
  "produces": ["media"], "match": { "hosts": ["mysite.com", "*.mysite.com"] },
  "priority": 100, "capabilities": ["fetch", "html"] }
*/
luna.register({
  classify({ url }) { /* return false, or { kind, itemId?, confidence? } */ },
  async ingest({ url, claim, page, reason, context, saveId }) {
    /* return null, or a Model matching `claim.kind` */
  },
});
```

- The file's FIRST non-whitespace characters must be `/*`; the comment's
  first line (trimmed) must be exactly `luna-plugin`; everything after that
  to the closing `*/` is one JSON object, parsed WITHOUT running any code.
- The body calls `luna.register(hooks)` exactly once, at top level.
- File size ≤ 1024 KB (Safari's message channel caps a served source at
  1.5 MB).

## Manifest fields (`PluginManifestParser` enforces these exactly)

| Field | Required | Rule |
| --- | --- | --- |
| `id` | yes | `[a-z0-9.-]`, ≤ 100 chars, no leading/trailing `.`, no `..` — this is also a directory name; NEVER change it across versions |
| `name` | yes | ≤ 40 chars |
| `version` | yes | `M.m.p` |
| `api` | yes | must be `1` |
| `description` | no | ≤ 200 chars |
| `produces` | if ingest | non-empty subset of `"article"`, `"media"`, `"product"` |
| `match` | if ingest | `{ hosts: string[] }` (exact or `*.` suffix) and/or `{ any: true }`; empty `hosts` with no `any` refuses import |
| `priority` | no | integer, default 0; bundled plugins ship at 100 |
| `capabilities` | no | list of `PluginCapabilityName` — unknown name refuses import |
| `export` | no | `{ kinds, input, title, symbol?, destination?, requiresSettings?, inputOptions? }` — see below |
| `settings` | no | `SettingField[]` — key `[A-Za-z0-9_]`, **cannot start with `_`** (reserved) |
| `bluetooth` | no | needs the `bluetooth` capability declared too, or import refuses |
| `background` | no | boolean, default false; shown on consent |

`capabilities` values: `fetch html page storage secrets files crypto
browser downloads settings ui mail notifications bluetooth wifi exports`.
Declaring one your plugin never uses is harmless but shown on the consent
screen — only declare what you call.

## Hook contracts

```ts
classify(input: { url: string; page?: PageSnapshot; context: "app"|"share"|"action"|"safari" })
  : false | { kind: "article"|"media"|"product"; itemId?: string; confidence?: number }
  | Promise<...>;
// 8s wall budget. May call ONLY luna.fetch/luna.html — nothing else is
// available yet. First claim (in priority order) wins; false/error/timeout
// falls through to the next matched plugin, then Luna's own classifier.

ingest(input: { url; claim: {kind,itemId?}; page?; reason: "save"|"resume"|"refresh"|"reresolve"|"rescue";
                context; saveId? }): Promise<Model | null>;
// 30s IDLE budget (every luna.* call resets it). Return null to decline
// AFTER reading the page — the walk continues with the next plugin, never
// fails the save. A thrown error or timeout does the same.

export(input: { kind; saveId: string; url: string; title: string; format: ExportInputFormat;
                file?: FileHandle; text?: string; json?: unknown; auto: boolean;
                source?: string; queuedRemaining?: number }): Promise<ExportResult>;
// 120s wall budget. ExportResult = null | {file,name?,mime?} | {text,name?,mime?}
// | {url} | {status:"sent"|"failed"|"retry", message?, hard?}.
// throw new luna.LunaError("hard", "…") is the ONLY way a thrown error
// becomes terminal (stops retries) for a destination — everything else is
// "might work next time."

onBluetooth(event: BluetoothEvent): Promise<void>;
// event: {type:"connected"|"disconnected"|"paired"|"unpaired"|"stateChanged", device?, restored?, error?, state?}
// Read the live link with luna.bluetooth.session() — synchronous, valid for
// the whole call including a nested luna.exports.deliverQueued(). 25s budget.

onSettingsChanged(changes: Record<string, unknown>): Promise<void>;   // 10s budget
onAction(input: { key: string }): Promise<void>;                       // 10s budget; fired by a "action"-type setting field
```

## Model shapes (returned from `ingest`)

```ts
// media — assets are what Luna's OWN download engine fetches; you never download anything.
{ kind: "media", title?, author?, thumbnailURL?, platform?, itemId?, expiresAt?,
  assets: [{ url, type: "video"|"image"|"gif"|"audio", audioURL?, dashManifestURL?,
             thumbnailURL?, estimatedBytes?, headers?, timeRange?, quality? }] }  // 1–50 assets

// article — html is a cleaned FRAGMENT; Luna's reader renders it near verbatim (no readability pass).
{ kind: "article", title, author?, publishedAt?, html, baseURL?, leadImageURL?, excerpt?, language?,
  document?: { url, type: "pdf"|"epub"|"docx"|"rtf"|"html"|"md"|"txt", headers? } }

// product — price.amount is a decimal STRING, never a float.
{ kind: "product", name, price: {amount, currency}, imageURL?, brand?, productId?,
  identifiers?: {gtin?,mpn?,sku?,brand?}, sellers?: [{url, name?, price?}] }   // ≤ 20 sellers
```

Caps: title/name ≤ 300, most strings ≤ 200, excerpt ≤ 1000, a URL string ≤
4096, `html` ≤ 4 MB. A relative URL is resolved against the page's URL for
you — only an absolute non-http(s) URL is refused. Asset/document `headers`
are limited to `user-agent, referer, cookie, accept, accept-language,
origin, range`.

## `luna.*` cheat sheet

```ts
luna.parseURL(url, base?) → {href,protocol,host,hostname,port,pathname,search,hash,searchParams}
luna.log(message, data?); luna.bytes.{fromBase64,toBase64,utf8Encode,utf8Decode};
luna.env.{context,api,pluginId,version,locale}; class luna.LunaError { code; message }

luna.fetch(req: string | {url, method?, headers?, userAgent?, body?, cookies?, redirect?,
  maxBytes?, timeout?, as?}) → Promise<{ok,status,url,redirected,headers,text?,base64?,file?,truncated,bytes}>
  // userAgent names: "safari" "googlebot" "googlebot-mobile" "bingbot" "facebookbot", or a literal string.
  // body: string | {base64} | {form} | {json} | {multipart: [{name,filename?,mime?,text?,base64?}]}
  //   — NOTE: multipart has NO `file` field; read a FileHandle to base64 first.
  // cookies: "shared"(default) | "ephemeral" | "none" | "browser" (needs a prior luna.browser.open).

luna.html.parse(html, baseURL?) → HTMLDocument   // querySelector(All), textContent, innerHTML/outerHTML,
  //   children, parentElement, tagName, getAttribute/hasAttribute/attributes, matches, closest,
  //   baseURI, absoluteURL(attr). CSS subset: type/class/id/attr(=,^=,$=,*=)/descendant+child/:not/:first-child/:nth-child.
luna.html.text(html) → string;  luna.html.jsonScripts(doc, type?) → unknown[];

luna.page.{document(),url(),title(),html()}                 // Safari only

luna.storage.{get,set,delete,keys}(key/prefix)               // JSON, ≤256KB/value
luna.storage.collection(name).{put(id,doc,{k1?,k2?}), get(id), delete(id),
  find({k1?,k2?},{limit?,offset?}), count({k1?,k2?})}

luna.secrets.{get,set,delete}(key)          // set/delete are APP ONLY
luna.files.{write(name,data,mime?), read(handle,as), size(handle)}
luna.crypto.{sha256, hmacSHA256, randomBytes}   // base64 in/out

luna.browser.open({url, userAgent?, headers?, cookies?, detect, title?, timeout?})
  → {url, html, title, cookieHeader, cookies}   // APP ONLY presents; elsewhere rejects "browser-deferred"

luna.settings.{get(key), set(key,value), all()}   // set is APP ONLY; a secret field reads back as ""
luna.ui.{prompt, confirm, choose, toast, shareSheet}   // APP ONLY
luna.mail.{send(message), isConfigured()}              // APP ONLY
luna.notifications.{post, clear}                        // APP ONLY, never requests permission
luna.bluetooth.{state, pair, pairedDevices, unpair, connect, session()}   // APP ONLY; session() is SYNCHRONOUS
luna.wifi.{join, forget, isReachable}                   // APP ONLY; join rejects code "background" if not foreground
luna.exports.{deliverQueued, queued, markSent}          // APP ONLY, destination plugins
```

An undeclared capability's namespace is `undefined`. A declared one this
process can't serve rejects every call with code `unavailable-here`.

## Constraints that are easy to get wrong

1. **A hook takes ONE argument.** No second parameter, ever.
2. **`classify` may call only `luna.fetch`/`luna.html`.** Every other
   namespace throws if called from `classify`.
3. **`ingest` returning `null` is a decline, not an error** — use it freely
   whenever the page turns out to have nothing for you.
4. **Multipart bodies cannot carry a `FileHandle`.** Base64-encode it first.
5. **A thrown error is NOT terminal by default.** Only `throw new
   luna.LunaError("hard", "…")` (for `export`) or an explicit `hard: true`
   result stops retries. Everything else is retried automatically for a
   `destination` plugin.
6. **Settings keys starting with `_` cannot be declared**, but `luna.settings.set`
   accepts `_status` specifically — write `"live"`/anything-else to drive a
   destination's share-row dot.
7. **A stuck hook cannot be interrupted.** JavaScriptCore has no watchdog
   that can forcibly stop your code — write hooks that always terminate;
   never poll in a bare `while(true)` loop. Three consecutive timeouts
   disable the whole plugin.
8. **`export` never receives a raw MIME message or credentials.** `luna.mail.send`
   builds the MIME for you; you supply `to`/`subject`/`text`/`attachments` only.
9. **Safari has fewer namespaces.** Only `fetch, html, page, storage,
   settings(get-only), crypto, browser(always defers)` exist there;
   `secrets, files, ui, mail, notifications, bluetooth, wifi, exports` do not.

## Checklist before you hand over a plugin

- [ ] Header is the FIRST thing in the file, JSON parses, `id`/`name`/
      `version`/`api` present, `id` is reverse-DNS and will never change.
- [ ] `produces`/`match` present and correct if this is an ingest plugin;
      `classify` returns `false` fast for URLs that aren't yours.
- [ ] `ingest` returns `null` (not throws) when the page has nothing usable.
- [ ] Every `capabilities` entry you declared is actually called somewhere;
      nothing you call is undeclared.
- [ ] `export.input`/`export.kinds` is a pair Luna can actually build (see
      the table in `docs/plugins/README.md` §7) — an unsupported pair
      refuses IMPORT, not just at run time.
- [ ] Ran `node tools/plugin-sim/run.mjs <file> <url> [--fixture dir]` and
      the `classify`/`ingest` output looks right.
- [ ] For an export plugin: verified `export` with a small standalone
      `bridge.mjs` harness (see `docs/plugins/README.md` §9) since `run.mjs`
      never calls `export`.
- [ ] Ran `node tools/plugin-sim/spec.mjs` if the plugin uses `luna.html`
      in any selector-heavy way.
- [ ] No infinite loops; every `await` has a real timeout underneath it.

## Reference files

- `tools/plugin-sim/luna-plugin.d.ts` — the complete, authoritative typings.
- `docs/plugins/examples/minimal-media.js` — smallest complete ingest plugin.
- `docs/plugins/examples/export-webhook.js` — smallest complete export plugin.
- `LunaLibraries/Sources/LunaBundledPlugins/Plugins/reddit.js` — a real,
  two-legged (video+audio) media plugin.
- `LunaLibraries/Sources/LunaBundledPlugins/Plugins/kindle.js` — a real
  destination plugin (mail delivery).
- `LunaLibraries/Sources/LunaBundledPlugins/Plugins/xteink.js` — a real
  Bluetooth+Wi-Fi transport plugin.
- `docs/plugins/README.md` — full authoring guide, worked step by step.
- `docs/plugins/api.md` — full reference, including every error code.
- `claudedocs/plugins.md` — internal design and file-cited implementation
  notes, for when this skill and the docs above are not enough.
