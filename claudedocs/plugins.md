# The Luna plugin platform

Central Luna (`com.hsanabria.luna`) alone runs a JavaScriptCore plugin
runtime that extends two of the three ingest pipeline steps — **ingest**
(URL → Model) and **export** (save → delivered file) — plus Bluetooth/Wi-Fi
transport for one bundled reader integration. Luna Reader, Luna Downloader
and Luna Price Tracker are untouched: they keep their Swift-only paths.

This is the CURRENT reference. `claudedocs/plans/plugin-platform.md` is now
history — it records the design decisions and each wave's departures from
plan; where the two disagree, this document and the code win. Read the plan
once for the "why"; read this for the "what, exactly."

## 1. Architecture

### 1.1 Processes and what runs plugin JS

| Process | Runs plugin JS | classify | ingest | export | onBluetooth | `luna.browser` |
| --- | --- | --- | --- | --- | --- | --- |
| Central Luna app | JavaScriptCore (`LunaPluginRuntime`) | yes | yes | yes | yes | presents the modal |
| `LunaShare` / `LunaAction` (central Luna's) | JavaScriptCore | yes | yes | no | no | stores the request, rejects `browser-deferred` — the save locks |
| `LunaSafari` (central Luna's) native handler | none — relays messages, serves plugin source, runs `PluginFetchService` | – | – | – | – | – |
| Safari content-script world | the page's isolated world (`LunaSafari/Resources/plugin_host.js`) | yes | yes | no | no | rejects `browser-deferred` immediately (no save exists yet) |
| Live Activity widget, App Clips | none | – | – | – | – | – |

The three sibling apps (Reader, Downloader, Price Tracker) and their
extensions link none of the plugin modules and run no plugin code at all.

### 1.2 Generated-plugin recovery

Central Luna supports a provider-neutral authoring loop that requires no API
key or paid LLM account. A user can choose **Create Plugin…** on a failed-save
card, or **Create for Website…** in Settings -> Plugins. Luna builds a bounded,
credential-redacted prompt containing the URL, matching plugins and the ordered
attempt trace. The user copies or shares that text into any chat app, pastes the
returned JavaScript into Luna, and taps **Validate**.

Validation parses the manifest, allows only the conservative `fetch` and `html`
capabilities, activates the draft in a temporary plugin store, and runs its
`classify` and `ingest` hooks against the target URL. It never writes the draft
to the installed-plugin tree, saves database, Keychain or user files. A passing
draft enters the ordinary preview, consent and transactional import path. A
failure produces a deterministic **Copy Fix Prompt** for another blind
copy/paste iteration. JavaScriptCore cannot forcibly terminate arbitrary
top-level JavaScript; activation therefore preflights on a disposable off-main
runtime and abandons a timed-out sandbox rather than reusing it.

Raw **Share Diagnostics…** remains a separate support artifact. It is not the
LLM prompt and may contain more operational context; the workshop always shows
a privacy warning before copying or sharing its redacted prompt.

### 1.3 Module map (`LunaLibraries/`)

| Target | Depends on | Owns |
| --- | --- | --- |
| `LunaPluginKit` | LunaAppConfig, LunaModels, LunaStorage, LunaURLClassification | `PluginManifest`/`PluginManifestParser`, `PluginStore`, `BundledPluginCatalog`, `PluginFetchService`, `PluginKVStore`, `PluginSecretsStore`, `PluginScratchStore`, `PluginDatabase`, `PluginCrawlerIdentity`, `PluginPlatformSeams.swift` (the cross-tier protocol contracts) |
| `LunaPluginRuntime` | LunaPluginKit, SwiftSoup, JavaScriptCore | `PluginRuntime` (the JSC host), `PluginContext` (one JS context per plugin), `PluginExecutionQueue`, the six always-available bridges (fetch/html/storage/secrets/files/crypto), `PluginPromiseBox`, `PluginBridgeSupport` |
| `LunaPluginIngest` | LunaPluginRuntime, LunaIngest, LunaFetch | `PluginIngestStage`, `PluginPlatformComposition` (the one root call), `PluginMediaResolver`, `PluginPriceFetcher`, `PluginProductInfoBuilder`, `PluginBrowserDeferring`, `PluginIngestScope` |
| `LunaPluginExport` | LunaPluginRuntime, LunaSend, LunaEpub, LunaMailAccount | `PluginExportStage`, `PluginExportInputProducer`, `PluginDestination`, `PluginDestinationLegacyIDs`, `PluginExportRowProvider`, mail/notifications/exports bridges |
| `LunaPluginTransport` | LunaPluginRuntime, LunaSend (lock only) | `luna.bluetooth`/`luna.wifi` bridges, `PluginBluetoothCenter`/`Store`, `PluginBluetoothSession`, `PluginPairedDeviceStore`, `CoreBluetoothPluginTransport` |
| `LunaPluginUI` | LunaPluginRuntime, LunaPluginIngest, LunaPluginExport, LunaDesignSystem, LunaSavesUI, LunaArchiveReader | Settings → Plugins, import/consent, the settings-schema renderer, `luna.ui`/`luna.settings`/`luna.browser` bridges, `PluginBrowserViewController`, `PluginUnlockFlow` |
| `LunaBundledPlugins` | none (resources only) | the nine bundled `*.js` plugins under a `Plugins/` resource folder — **not** named `Resources`: a directory literally called `Resources` at a bundle's root makes `codesign` read the bundle as a framework layout and refuse it (`LunaLibraries/Package.swift` comment, `LunaLibraries/Sources/LunaBundledPlugins/LunaBundledPlugins.swift`) |

Model types and the adopter protocols live in `LunaModels/Plugin/` (bottom of
the stack), so a kind module can install a witness without depending on any
plugin-tier target:

- `PluginModel.swift` — `PluginModel`, `MediaModel`/`ArticleModel`/`ProductModel`, `PluginModelCaps`, `PluginModelValidationError`.
- `PluginModelAdopting.swift` — `MediaModelAdopting`/`ArticleModelAdopting`/`ProductModelAdopting`, `PluginModelAdopters` (the registry).
- `PluginModelResolution.swift` — `PluginModel.resolvingRelativeURLs(against:)`.
- `PluginMediaSeams`, `PluginPriceSeam.swift`, `PluginExportSeam.swift`, `PluginResumeSeam.swift` — the four bottom-of-stack witness slots a higher tier that cannot be reached from a kind pack's app target still needs to fill (see §7 below).

### 1.4 The composition rule

`PluginPlatformComposition.install()` (`LunaLibraries/Sources/LunaPluginIngest/PluginPlatformComposition.swift`)
is the single root call for the ingest/runtime half of the platform. It is
called, `@MainActor`, from exactly three roots:

- `Luna/KindWiring+Luna.swift` (the app)
- `LunaShare/ShareEntry+Luna.swift`
- `LunaAction/ActionEntry+Luna.swift`

`PluginExportComposition.install()` (`LunaLibraries/Sources/LunaPluginExport/PluginExportComposition.swift`)
and `PluginTransportComposition.install()` (LunaPluginTransport) are called
only from `KindWiring+Luna.install()`/`appDidLaunch()` — export and
transport never run in the extensions. `KindCompositionRootTests` (`LunaTests`)
asserts both directions: the three central roots call
`PluginPlatformComposition.install`, and no other root writes
`PluginPlatformServices` or `IngestPipeline.pluginStage` directly. The Safari
native handler does not call any composition function; it uses
`LunaPluginKit` (manifest parsing, the store, `PluginFetchService`) straight,
because no JS runs in that process.

`install(processKind:bundledPluginsBundle:additionalBridges:store:keyValueStore:)`
takes the bundled-plugin resource bundle and the higher-tier bridge factories
as parameters rather than reaching for them, because `LunaPluginIngest` sits
below `LunaBundledPlugins`, `LunaPluginUI`, `LunaPluginExport` and
`LunaPluginTransport` in the link graph. `KindWiring+Luna.install()` composes
all four:

```swift
PluginPlatformComposition.install(
    processKind: .app,
    bundledPluginsBundle: LunaBundledPluginsBundle.bundle,
    additionalBridges: {
        PluginUIComposition.bridges(processKind: .app, scheduler: $0)
            + PluginTransportComposition.bridges(processKind: .app, scheduler: $0)
            + PluginExportComposition.bridges(processKind: .app, scheduler: $0)
    })
PluginUIComposition.installAppWitnesses()
PluginExportComposition.install(mediaFiles: …, recipientPicker: …)
```

then, from `appDidLaunch()`:

```swift
PluginTransportComposition.install()
PluginTransportComposition.appDidLaunch()
```

`install` is idempotent: a second call replaces the same witnesses rather
than accumulating a second runtime.

## 2. The plugin file

### 2.1 Shape

One UTF-8 `.js` file, ES2022 (JavaScriptCore on iOS 18 — async/await,
optional chaining, classes, `Promise`, typed arrays, `TextEncoder`), no
`import`/`export`/`require`. Two parts:

1. **The header**: the first non-whitespace token must be a block comment
   whose first line (after trimming) is `luna-plugin`, holding one JSON
   object. `PluginManifestParser.extractHeader` (`LunaLibraries/Sources/LunaPluginKit/PluginManifestParser.swift`)
   reads this WITHOUT evaluating the script, so the consent screen and the
   store never run untrusted code. A missing header, a header that is not
   JSON, or a file over 1024 KB (`PluginManifestParser.maxSourceKB` —
   Safari's native-message channel caps a served source at 1.5 MB, so a
   larger file could never run in every process meant to run it) all fail
   import with a field-and-line error.
2. **The body**, which must call `luna.register(hooks)` exactly once at top
   level. `register` and the declared capability namespaces are the only
   things on `luna` before that call; `PluginContext.seal()` then
   `Object.freeze`s `luna` and `luna.bytes`.

### 2.2 Manifest fields, as the parser enforces them

| Key | Type | Required | Rule the parser actually enforces |
| --- | --- | --- | --- |
| `id` | string | yes | `[a-z0-9.-]`, ≤ 100 chars, no leading/trailing `.`, no `..` (it is a directory name under the App Group) |
| `name` | string \| `LocalizedText` | yes | ≤ 40 chars (every table variant) |
| `version` | string | yes | `M.m.p` (`PluginVersion`) |
| `api` | integer | yes | ≥ 1 and ≤ `PluginAPIVersion.current` (1); higher refuses import |
| `description` | string \| `LocalizedText` | no | ≤ 200 chars (every table variant) |
| `produces` | `("article"\|"media"\|"product")[]` | only if ingest | non-empty; unknown values refuse |
| `match` | `{hosts?: string[], any?: boolean}` | only if ingest | `hosts` lowercased, deduped, no `/`, no `*` except a leading `*.` (a bare `"*"` or `"a.*.com"` refuses import — use `any: true` instead); `any:true` without hosts is fine, but empty `hosts` with no `any` refuses |
| `priority` | integer | no | default 0; any whole number, including negative |
| `capabilities` | string[] | no | must be `PluginCapabilityName` raw values; unknown name refuses import |
| `export` | object | no | `kinds` (non-empty, valid), `input` (valid `ExportInputFormat`, and the kind/format pair must be one `PluginExportInputAvailability` actually supports — an unsupported pair refuses at import, not at run time), `title` (`LocalizedText`, 1–40 chars per variant), `inputOptions.epub.{profile,images}`, `requiresSettings` (list of keys, each of which must be a key some `settings[]` entry declares), `destination` (bool), `symbol` (optional) |
| `settings` | `SettingField[]` | no | keys are ASCII `[A-Za-z0-9_]`, **cannot start with `_`** (reserved), no duplicate keys within one manifest; `label`/`help`/`placeholder`/`options[].label` are `LocalizedText`; `choice` needs a non-empty `options` list with `id`+`label` on every entry; `required`/`secret` must be a real boolean, not `0`/`1`; `default` must be a value `JSONSerialization` can encode |
| `bluetooth` | object | no | requires the `bluetooth` capability to be declared too, or the manifest refuses; `services` non-empty; `pairing` is `"accessorySetupKit"` or `"none"` |
| `background` | boolean | no | default false; shown on consent |

`LocalizedText` (`PluginManifestParser.swift`, `PluginLocalizedText.swift`) is
a plain string, or a `{ "<BCP-47 tag>": "<text>" }` table that MUST include
`"en"` — a table missing it fails import naming the field. The parser
resolves a table to one `String` at IMPORT time, against the device's own
preferred languages (`Locale.preferredLanguages` by default; exact tag, then
that tag's language — `"pt-BR"` falls back to `"pt"` — then `"en"`), so
`PluginManifest`/`PluginSettingField`/`PluginExportSummary` carry a plain
`String` and no downstream code reads a table. `luna.localize` (§5) applies
the identical rule to a table a plugin builds itself at runtime.

`PluginManifest.requiredHooks` (`LunaLibraries/Sources/LunaPluginKit/PluginManifest.swift`)
computes what `register` must provide: `produces` non-empty needs both
`classify` and `ingest`; `export` present needs `export`; `bluetooth` present
needs `onBluetooth`. `PluginRuntime.load` (`LunaLibraries/Sources/LunaPluginRuntime/PluginRuntime.swift`)
fails the load — reported as `loadFailed` in Settings — when a required hook
is missing, when `register` was called zero or more than once, or when the
GRANTED namespace set (read back via `Object.keys(luna)`, `PluginContext
.grantedNamespaces`) disagrees with the DECLARED capability set: a bridge
installing under a stray name, or a capability with no installer serving a
"declared but not honestly present" gap, both fail the load rather than
silently degrading.

## 3. Hooks — real argument and return shapes

A JS hook is called with **exactly one JSON argument**. `PluginContext.call`
(`LunaLibraries/Sources/LunaPluginRuntime/PluginContext.swift`) does
`JSON.parse` on an encoded argument string and invokes the hook with that one
value — there is no way for a second, native argument to ride along. This
one fact shapes `onBluetooth` and `onAction` below.

### 3.1 `classify(input: ClassifyInput): ClassifyResult`

```ts
interface ClassifyInput { url: string; page?: PageSnapshot; context: "app"|"share"|"action"|"safari" }
interface PageSnapshot { url: string; html?: string; title?: string; source: "safari"|"fetch"|"browser" }
type ClassifyResult = false | { kind: "article"|"media"|"product"; itemId?: string; confidence?: number };
```

`PluginClassifyVerdict` (`LunaLibraries/Sources/LunaPluginIngest/PluginHookPayloads.swift`)
decodes `false`/`null`/absent as `.declined`; `true` is a decoder error
(`malformedResult`), not a claim — the contract is `false` or an object
naming `kind`. Budget: 8 s wall (`PluginIngestStage.classifyTimeout`).

### 3.2 `ingest(input: IngestInput): Promise<Model | null>`

```ts
interface IngestInput {
  url: string; claim: { kind; itemId? }; page?: PageSnapshot;
  reason: "save"|"resume"|"refresh"|"reresolve"|"rescue";
  context: "app"|"share"|"action"|"safari"; saveId?: string;
}
```

`null` means "declined after reading the page": the walk continues with the
next matched plugin, then the Swift classifier — this is the "claimed, then
declined" case the prior module platform could not express. Budget: the
pipeline's 30 s **idle** watchdog; every bridge call (`notePluginActivity`)
resets it, so a slow server does not time out a plugin that is still doing
work.

### 3.3 `export(input: ExportInput): Promise<ExportResult>`

```ts
interface ExportInput {
  kind; saveId: string; url: string; title: string; format: ExportInputFormat;
  file?: FileHandle; text?: string; json?: unknown; auto: boolean;
  source?: string; queuedRemaining?: number;
}
type ExportResult =
  | null
  | { file: FileHandle; name?: string; mime?: string }
  | { text: string; name?: string; mime?: string }
  | { url: string }
  | { status: "sent"|"failed"|"retry"; message?: string; hard?: boolean };
```

Budget: 120 s wall (`PluginExportStage.timeout`). A **thrown** `LunaError`
is terminal (stops retrying) only when its `code` is exactly `"hard"` —
`throw new luna.LunaError("hard", "…")`. The runtime drops a rejection's
`details` (`PluginContext.failure(fromRejection:)` keeps only `code` and
`message`), so `hard` in the CODE is the only signal a plugin has;
`PluginExportStage.isTerminal` checks `message.hasPrefix("hard:")`, which is
what a `code: "hard"` rejection actually renders as (`PluginContext.failure`
builds the message as `"\(code): \(message)"`). A `{status:"failed",
hard:true}` RESULT works as documented — this restriction is only about a
thrown error's `details`.

### 3.4 `onBluetooth(event: BluetoothEvent): Promise<void>` — one argument, not two

The plan originally specified `onBluetooth(event, session)`. That is **not
buildable**: a hook takes one JSON argument. The session is instead read
synchronously inside the hook:

```ts
luna.bluetooth.session(): BluetoothSession | null
```

`session()` (`LunaLibraries/Sources/LunaPluginTransport/PluginBluetoothBridge.swift`)
is deliberately synchronous — the answer is "is a link live right now", and
an awaited call could not distinguish "no session" from "not yet" — and it
stays live for the WHOLE `onBluetooth` invocation, including a nested
`export` call the same hook triggers via `luna.exports.deliverQueued()`
(`xteink.js` keeps that link in a module-level variable so `export` inherits
the hello rather than re-authenticating). `BluetoothEvent` itself matches the
plan exactly (`connected`/`disconnected`/`paired`/`unpaired`/`stateChanged`,
`PluginBluetoothCenter.swift`).

### 3.5 `onAction(input: {key, action?}): Promise<void>` — an object, not a bare string

`PluginDetailScreen` (`LunaLibraries/Sources/LunaPluginUI/PluginDetailScreen.swift`)
calls `invoke(.onAction, pluginID:, argument:)` with `{ "key": "…" }`, matching
the one-JSON-argument rule, never a bare string. A `pairedDevice` row adds
`"action": "pair" | "unpair"`: that one row offers both buttons under one key,
so the key alone cannot say which was pressed.

### 3.6 `onSettingsChanged(changes: Record<string, unknown>): Promise<void>`

The argument is the map of CHANGED KEYS — `{ "<key>": <value> }` — which is
what `xteink.js` reads as `changes.enabled`. Budget for
`onAction`/`onSettingsChanged`: 10 s wall.

## 4. Models, as decoded

`PluginModel` (`LunaLibraries/Sources/LunaModels/Plugin/PluginModel.swift`)
is hand-decoded, never `Codable`-derived, so every rejection names the field.
Caps (`PluginModelCaps`): `title`/`price.amount`-string 300 & 200 chars,
`excerpt` 1000, a URL string 4096 chars (long enough for a signed YouTube
stream URL, which carries its whole signature in the query — this cap was
raised from the original prose cap during Wave 2A once a real fixture hit
it), `html` 4 MB, `assets` 1…50, `sellers` ≤ 20. A relative URL is kept as
written by the decoder and resolved later, by `PluginIngestStage`, against
`IngestInput.url` — only an ABSOLUTE URL with a non-http(s) scheme is
refused at decode time. Request headers on a `MediaAssetSpec` or
`ArticleDocumentSpec` are filtered to `PluginModelCaps.allowedHeaderNames`
(`user-agent`, `referer`, `cookie`, `accept`, `accept-language`, `origin`,
`range`); any other name is a decode error (`disallowedHeader`).

- **`MediaModel`** → `MediaModelAdopting` (`MediaKindComposition.install()`
  in LunaMediaDownload sets `PluginModelAdopters.media`). A media Model with
  no `itemId` inherits the `claim.itemId` from `classify`
  (`PluginIngestStage.adopt`), so a plugin need not repeat the id it already
  gave. `MediaAsset` gained `requestHeaders`, `quality`, `pluginID` and
  `expiresAt` to carry a plugin's answer into the durable download engine.
- **`ArticleModel`** → `ArticleModelAdopting`, whose witness lives in
  **LunaReaderUI**, not LunaArticleIngest — a `document` spec needs
  `DocumentParser`, which LunaArticleIngest does not link. `document` present
  fetches and imports the file like a shared document; otherwise the
  `html` fragment is adopted directly (`ArticleExtractor.convertTrusted`,
  skipping readability scoring — the plugin already chose the body).
  A third body source, `transcription` (`ArticleTranscriptionSpec`: `url`,
  `type: "audio" | "video"`, `audioURL?`, `headers?`, `expiresAt?`), makes
  `html` optional and is refused beside `document`. The adopter answers
  `.transcription(TranscriptionRequest)` without fetching anything; the
  save parks `.pending` with a `transcriptions` row and the central app's
  runner downloads, transcribes and persists the article later
  (`claudedocs/plans/transcription-plugins.md`). Non-empty `html` beside
  it becomes the lead the transcript follows.
- **`ProductModel`** → `ProductModelAdopting` in LunaPriceIngest, via
  `PluginProductInfoBuilder.make(from:imageURL:)`
  (`LunaLibraries/Sources/LunaPluginIngest/PluginProductInfoBuilder.swift`).
  `sellers` present means the plugin owns comparison for that tracker and the
  Swift seller fan-out is skipped for it (`tracker_stores.plugin_id` is what
  routes this at refresh time, §6).

Every save produced from a plugin Model carries `saves.plugin_id`
(`LunaLibraries/Sources/LunaStorage/SavesSchema.swift`).

## 5. `luna.*` — every namespace, verified against the bridges

Always present, no capability needed: `luna.register`, `luna.parseURL`,
`luna.log`, `luna.bytes`, `luna.env`, `luna.LunaError`, `luna.localize`
(`LunaLibraries/Sources/LunaPluginRuntime/PluginContext.swift`,
`PluginBootstrapScript.swift`). Every other namespace is installed ONLY
when its capability is both declared and served
by an installer in this process — an undeclared one is `undefined`
(`PluginRuntime.load`'s grant/stray check enforces this at load time, not
just at call time). A capability the plugin DID declare that this process
cannot serve is neither missing nor a working stub: it is a Proxy whose
every call rejects `unavailable-here`, so `Object.keys(luna)` still matches
the manifest and a plugin branches on `error.code` rather than catching a
TypeError. `PluginUnavailableNamespace` (`LunaPluginRuntime/PluginCapabilityRegistry.swift`)
and `plugin_host.js`'s `unavailableNamespace` are the same Proxy. `env.languages` is `Locale.preferredLanguages`
(`navigator.languages` in Safari, `config.languages` in `bridge.mjs`), most-
preferred first; `env.locale` is always `env.languages[0]`. `luna.localize`
resolves a `{ "<tag>": "…" }` table a plugin builds at runtime against that
same list, the identical rule the manifest parser applies to `name`/
`settings[].label`/… at import time (§2.2).

| Capability | Namespace | app | share/action | Safari world | Bridge file |
| --- | --- | --- | --- | --- | --- |
| — | `register`,`parseURL`,`log`,`bytes`,`env`,`LunaError`,`localize` | yes | yes | yes | `PluginContext.swift` / `plugin_host.js` |
| `fetch` | `luna.fetch` | yes | yes | relayed (`plugins.fetch`; no multipart `file` part, which needs `files`) | `PluginFetchBridge.swift` |
| `html` | `luna.html` | SwiftSoup | SwiftSoup | DOMParser | `PluginHTMLBridge.swift` / `plugin_host.js` |
| `page` | `luna.page` | — | — | live DOM | `plugin_host.js` only |
| `storage` | `luna.storage` | yes | yes | relayed | `PluginStorageBridge.swift` |
| `secrets` | `luna.secrets` | get/set/delete | get only (`set`/`delete` reject `unavailable-here`) | — | `PluginSecretsBridge.swift` |
| `files` | `luna.files` | yes | yes | — | `PluginFilesBridge.swift` |
| `crypto` | `luna.crypto` | CryptoKit | CryptoKit | SubtleCrypto | `PluginCryptoBridge.swift` / `plugin_host.js` |
| `browser` | `luna.browser` | presents the modal | stores + rejects `browser-deferred` | rejects `browser-deferred` immediately | `PluginBrowserBridge.swift` (LunaPluginUI) / `plugin_host.js` |
| `downloads` | `luna.downloads` | yes | yes | — (no relay) | `PluginDownloadsBridge.swift` |
| `settings` | `luna.settings` | get/set/all | get/all (`set` rejects `unavailable-here`) | `get` relayed, the manifest default included (`set`/`all` reject `unavailable-here`) | `PluginSettingsBridge.swift` |
| `ui` | `luna.ui` | yes | — (`unavailable-here`) | — | `PluginUIBridge.swift` |
| `mail` | `luna.mail` | yes | — | — | `PluginMailBridge.swift` |
| `notifications` | `luna.notifications` | yes | — | — | `PluginNotificationsBridge.swift` |
| `bluetooth` | `luna.bluetooth` | yes | — | — | `PluginBluetoothBridge.swift` |
| `wifi` | `luna.wifi` | yes | — | — | `PluginWiFiBridge.swift` |
| `exports` | `luna.exports` | yes | — | — | `PluginExportsBridge.swift` |

`luna.downloads` (`PluginDownloadsBridge.swift`) is a read-only view of the
engine's own live media download jobs, straight off `SavesStore`
(`LunaStorage`) rather than `LiveMediaDownloadManager` — it needs nothing the
share/action extensions lack, so it installs the same way in app, share and
action. `luna.downloads.jobs(): Promise<DownloadJob[]>` lists every job;
`luna.downloads.job(saveId): Promise<DownloadJob|null>` resolves the save's
URL and answers the newest job for it, or `null` when there is none — a
non-UUID `saveId` rejects `bad-argument`. `DownloadJob.phase` is
`LiveMediaDownloadJob.Phase`'s own raw values verbatim
(`resolving|downloading|waiting|suspended|saving|finished|failed`) — not the
plan's `queued`/`deferredUntilWiFi` names (§15). `saveId` on a job is looked
up from the job's own source URL, so it reads `null` once the save that made
the download is gone. Not relayed in Safari: `plugin_host.js` has no native
message for it.

`luna.exports` is `deliverQueued()`, `queued()`, `markSent(saveId)`,
`pendingDeletes()`, `markRemoteDeleted(saveId)` and `markReadOnDevice(saveId)`.
The last three are the read-state surface a destination whose receiver tracks
reading needs: `pendingDeletes` lists the deliveries whose save was finished in
Luna and whose remote name Luna recorded, and `markReadOnDevice` makes the two
store writes `XteinkBLECentral.handleReadIDs` makes, in that order
(`markRemoteDeliveryReadOnDevice` then `markFinishedReading`) — the order is
what stops a redundant remote delete for a book the receiver filed away
itself.

### 5.1 `luna.fetch` — `PluginFetchService` (`LunaLibraries/Sources/LunaPluginKit/PluginFetchService.swift`)

Matches the plan's `FetchRequest`/`FetchResponse` shapes, with one
deliberate departure: the cookie policy is `"shared"|"ephemeral"|"none"`
and there is no `"browser"`. `redirect: "follow"|"manual"|"headThenGet"`,
`as: "text"|"base64"|"file"`, and body shapes
`string | {base64} | {form} | {json} | {multipart}`. Three things worth
knowing:

- **`userAgent` names**: `PluginCrawlerIdentity` (`LunaLibraries/Sources/LunaPluginKit/PluginCrawlerIdentity.swift`)
  only recognizes `"safari"`, `"googlebot"`, `"googlebot-mobile"`,
  `"bingbot"`, `"facebookbot"` — a copy of `CrawlerAgent`'s strings, pinned
  against it by `PluginCrawlerIdentityParityTests`. Anything else is sent
  verbatim as the literal `User-Agent` header.
- **A `multipart` part may carry a `FileHandle`.** `PluginFetchRequestDecoder
  .encodeMultipart` resolves a part's `file` through the scratch store and
  appends the bytes, defaulting `filename` and `mime` to the handle's own.
  It needs the `files` capability, so it serves the app and the
  share/action extensions and never Safari (`plugin_host.js` has no `files`
  bridge to resolve a handle with, and the appex answers
  `unavailable-here` for such a part). A handle whose generation was reaped
  fails the whole fetch with `not-found`, and one over
  `PluginFilesBridge.maxFileBytes` with `too-large`, both BEFORE the request
  leaves. `xteink.js`'s Wi-Fi upload leg sends the EPUB this way; only its
  BLE leg still reads the bytes into JavaScript.
- **There is no `cookies: "browser"`.** A plugin that wants the session the
  browser modal earned reads `cookieHeader` off the `luna.browser.open`
  result and sets the header itself. The policy used to be declared and was
  served by nothing in any process; a decoded `"browser"` (or any other
  unknown value) now rejects `bad-argument`.

### 5.2 `luna.html` — the subset

`PluginHTMLBridge` (SwiftSoup), `plugin_host.js` (DOMParser) and the node
harness (`tools/plugin-sim/bridge.mjs`, `linkedom`) all implement the same
60-case specification, `LunaTests/Fixtures/Plugins/html-subset.spec.js`, run
respectively by `PluginHTMLSubsetTests`, `PluginHTMLParityTests` and
`tools/plugin-sim/spec.mjs`. `textContent`/`luna.html.text` deliberately
SKIP `<script>`/`<style>` subtrees on all three backings — matching
SwiftSoup's `Element.text()` rather than the DOM's own `textContent`, which
is why the file is the specification rather than "whatever SwiftSoup does."

### 5.3 `luna.browser` and the lock flow — §7

### 5.4 `luna.settings`

The Safari relay answers what the app's bridge answers: the stored value, or
the manifest field's own `default` for a key nobody has touched, or `null` for
a key the schema does not declare (`SafariPluginMessages+Luna.pluginSettingsGet`).
`set` and `all` reject `unavailable-here` there — a page must not change what
the user sees in Settings, and reading the whole schema has no relay.

`PluginSettingsBridge.value` masks a `secret` field's stored value back to
`""` once set (never the plaintext — that only ever reaches the network
through `luna.secrets`). `set` accepts a key starting with `_` even though a
manifest can never DECLARE one (the parser refuses `settings[].key` starting
with `_`) — that is deliberate: `_status` is the one reserved key a
destination plugin writes to drive its share row's dot
(`PluginReservedSettingKeys.status`, `LunaLibraries/Sources/LunaPluginExport/PluginExportRowProvider.swift`).

**A landed bug worth knowing if you read `PluginKVStore`:** `isConfigured`
originally looked for a value under `settings.<key>`, but both real writers
— `luna.settings.set` and the Settings screen's `PluginDetailScreen` — write
the BARE key through `PluginSettingsStoring.setValueJSON`. This was fixed in
one place, `PluginKVStore.isConfigured` (`LunaLibraries/Sources/LunaPluginKit/PluginKVStore.swift`),
which now reads the bare key to match the writers; there is no `settings.`
prefix anywhere in the shipped code. If you see the prefix mentioned in an
old commit message or the plan's landed notes, it describes a bug already
fixed here.

### 5.5 `luna.bluetooth` / `luna.wifi`

See §3.4 for `session()`. `luna.wifi.join` rejects with code `"background"`
when the app is not foreground (iOS applies a hotspot configuration only
then) — `xteink.js` catches exactly that code to post a notification instead
of failing outright.

## 6. Ingest walk — order, decline, floor, budgets

`PluginIngestStage.run` (`LunaLibraries/Sources/LunaPluginIngest/PluginIngestStage.swift`)
is inserted into `IngestPipeline.runUnbounded` **after unwrap, before
`Classifier.classify`**, through `IngestPipeline.pluginStage: PluginIngestStaging?`
(nil in the three sibling apps).

1. `invoker.matchedPlugins(forHost:)` — the host pre-filter. No match →
   `.passed` (Swift classifier runs). Plugins are pre-sorted at load time:
   host-matched before `any:true`, then `priority` descending, then `id`
   (`PluginRuntime.sortLoaded`) — an `any` plugin runs after every
   host-matched one no matter its own priority.
2. For each matched plugin, `classify`. A `false`/decode failure/timeout
   moves to the next plugin. A claim whose `kind` is not in the plugin's own
   `produces` is treated as a failure to claim (logged, not honored).
3. First claim's `ingest` runs with `reason: "save"` (or `"resume"` when
   `PluginBrowserDeferral.witness.hasCompletedResult(saveID:)` is true for
   this save — the resume case after a browser step, §7).
   - `null` → continue the walk with the NEXT matched plugin (closes the old
     "claimed then declined fails the save" gap).
   - A failure whose `PluginInvocationFailure` case is `.browserDeferred` →
     `.locked(pluginID:)` — the ONE failure that stops the walk rather than
     falling through.
   - Any other failure (timeout, exception, malformed result) → logged,
     walk continues. **A broken plugin never fails a save the Swift floor
     could still make.**
4. A returned Model is validated against `produces`, resolved for relative
   URLs against the save's own URL, and handed to its kind's adopter
   (`PluginModelAdopters`). No adopter installed in this process (impossible
   in central Luna, since all three kind packs install one; theoretically
   possible if a kind pack were ever removed) → walk continues.
5. Every matched plugin passing → `.passed`, and the Swift `Classifier` is
   the floor.

Every step writes a `SaveDiagnostics` line under the `"plugin"` category, so
a save's exported diagnostics trace shows exactly which plugins were asked
and what each answered — this is the primary debugging tool for "why did my
plugin not claim this URL."

**Budgets and disable policy** (`PluginIngestStage`, `PluginRuntime`):

| Hook | Budget | On timeout |
| --- | --- | --- |
| `classify` | 8 s wall | abandoned; plugin passes for this URL |
| `ingest` | pipeline's 30 s **idle** watchdog | as classify, walk continues |
| `export` | 120 s wall | destination soft failure (unless `hard`) |
| `onBluetooth` | 25 s wall, inside a background lease | session closed, event recorded |
| `onAction`/`onSettingsChanged` | 10 s wall | reported in Settings |

A budget's clock starts when the hook's body enters the plugin's context,
not when the call is enqueued: one plugin holding the shared serial queue
must not charge a timeout to another that executed nothing. A call still
waiting to start when its budget passes is CANCELLED — no strike, and no
wedge, because it holds nothing.

Three consecutive timeouts of a call that DID run disable a plugin
(`PluginRuntime.timeoutsBeforeDisable`) with status `.stopped` in Settings
and a Re-enable button. Because JavaScriptCore has no interrupt, an
abandoned call's thread may still be running: `PluginExecutionQueue.isWedged`
reports this and every further call to that runtime fails with `.wedged`
until the abandoned call eventually returns. Loading a plugin also runs
JavaScript, so `PluginRuntime.load` hops onto the same queue and refuses a
wedged one rather than blocking the caller. The consent screen states this
plainly (§10) — Luna limits what a plugin can REACH, but cannot stop one
that does not finish.

**Hooks overlap, and the runtime counts them per plugin.** `onBluetooth`
calling `luna.exports.deliverQueued()` runs an `export` inside a live
`onBluetooth`, and `SavesIngestor` spawns one walk per pending row. The
runtime holds every in-flight call of a plugin and a bridge touch reaches
ALL of them, because a bridge callback cannot tell which hook's continuation
is running — two concurrent calls of one plugin therefore keep each other
alive while either is active. `PluginIngestScope` is keyed the same way, so
`luna.browser.open` files its deferred request against the right save; with
several ingests of one plugin in flight the request must name a `saveId`, or
it rejects `bad-argument`.

### 6.1 `PluginMediaResolver` — the media port

`PluginMediaResolver` (`LunaLibraries/Sources/LunaPluginIngest/PluginMediaResolver.swift`)
implements both `SocialMediaResolving` and `MediaReresolving` by running the
SAME classify+ingest walk and reading a `media` Model's assets. Central
Luna's `PluginPlatformComposition.install()` sets it as
`PluginMediaSeams.resolver` and `.reresolver`; `MediaAssetResolution`
(LunaMediaDownload) is what actually decides which resolver
`MediaShellWiring` uses — it reads `PluginMediaSeams.resolver` and falls
back to the Swift `SocialMediaResolver` when nil, so the ONE file
`MediaShellWiring` (shared by central Luna and the Downloader) never names
either answer directly. `PluginPlatformBootTests` pins that neither
`KindWiring+Luna` nor `MediaShellWiring` names a Swift resolver. The
Downloader app and the three sibling Safari appexes keep using the Swift
`SocialMediaResolver` in `LunaMediaResolve` unchanged.

**A cost worth knowing:** because a bundled media plugin's `ingest` runs at
SAVE time (through the walk), saving a YouTube/TikTok/Facebook/etc. link in
central Luna now pays that resolver's network round trips inline, where the
old Swift path decided the KIND from the URL shape alone and resolved the
asset later. A resolver failure still falls through to the Swift classifier
(and then a generic media save), so this is a latency cost, not a
correctness one.

Nine bundled plugins ship in `LunaLibraries/Sources/LunaBundledPlugins/Plugins/`:
`direct-media.js` (`any:true`, priority 90 — a URL that is itself an
image/video/audio file; it runs last among matched plugins regardless of
priority, which is exactly the fallback ordering an `any` plugin wants),
`x.js` (fxtwitter; declines a long-form text post so `XPostIngestProcessor`
keeps it), `instagram.js`, `tiktok.js`, `facebook.js`, `reddit.js` (video +
separate DASH audio leg), `youtube.js`, plus the two export/transport
plugins `kindle.js` and `xteink.js` (§8, §9). None sets `headers` on its
returned assets — `LiveMediaDownloadManager` already sends the
per-platform User-Agent/Referer these CDNs need, keyed off the save's own
URL; `headers` exists in the Model for a CDN the engine's defaults miss.

`MediaAsset` reresolution (`LiveMediaDownloadManager.reresolver: MediaReresolving?`)
fires on a 401/403/410 task failure, a job whose `expires_at` has passed
before start, and once per job older than 6 hours on
`resumeUnfinishedDownloads`; assets are matched by `(kind, quality)` — schema
13's `media_download_jobs.quality` column exists for exactly this, one TEXT
column since a job persists exactly one asset, not a list. A re-resolve is
capped by `mediaAttempts` — the same counter `retryOrFail` bumps for a
transient download failure — so a plugin that keeps answering with a dead URL
falls into the retry ladder (and then fails the job) rather than looping
forever. `MediaReresolving.reresolve`'s `saveID` is the save that owns the
download, looked up from the job's source URL at the moment of the
re-resolve, not the download engine's own job id — it is nil only when that
save has since been deleted, so a plugin can otherwise correlate it with the
`saveId` it saw at save time.

### 6.2 Price refresh

`PluginPriceFetcher` (`LunaLibraries/Sources/LunaPluginIngest/PluginPriceFetcher.swift`)
implements `PluginPriceFetching` (LunaModels), installed as
`PluginPriceSeams.fetcher`. A `tracker_stores` row with a non-null
`plugin_id` routes its refresh through the owning plugin's `ingest` hook
(`reason: "refresh"`), reading only `price`; nil (plugin gone, declined, or
returned no product) falls back to the Swift `PriceRefresher` path.

## 7. The browser lock flow

### 7.1 Storage

`plugin_browser_requests` (schema 12, `LunaLibraries/Sources/LunaStorage/SavesSchema.swift`):
`save_id` (PK, cascades from `saves`), `plugin_id`, `request_json`,
`result_json` (NULL = still locked), `created_at`, `completed_at`.
`PluginBrowserRequestStore` is the typed wrapper.

### 7.2 In an extension or Safari

`luna.browser.open` (`PluginBrowserBridge.open`, LunaPluginUI) checks
`PluginIngestScope.currentSaveID` first — a browser step belongs to a save
being ingested; called outside a save walk (a refresh, a reresolve) it
rejects `unavailable-here` immediately, since there is nowhere to park the
request. In `share`/`action`, it writes the request through the store and
rejects `browser-deferred`; the plugin lets that rejection propagate
(`ingest` treats it as a distinguished failure, not a decline), and
`PluginIngestStage` returns `.locked(pluginID:)`. The save is written with
`state = .needsCaptcha` and `plugin_id` set; the three card presenters
(article/media/product) already check `.needsCaptcha` and route through
`chrome.presentUnlockFlow`, which now consults `PluginBrowserRequestStore
.pending` first (`PluginLockedSaves`, LunaSavesUI — this is how a locked tap
knows to open the plugin modal rather than the archive unlock). In Safari, no
save exists yet: `plugin_host.js`'s `luna.browser.open` always sends
`plugins.browserDeferred` then rejects; the content script's own pill flow
deep-links `<scheme>://save?url=…` to start the save in the app from
scratch, reaching this same lock the first time `ingest` runs there.

### 7.3 In the app

`PluginBrowserViewController` (`LunaLibraries/Sources/LunaPluginUI/PluginBrowserViewController.swift`)
generalizes the archive unlock's cover-until-challenge mechanics onto a
plugin's own `detect` script: an always-live `WKWebView` under an opaque
overlay, a 350 ms poll of `detect`, lifted only on `"challenge"`, closed on
`"done"`, an error state on `"error"`. The stateless pieces
(`ChallengeCoverView`, `DOMProbePoller`/`DOMProbeEvaluating`,
`DeviceSafariUserAgent`) were extracted into `LunaArchiveReader` and are
shared with `ArchiveWebReaderViewController`, which keeps its own stage
machine untouched. On `"done"` it captures `documentElement.outerHTML`, the
final URL, the title and the domain's cookies, then
`PluginBrowserRequestStore.complete(saveID:result:)`.

`luna.browser.open` in the app: if a stored result already answers this
EXACT request (same page — `PluginBrowserRequest.addressesSamePage(as:)`),
it is returned via `takeResult` (single-use) with no modal shown — this is
the resume path. Otherwise the modal is presented and awaited. After it
closes, `PluginUnlockFlow.resumeCompleted()` (called from `appDidLaunch`,
`sceneDidForeground`) re-runs `ingest` with `reason: "resume"` for any save
still holding a completed, undrained result — the save keeps its id, and the
Model that comes back replaces the locked placeholder.

`PluginIngestScope` (LunaPluginIngest) is what carries the save id to the
bridge across the runtime's own serial queue — where the walk's own
task-locals do not reach, since plugin JS calls dispatch onto
`PluginExecutionQueue`.

## 8. Export framework

### 8.1 `PluginExportStage.run` (`LunaLibraries/Sources/LunaPluginExport/PluginExportStage.swift`)

The ONE place a plugin's `export` runs, whether triggered by a share row tap
or by `ArticleSendCoordinator` delivering a queued send. It builds the input
off-main via `PluginExportInputProducer` (images prepared first, same as
`ArticleExportService.writePreparingImages`), invokes the hook, and sinks the
result: `null` shows nothing (the plugin handled everything itself, e.g.
sent mail), `{file}`/`{text}`/`{url}` present the system share sheet,
`{status}` is destination bookkeeping consumed by `PluginDestination`. A
`{status:"sent"}` may carry `remoteName`, the name the receiver filed the save
under, which `PluginDestination` records through
`SavesStore.recordRemoteDelivery`.

### 8.2 Input production (`PluginExportInputProducer`)

| Kind | `url` | `epub` | `pdf` | `docx` | `markdown` | `text` | `html` | `json` | `file` |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| article | yes | EpubBuilder | ArticlePDFBuilder | ArticleDOCXBuilder | ArticleMarkdownBuilder | ArticlePlainTextBuilder | reader source HTML | `ArticleContent` JSON | — |
| media | yes | — | — | — | — | — | — | JSON | the downloaded file, via `PluginExportMediaFileLocating` |
| product | yes | — | — | — | — | — | — | tracker JSON | — |

`inputOptions.epub.profile: "compact"` maps to `EpubBuilder.Profile.xteink`;
`images: false` maps to the TEXT-ONLY profile (not merely "skip downloading
new images" — a book already holding on-disk images would otherwise still
embed them, defeating the request). `PluginDestination.epubBuildProfile`
reports the DECLARED profile regardless. `PluginExportMediaFileLocating` and
`PluginMailRecipientPicking` are the two app-only witnesses only
`KindWiring+Luna` can build (it is the one file that sees both the export
tier and the media module, and the only one with a presenter for the native
recipient picker).

### 8.3 Destinations and the legacy-id seam

`PluginDestination: ArticleDestination` (`LunaLibraries/Sources/LunaPluginExport/PluginDestination.swift`)
wraps one loaded plugin with `export.destination == true`. Its `id` is
**not** the plugin's own id — `PluginDestinationLegacyIDs.destinationID(forPluginID:)`
(`LunaLibraries/Sources/LunaPluginExport/PluginDestinationLegacyIDs.swift`)
maps `app.luna.kindle` → `"kindle"` and `app.luna.xteink` → `"xteink"`, the
exact ids the Swift destinations used. This is load-bearing: `send_states`,
per-source `SourceSendSettings` toggles and sent dates are keyed by
destination id, and a plugin taking over under a NEW id would read as "Luna
forgot every article it ever sent." `PluginExportComposition.installDestinations`
calls `ArticleDestinationRegistry.install(_:replacingBuiltInIDs:)`, and
`ArticleSendCoordinator.destinations` filters its Swift-default
`[KindleDestination(), XteinkDestination()]` by whatever ids the registry
says are replaced, then appends the installed plugin destinations
(`LunaLibraries/Sources/LunaSend/ArticleSendCoordinator.swift`). Central
Luna therefore delivers BOTH Kindle and Xteink under the exact ids Luna
Reader's Swift destinations use — the `app.luna.xteink` mapping was added in
a follow-up commit (`80387935c`, "the Xteink plugin delivers under the
Swift destination's id") after Wave 3B first landed without it; see §12.

`PluginDestination.deliver(item:context:)` runs the export stage and maps its
outcome onto `PluginDestinationError` (`.soft`/`.hard`/`.unsupportedPayload`),
which conforms to `SendHardFailureError`, or onto
`PluginDestinationDeferral` for a `retry` — that one is a `SendDeferralError`,
so an enqueue-only destination costs no failure count and no backoff, exactly
as the Swift Xteink destination does. A share-shaped answer (`file`/`text`/
`url`) to this call is a hard failure: `deliver` only ever runs a queued send,
where nothing presents. The coordinator's retry/backoff, double-save gating
and auto-send-by-source logic are otherwise unchanged; only the delivery step
is a plugin call instead of an EPUB attach.

**A destination auto-sends whatever kinds it declared.** `ArticleDestination`
asks `accepts(_ item:)` before it queues, sends or retries, and
`PluginDestination` answers `export.kinds.contains(item.exportKind)` — so a
media or product destination is queued, auto-sent by capture source, backed off
and retried exactly as an article one is. The default `accepts` is an article,
which is what the two Swift destinations (`KindleDestination`,
`XteinkDestination`) keep: their payload is a book built from reader content.

The readiness report that starts an automatic send is kind-neutral too, and
there is one of it: `SaveReadiness.observer` (LunaModels), which
`ArticleShellWiring.install()` fills with an adapter onto
`ArticleSendCoordinator.saveBecameReady(_:)`. The two apps that link no send
tier leave it nil, where every report is a no-op. Each kind reports at the
moment its save gains the content a destination would deliver:

| Kind | Reported from | The moment |
| --- | --- | --- |
| article | `ArticleIngestHandler` (`persistArticle`, `ingestDocument`), `SavesIngestor`, `IncomingMailImporter` | the row flips `.ready`, which for an article means its reader content is on disk |
| media | `SavedMediaStore.addDownloadedFile` | the downloaded FILE lands. NOT the `saves` row flipping `.ready` — `savePlatformMetadata` does that the moment the post's title and thumbnail arrive, minutes before any bytes, while a media export's input is the file (`PluginExportInputProducer.mediaFile`). A Photos-backed save reports nothing: its bytes are in the photo library, where there is no file handle to hand a plugin |
| product | `ProductTrackerIngestor` (both routes: a new tracker and the existing one a duplicate save merged into) | the tracker is written, which `savePriceTracker` does in the same step as marking the row `.ready` |

A `file` destination's `accepts` carries the same condition the trigger does:
the downloaded file must exist. Without it the lifecycle sweep
(`retryPendingSends`, which reconciles any `.ready` all-saves save into a
queue row) would queue a media save whose bytes have not arrived and spend the
whole retry budget failing to build its input.

**The double-save press stays article-only.** `doubleSaveDestinationIDs()`
reports every configured destination in `.doubleSave` mode regardless of kind,
but the press itself is gated upstream: a platform item's second press is
always `.ignore` (`claudedocs/send-to-kindle.md`). `sendTestDocument` is
article-shaped for the same reason and still throws
`PluginDestinationError.unsupportedPayload` for any plugin destination.

A destination that declares `export.dequeueOnRead: true` joins
`ReadStateSendReconciler`'s set: a save finished in Luna before its send went
out is dropped from that destination's queue rather than delivered.
`SourceSendSettings.appIntentsMode` reads `send.<id>.appIntentsMode` for any
destination other than `kindle`/`xteink` (which keep their own keys), and
`PluginDetailScreen`'s "Auto-send" row opens `AutoSendBySourceScreen` through
`PluginDestinationAutoSendPresenting`, installed by `KindWiring+Luna`.

`ArticleDestination` gained a default-implemented `deliver(item:context:)`
that BUILDS the EPUB itself (reading `ArticleSendContext.savesStore`, added
for exactly this), so every pre-existing conformer stays source-compatible;
the coordinator prefers `deliver` over the older `send(epubData:fileName:title:)`
when a destination implements it.

### 8.4 Share rows

`AppReaderProviders`/`MediaCardFactory`/`ProductCardPresenter` compile into
Reader/Downloader/Price Tracker too, so they cannot name the export tier.
`ReaderShareSheet.pluginRows` (LunaSocialUI, universal) reads
`PluginExportSeams.rows: PluginExportRowProviding?` (LunaModels) — VALUES,
not menu elements — which `PluginExportComposition.install()` fills with
`PluginExportRowProvider` (LunaPluginExport). A destination that
`providesOwnShareRow` (always true for `PluginDestination`) is excluded from
`ArticleSendCoordinator.configuredDestinations()`, so the menu never offers
the same destination twice. A destination's status dot reads the reserved
`_status` setting (§5.4).

### 8.5 `kindle.js` (bundled)

Settings: `kindleAddress` (email, required), `senderNote` (toggle, default
true). Export: `{kinds:["article"], input:"epub", title:"Send to Kindle",
symbol:"book.closed", destination:true, requiresSettings:["kindleAddress"]}`.
Capabilities: `mail`, `settings`. `isConfigured` also requires
`luna.mail.isConfigured()`. `PluginExportComposition.migrateKindleAddress`
seeds the plugin's setting from `KindleSendSettings.kindleAddress` once (and
re-runs whenever the plugin's own value is still empty, which is what
carries an address typed in Luna Reader — where the Swift `KindleSettingsScreen`
still lives — across to central Luna). **Central Luna has no top-level Kindle settings page**, and the
double-save setup step pushes the PLUGIN's detail screen there
(`KindWiring+Luna` replaces `ArticleShellWiring`'s presenter after installing
it) — the Swift screen writes `KindleSendSettings.kindleAddress`, which the
plugin reads only at the next launch's migration. The address lives in
Settings → Plugins → Kindle. Luna Reader is
unaffected. See `claudedocs/send-to-kindle.md`.

## 9. Bluetooth, Wi-Fi and `xteink.js`

`PluginBluetoothCenter` (`LunaLibraries/Sources/LunaPluginTransport/PluginBluetoothCenter.swift`)
owns one `CBCentralManager` per declaring plugin, built LAZILY — `start()`/
`pair()`/`connect()`, never at load — since building one is what raises the
system Bluetooth permission prompt, and a plugin nobody set up must not cost
the user that alert. `PluginBluetoothCenterStore.startAll()` gates this on
every `required` setting being filled and the plugin's own `enabled`
setting, and runs from `KindWiring+Luna.appDidLaunch()`, so a plugin that IS
configured still has its manager alive for state restoration at launch
(TN3115).

`BluetoothServiceLock` (moved to LunaStorage from the Reader-only
`XteinkRendezvousSweepLock`), keyed purely by the CrossPoint service UUID, is
what stops central Luna's plugin bridge and Luna Reader's Swift
`XteinkBLECentral` from sweeping the same rendezvous window concurrently — a
pure function of the UUID, so the two derive the same lock file path without
sharing a constant. A center that cannot take the lock invokes NOTHING: no
hook call, no lease, no answer to the device.

`onBluetooth` events serialize per center: one event's hook settles before
the next event's hook starts, so a `disconnected` cannot run in JavaScript
beside a `connected` sweep and clobber the link a destination plugin keeps
for its nested `export`. Inside a session, queued and in-flight calls settle
(not merely start) before another may run on the same GATT link, or the
reader would reject the interleave as `resume_mismatch`. A `connected` sweep
takes the service lock when its turn comes and closes only the session it
was dispatched for, so a link that drops and comes back mid-hook leaves the
reconnect's session to the sweep that follows it.

`xteink.js` (`LunaLibraries/Sources/LunaBundledPlugins/Plugins/xteink.js`)
is the full worked example: HMAC-SHA256 hello over the pairing secret
(`luna.secrets`), the BLE-frame transfer paced to the reader's checkpoint
stride, the Wi-Fi escalation for a book over 200 KiB (retried once across the
reader's server-bind gap, as the Swift router does), read-state reconciliation
via `luna.exports.markReadOnDevice` looped until the reader stops handing ids
back, and `luna.exports.pendingDeletes()`/`markRemoteDeleted` draining the
reader's remote-delete queue. `XteinkPluginTests`
(`LunaTests/XteinkPluginTests.swift`) pins its wire behavior against the same
protocol Luna Reader's Swift `XteinkSyncProtocol` implements — a fix to one
side that is not mirrored to the other is a fix half the apps get. Full
device-level behavior (rendezvous windows, dequeue-on-read, checkpoint
pacing) is documented in `claudedocs/xteink.md`, which now describes BOTH
implementations.

`Luna/Settings/XteinkSettingsScreen.swift` (the old Swift settings page) is
excluded from the central `Luna` target by a `project.pbxproj` membership
exception (added by the orchestrator's scaffolding commits, not by an
implementation agent) — it no longer compiles into central Luna at all,
closing the "not reached" gap the Wave 3B plan notes originally recorded.

## 10. Settings, storage, secrets, storage layout

### 10.1 Settings schema and screen

`PluginSettingField` types render in `PluginDetailScreen`
(`LunaLibraries/Sources/LunaPluginUI/PluginDetailScreen.swift`):
`text`/`email`/`url`/`password`/`number` as inline editors, `toggle` as a
switch row, `choice` as a picker, `pairedDevice` as a row with Pair/Unpair
driving `onAction({key, action})`, `action` as a plain button row calling
`onAction({key})`, `info` as read-only text. Every type renders its `help`
under the label, and committing a `choice` or a `toggle` redraws the row. Every write goes through `PluginSettingsStoring
.setValueJSON` — the SAME entry point `luna.settings.set` uses — under the
BARE key (no `settings.` prefix anywhere in the store).

### 10.2 Storage layout

```
<AppGroup>/Plugins/
  user/<id>/<version>/plugin.js     installed verbatim
  user/<id>/state.json              { enabled, installedAt, origin, consentedCapabilities }
  state/<bundledId>.json            { enabled }  (absent = enabled)
  scratch/<id>/<generation>/        luna.files, reaped when the plugin's
                                    last in-flight call ends
```

One `PluginScratchStore` serves the process, keyed by (plugin id,
generation). A generation opens when the first holder arrives and its
directory is reaped when the last one goes, so a nested call
(`onBluetooth` → `export`) writes beside the call that started it rather
than into a directory the outer settle would delete. Holders are every
in-flight hook call (`PluginRuntime`) and the export stage, which keeps one
open across the input file, the hook and the share. `PluginRuntime.load`
calls `reapAll(pluginID:)` first, which is what clears a killed process's
leftovers; `PluginStore.delete` removes the same `scratch/<id>` path. An
export's file result is copied into a directory of the SHARE's own, removed
in the share sheet's completion handler, so nothing has to outlive a
generation.

Values (`luna.storage`, `luna.settings`) live in `saves.sqlite`'s
`plugin_kv` and `plugin_collections` tables (§11) — not in the filesystem —
so they are visible to every process that opens the App Group database.

### 10.3 Secrets

`PluginSecretsStore` (Keychain, App Group access group), one item per
`(pluginID, key)`. `get` works everywhere a plugin runs; `set`/`delete` are
app-only (`PluginSecretsBridge.isWritable = processKind == .app`) — an
extension has no business minting a credential the user cannot see the
prompt for.

## 11. Store schema (schema 12 and 13)

Both bumps are in `LunaLibraries/Sources/LunaStorage/SavesSchema.swift`
(current `SavesDatabase.schemaVersion = 13`). No CHECK constraints anywhere
— the three sibling apps share the file and never read these tables but must
not fail on them.

**Schema 12** — owner routing and asset metadata:

```sql
ALTER TABLE saves ADD COLUMN plugin_id TEXT;
ALTER TABLE tracker_stores ADD COLUMN plugin_id TEXT;
ALTER TABLE media_download_jobs ADD COLUMN plugin_id TEXT;
ALTER TABLE media_download_jobs ADD COLUMN request_headers_json TEXT;
ALTER TABLE media_download_jobs ADD COLUMN expires_at REAL;
CREATE TABLE plugin_kv (plugin_id TEXT NOT NULL, key TEXT NOT NULL, json TEXT NOT NULL,
                        updated_at REAL NOT NULL, PRIMARY KEY (plugin_id, key));
CREATE TABLE plugin_collections (plugin_id TEXT NOT NULL, collection TEXT NOT NULL, id TEXT NOT NULL,
                                  k1 TEXT, k2 TEXT, json TEXT NOT NULL, updated_at REAL NOT NULL,
                                  PRIMARY KEY (plugin_id, collection, id));
CREATE INDEX plugin_collections_k1 ON plugin_collections(plugin_id, collection, k1);
CREATE INDEX plugin_collections_k2 ON plugin_collections(plugin_id, collection, k2);
CREATE TABLE plugin_browser_requests (save_id TEXT PRIMARY KEY REFERENCES saves(id) ON DELETE CASCADE,
                                       plugin_id TEXT NOT NULL, request_json TEXT NOT NULL,
                                       result_json TEXT, created_at REAL NOT NULL, completed_at REAL);
CREATE TABLE pending_plugin_models (id TEXT PRIMARY KEY, url TEXT NOT NULL, model_json TEXT NOT NULL,
                                     plugin_id TEXT NOT NULL, created_at REAL NOT NULL,
                                     return_to_source_until REAL);
```

**Schema 13** — adds `media_download_jobs.quality TEXT`, one column (a job
persists exactly one asset, never a list), so `MediaReresolveMatching`
matches a re-resolved asset back to its job by `(kind, quality)` instead of
by kind plus display order alone.

An existing database gets each column via one `ALTER TABLE … ADD COLUMN` per
column (`SavesSchema.pluginColumns`, checked with `hasColumn` first) since
`CREATE TABLE IF NOT EXISTS` does nothing for a table that already exists
without the new columns.

## 12. Safari

### 12.1 Mechanics

Only the CENTRAL `LunaSafari` appex's target links `LunaPluginKit` and
`LunaBundledPlugins` in `Luna.xcodeproj/project.pbxproj` — the other three
Safari appexes do not, even though `SafariWebExtensionHandler` and
`content.js` are the SAME shared source file compiled into all four. The
split is a per-target FILE substitution, not a `#if canImport` compile-time
guard (CLAUDE.md already documents why that check is unreliable per target):
`LunaSafari/SafariPluginMessages+Luna.swift` (the real, `LunaPluginKit`-backed
implementation) and `LunaSafari/SafariPluginMessages+None.swift`
(`handler = nil`) both declare `enum SafariPluginMessages`, and exactly one
is a member of each Safari target via the usual `membershipExceptions`
mechanism.

`content.js`'s `startPillDecision` runs the plugin walk FIRST (§6's ordering
decision) and only falls back to the Swift-parity heuristics when no plugin
claims the page (`buttonContext.supportsPlugins`, true only for the central
host). Per page load: one `plugins.catalog` round trip, then for each host-matched
plugin one `plugins.source` fetch (≤ 1.5 MB, else skipped and logged),
evaluated with `plugin_host.js`'s text concatenated ahead of the plugin's own
source inside one `new Function` body — each plugin gets its own `luna`, its
own grants, its own scope.

The catalog reply carries a STAMP naming the enabled set (each id at its
version, sorted). A page with a cached catalog decides against that cache
immediately rather than waiting on the round trip, and `loadPluginCatalog`
rewrites the cache only when the fresh stamp differs — so an unchanged set
costs no `storage.local` write, and a changed one takes effect on the next
page rather than mid-decision on this one. The handler builds the stamp from
the enabled set it reads for that message, which is also when it REBUILDS the
set it caches for the process: every other `plugins.*` message would otherwise
rescan the store's directory and re-parse every manifest, and one classify
makes twenty of them.

The walk itself matches `PluginIngestStage` step for step. A claim whose
`kind` is not in the plugin's `produces` is refused and logged, so the pill is
never built from a kind the app then rejects at `plugins.queueModel`. An
`ingest` that answers `null` — "claimed, then declined" — does not consume
the URL: the walk carries on with the next matched plugin's `classify`, and
only falls back to the plain `save?url=` hand-off once every one of them has
passed. `classify` and `ingest` both receive a `PageSnapshot`
(§3.1) built from the live DOM and naming `source: "safari"`, so a plugin
standing on the rendered page needs neither the `page` capability nor a
refetch; it is built at most once per URL and never leaves the content-script
world, so the native message ceiling does not apply.

`SafariWebExtensionHandler` dispatches every `plugins.*` message type through
one seam, `SafariPluginMessaging.handle(type:message:context:) -> Bool`:
`plugins.catalog`, `plugins.source`, `plugins.fetch`,
`plugins.storage.{get,set,delete,keys}`, `plugins.collection.{put,get,delete,find,count}`,
`plugins.log`, `plugins.settings.get`, `plugins.browserDeferred`,
`plugins.queueModel`. Native re-checks the plugin's id is installed, enabled
and has the capability declared before serving — the content script is not
trusted to enforce its own grants. `plugins.log` needs no capability and
still needs a PLUGIN: the id names a category in the shared diagnostic log.
A failed grant check answers `capability-not-declared` and nothing else
answers it; a malformed message answers `bad-argument`, so an author
debugging a typo'd key is not told their manifest is wrong.

Every relayed call reaches the plugin as a `LunaError` it can branch on. A
reply carrying an `error` code rejects with that code (a storage row over the
256 KB cap answers `too-large`), an explicit `ok: false` rejects
`bridge-failed`, and a messaging failure rejects `bridge-failed` too — the
one reply where `ok: false` is a real answer is `plugins.fetch`, whose 404 a
plugin still reads the body of. `luna.storage.set(key, undefined)` rejects
`bad-argument` in the content script before it sends, because a native
message drops an undefined field and the write would otherwise land as JSON
null.

A `media` claim plays the existing in-page video overlay and posts
`plugins.queueModel` on Download; an `article`/`product` claim does the same
on the save pill's tap. Both write into `PendingPluginModelStore` (schema
12's `pending_plugin_models`) and deep-link `<scheme>://pluginmodel?ret=safari`.
`KindWiring.drainPendingPluginModels` → `PluginModelDrain.run` (`Luna/`,
universal, no membership exception needed) adopts the queued Model through
`PluginModelAdopters` and reaches `SavesIngestor.applyRescued` — the same
path a same-process save takes, so the app never re-fetches what Safari
already read.

`luna.browser.open` in `plugin_host.js` always sends
`plugins.browserDeferred` and then unconditionally rejects
`browser-deferred` — no save exists yet in Safari, so there is no lock to
enter; the rejection just tells the plugin's `ingest`/`classify` to stop, and
the deep-link handoff (§7.2) starts the save fresh in the app.

### 12.2 Testing the two backings

`LunaTests/PluginHTMLParityTests.swift` drives `plugin_host.js`'s DOMParser
backing inside `SafariJSTestHarness`'s shared WKWebView against
`html-subset.spec.js`; `LunaTests/SafariPluginHostTests.swift` and
`LunaTests/SafariPluginHandlerSourceTests.swift` cover the rest of the
content-script/native-handler contract. `LunaTests/PluginBridgeParityTests.swift`
runs ONE probe script through both backings — the JavaScriptCore bridges via
`PluginJSFixtureRunner`, `plugin_host.js` via `SafariJSTestHarness` — and
asserts they answer the same error codes, storage semantics and settings
values. It runs the JavaScriptCore side as a SHARE process, because Safari's
`luna` is the extension contract rather than the app's. `SafariPluginHandlerSourceTests` is a
SOURCE-TEXT pin, not a behavior test — `NSExtensionContext` has no fake
anywhere in this codebase, matching the existing pattern for this file family.
Per-hook capability restriction (§3.1's "classify may call only
fetch/html") is **not enforced client-side** in Safari — only native
re-checks the declared capability set per message; a malicious plugin's JS
could still try to call an undeclared bridge method locally, it just gets
nothing useful back because native refuses to serve it.

## 13. Composition, testing, staging

### 13.1 The composition-root test

`KindCompositionRootTests` (`LunaTests`) fails the build on: a direct write
to `PluginPlatformServices`/`IngestPipeline.pluginStage` from anywhere but
`PluginPlatformComposition.install`; a root that installs plugin composition
without calling the three required central roots; and a new, unlisted
composition root.

### 13.2 Testing layers

| Layer | What it runs | Files |
| --- | --- | --- |
| Fixture runner | Loads a real `PluginRuntime` on an isolated VM, answers `luna.fetch` from recorded HTML/JSON fixtures, runs `classify`+`ingest`, decodes Models | `LunaTests/PluginJSFixtureRunner.swift`, `LunaTests/MediaPluginHarness.swift`, per-platform `*PluginTests.swift` (Direct, X, Instagram, TikTok, Facebook, Reddit, YouTube, Kindle, Xteink), fixtures under `LunaTests/Fixtures/Plugins/<platform>/` |
| `luna.html` parity | Same 60-case spec across three backings | `LunaTests/PluginHTMLSubsetTests.swift` (SwiftSoup), `LunaTests/PluginHTMLParityTests.swift` (DOMParser via `SafariJSTestHarness`), `tools/plugin-sim/spec.mjs` (linkedom) |
| Runtime/bridge unit tests | Manifest parsing, hook invocation, timeouts/disable, each bridge's argument validation and error codes | `PluginManifestParserTests`, `PluginRuntimeTests`, `PluginConcurrencyTests`, `PluginBridgeRuntimeTests`, `PluginFetchTests`/`PluginFetchParityTests`, `PluginStorageRuntimeTests`, `PluginBluetoothCenterTests`/`PluginBluetoothSessionTests`, `PluginWifiBridgeTests`, `PluginMailBridgeTests`, `PluginExportInputTests`/`PluginExportStageTests` |
| Ingest/export integration | The walk end to end, decline-then-continue, lock/resume, adoption into Outcome | `PluginIngestStageTests`, `PluginIngestPersistenceTests`, `PluginModelAdopterTests`, `PluginModelDecodingTests`, `PluginResumeTests`, `PluginLockedSaveRoutingTests`, `PluginBrowserBridgeTests`, `PluginBrowserViewControllerTests` |
| UI | Settings → Plugins, import/consent, per-plugin detail | `PluginsSettingsScreenTests`, `PluginDetailScreenTests`, `PluginImportCoordinatorTests`, `PluginCapabilityCopyTests` |
| Safari | Handler dispatch, content-script bridge | `SafariPluginHostTests`, `SafariPluginHandlerSourceTests` |
| Schema/composition parity | Store shape and composition-root discipline | `SavesSchemaPluginColumnsTests`, `PluginStoreSchemaParityTests`, `PluginPlatformBootTests`, `KindCompositionRootTests` |

### 13.3 Node dev harness

`node tools/plugin-sim/run.mjs <plugin.js> <url> [--fixture dir] [--hook classify|ingest]`
prints `classify` and `ingest` output against a Node reimplementation of the
bridge (`undici` fetch, `linkedom` for `luna.html`, in-memory storage,
`luna.downloads` fed from `config.downloads`, no
`luna.browser`/`secrets`/`files`/`ui`/`mail`/`notifications`/`bluetooth`/
`wifi`/`exports` — every app-only or WebKit-only capability is
simply absent, matching how an undeclared capability behaves everywhere
else). It is a convenience tool, never a build gate — no timeout, no
three-strikes disable, a hang just hangs. `node tools/plugin-sim/spec.mjs`
is the one command with a pass/fail exit code (the `luna.html` parity spec).
See `tools/plugin-sim/README.md`.

### 13.4 Staging

`Luna/Stage/StageCatalog+Plugins.swift`, central Luna only (via a
`project.pbxproj` membership exception on the three sibling app targets — its
own header comment still describes a runtime `LunaApp.current` gate that was
superseded by that exception and was never actually written into the file's
body; treat the pbxproj as authoritative). Stage ids: `plugins.settings.empty`,
`plugins.settings.list`, `plugins.settings.detail`, `plugins.consent`,
`plugins.import.paste`, `plugins.browser.lock`, `plugins.locked.card` — see
`claudedocs/staging.md` for the general mechanism.

## 14. Known gaps

Collected from every implementation wave's landed notes, so nothing is lost
between the plan document and this one:

- **Per-hook capability restriction is not enforced client-side in Safari.**
  §3.1's "classify may call only `luna.fetch`/`luna.html`" is checked by
  native re-validating the declared capability set on every message, not by
  anything in `plugin_host.js` itself.
- **`sendTestDocument` throws for a plugin destination.** It hands over loose
  EPUB bytes with no save to build an export input from
  (`PluginDestinationError.unsupportedPayload`). Nothing calls it for a
  plugin destination now that the Kindle settings CATEGORY is gone from
  central Luna (test-send lived on that category's own screen).
- **`SafariPluginHandlerSourceTests` is a source-text pin, not a behavior
  test** — there is no `NSExtensionContext` fake in this codebase to drive
  the real dispatch path.

## 15. Where the plan and the code disagree

Everything below is a real, verified departure from `claudedocs/plans/plugin-platform.md`'s
original TypeScript/design text. The plan's own "landed" notes record most of
these; a few were found only by reading the current code and are called out
explicitly.

1. **`onBluetooth(event, session)` is not the real signature.** A hook takes
   exactly one JSON argument (`PluginContext.call`); the session comes from
   the synchronous `luna.bluetooth.session()` instead (§3.4). `tools/plugin-sim/luna-plugin.d.ts`
   had this wrong before this wave's audit — see the fix in §16.
2. **`onAction(key: string)` is not the real signature.** It receives
   `{key: string}` (§3.5) — also wrong in the pre-audit `.d.ts`.
3. **`PluginKVStore.isConfigured`'s prefix bug is already fixed in this
   tree.** The plan's Wave 3B notes describe it as an open problem "3A will
   hit"; by the time 3A landed, the fix (read the bare key) was already the
   only code path — there is no `settings.` prefix left to trip over.
4. **The Xteink plugin DOES now replace the Swift `XteinkDestination` in
   `ArticleDestinationRegistry`.** The plan's Wave 3B "not reached" list says
   `ArticleSendCoordinator` still defaults to Swift Kindle+Xteink and this
   would wait for 3A. `PluginDestinationLegacyIDs.byPluginID` already maps
   `app.luna.xteink` → `"xteink"` as of commit `80387935c` ("the Xteink
   plugin delivers under the Swift destination's id") — the current HEAD of
   this branch. Central Luna's Xteink share row today is the PLUGIN'S row
   (`providesOwnShareRow`), delivering under the Swift destination's
   bookkeeping id.
5. **`Luna/Settings/XteinkSettingsScreen.swift` is excluded from the central
   `Luna` target.** The plan's Wave 3B notes list this as a standing gap ("one
   line for the orchestrator"); `project.pbxproj`'s `membershipExceptions`
   for the `Luna` target already list it, so the file compiles but is
   completely unreferenced dead code in that target, not a settings entry
   point.
6. **`multipart` request bodies cannot carry a `FileHandle`** despite the
   plan's TypeScript showing `file?: FileHandle` on `MultipartPart` (§14).
7. **`luna.downloads`'s `DownloadJob.phase` is the engine's own
   `LiveMediaDownloadJob.Phase` raw values, not the plan's
   `queued`/`deferredUntilWiFi` names** — the plan's phase set was never a
   real state the download engine has; mapping onto engine phases the plugin
   walk can actually observe is more honest than inventing a translation
   table for states that don't exist.
8. **`match.any` plugins run after every host-matched plugin's `ingest`, not
   merely after `classify`.** This matches the plan's intent (§3.2's ordering
   rule) but is worth stating precisely: the ANY-host plugin's own `classify`
   only gets a chance once every host-matched plugin has FAILED TO CLAIM (not
   merely been tried) — confirmed in `PluginRuntime.sortLoaded`'s ordering and
   `PluginIngestStage.run`'s single linear walk over that order.

## 16. This wave's `.d.ts` and example fixes

`tools/plugin-sim/luna-plugin.d.ts` was audited against every bridge file and
had two real mismatches, both now fixed: `PluginHooks.onBluetooth`'s second
`session` parameter was removed (§15.1) and a `Bluetooth.session(): BluetoothSession
| null` synchronous method was added; `PluginHooks.onAction`'s `key: string`
parameter was changed to `input: {key: string}` (§15.2). Everything else in
the file was verified correct against its bridge and left unchanged.

Two new examples ship under `docs/plugins/examples/`:
`minimal-media.js` (the smallest valid media plugin — `direct-media.js`'s
"any URL matching a file extension" shape, trimmed to the bare minimum a
`produces:["media"]` plugin needs) and `export-webhook.js` (an export plugin
that POSTs an article's Markdown to a URL read from a setting, returning
`null` since it delivers itself). Both were run under
`node tools/plugin-sim/run.mjs` against local fixtures; see `docs/plugins/README.md`
for the exact commands and output.
