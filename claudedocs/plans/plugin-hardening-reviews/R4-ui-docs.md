# Review R4 — LunaPluginUI, plugin settings/stage surface, and the developer-facing docs

Read-only review at `main` (HEAD `aff524cc6`). Every claim below was checked against the
named file. Ranked most severe first. Findings already excluded by the brief (plugin copy
not localized, `luna.downloads` has no bridge, multipart has no `file` field) are not
repeated.

---

## 1. `onSettingsChanged` is called with `{key, value}`, not the documented `Record<key, value>` — the only implementation in the tree is dead

**bug** — `LunaLibraries/Sources/LunaPluginUI/PluginDetailScreen.swift:284-293`

`notifySettingsChanged` builds `struct Argument { let key: String; let value: PluginRawJSON }`
and invokes `.onSettingsChanged` with it, so a plugin receives
`{ "key": "enabled", "value": false }`.

The contract everywhere else is a map of changed keys:
- `claudedocs/plugins.md:246` — `onSettingsChanged(changes: Record<string, unknown>)`
- `tools/plugin-sim/luna-plugin.d.ts:154` — same
- `docs/plugins/api.md:95` — same

The consequence is live, not theoretical. `LunaLibraries/Sources/LunaBundledPlugins/Plugins/xteink.js:448-452`:

```js
async onSettingsChanged(changes) {
    if (changes && changes.enabled === false) {
        await luna.settings.set("_status", "off");
    }
},
```

`changes.enabled` is always `undefined` (the object has only `key`/`value`), so switching
"Send to Xteink" off in Settings never dims the share row's status dot. `PluginDetailScreen`
is the ONLY caller of `.onSettingsChanged` in the codebase (verified by grep), so nothing
else compensates.

**Fix:** send `[field.key: value]` as a single-entry dictionary — one `Encodable` wrapper
around `[String: PluginRawJSON]` — matching the three documents and `xteink.js`.

---

## 2. `luna.ui.choose` and `luna.ui.shareSheet` crash on iPad

**bug** — `LunaLibraries/Sources/LunaPluginUI/PluginUIPresenting.swift:107-121` and `:136-151`

`choose` presents a `UIAlertController(preferredStyle: .actionSheet)` and `shareSheet`
presents a `UIActivityViewController`, neither configuring
`popoverPresentationController.sourceView`/`sourceRect`/`barButtonItem`. On iPad both
raise `NSInvalidArgumentException` at present time ("your application has presented a
UIAlertController … Style UIAlertControllerStyleActionSheet … must have a non-nil
sourceView"). All four apps ship `TARGETED_DEVICE_FAMILY = "1,2"` (CLAUDE.md), so this is
a reachable hard crash driven by plugin JS.

`PluginImportCoordinator.begin` (`PluginImportCoordinator.swift:48-49`) gets this right,
which shows the pattern is known in this module.

**Fix:** anchor both to the presenting view controller's `view` with a centred `sourceRect`
(and `permittedArrowDirections = []`), as `PluginImportCoordinator` does.

---

## 3. `luna.ui.shareSheet` silently drops a `FileHandle` and accepts an undocumented `{path}` naming any file on disk

**bug** — `LunaLibraries/Sources/LunaPluginUI/PluginUIBridge.swift:122-138`

```swift
/// The three item shapes §6.12 allows. A `FileHandle` is named by its id,
/// which the files bridge resolves to a path.
private static func shareItems(_ value: JSValue?) -> [PluginShareItem] {
    …
    if let path = object["path"] as? String { return .fileURL(URL(fileURLWithPath: path)) }
```

Two problems, both verifiable against `LunaPluginRuntime/Bridges/PluginFilesBridge.swift:114-121`,
where a handle is `{id, name, size, mime}` and **has no `path`**:

1. The documented item shape — `shareSheet(items: (FileHandle | {url} | {text})[])`
   (`luna-plugin.d.ts:386`, `docs/plugins/api.md:295`) — is not handled: a `FileHandle`
   passed in matches none of the branches (`id` is never read) and is dropped by
   `compactMap`. Sharing a file a plugin just wrote is impossible through the documented API.
2. The branch that *is* implemented takes an arbitrary filesystem path from JavaScript and
   hands it to `UIActivityViewController`. `luna.files` exists precisely so "a plugin can
   hand one back to Luna … but cannot name a file it did not write"
   (`PluginFilesBridge.swift:11-14`); `{path}` re-opens exactly that, letting a plugin put
   any readable file in the app container (`saves.sqlite`, another plugin's scratch) into
   the share sheet.

**Fix:** delete the `path` branch, and resolve a `FileHandle` through
`PluginFilesBridge.descriptor(from:)` + `PluginScratchStore.fileURL(for:)`. The doc comment
already describes that design — the code just never got there.

---

## 4. The detail screen shows a stale value after a `choice` is picked

**bug** — `PluginDetailScreen.swift:274-282, 324-330`

`pushChoice` pushes `PluginChoiceScreen` with a callback that calls `commitValue`.
`commitValue` writes the store and updates the in-memory `values` dictionary but never
calls `tableView.reloadData()`, and `PluginDetailScreen` overrides only `viewDidLoad` — it
has no `viewWillAppear` reload (unlike `PluginsSettingsScreen.swift:53-56`, which does).
Pop back from the picker and the `.value1` detail label still reads the previous option,
and the required-and-empty red marking (`markIfRequiredAndEmpty`) is not re-evaluated
either. `invokeAction` gets this right — it calls `reloadValues()` (`:302`).

**Fix:** call `reloadValues()` at the end of `commitValue`, or add a `viewWillAppear`
reload. (Committing a text field mid-edit would then reload under the keyboard, so
`reloadValues()` inside `commitValue` should be preferred for `choice`/`toggle` only, or
guard on `tableView.isEditing`/first responder.)

---

## 5. The paste-import screen's Import button sits under the keyboard, with no way to dismiss it

**bug** — `PluginPasteImportViewController.swift:57-74`

`viewDidAppear` calls `textView.becomeFirstResponder()`. `importButton` is pinned to
`view.safeAreaLayoutGuide.bottomAnchor` with no keyboard-avoidance constraint, no
`keyboardLayoutGuide`, no `keyboardDismissMode`, no Done accessory and no return-key
dismissal (it is a `UITextView`). The keyboard therefore covers the only Import control
from the moment the screen appears and cannot be dismissed. The only usable control is
Cancel. This is the shipped path behind Settings → Plugins → Add → Paste Source, and the
`plugins.import.paste` stage reproduces it.

**Fix:** constrain `importButton.bottomAnchor` to `view.keyboardLayoutGuide.topAnchor`
(with a safe-area fallback), or move Import to a right bar button item.

---

## 6. `LunaError`'s constructor argument order differs between the three backings

**bug (parity)** — `LunaLibraries/Sources/LunaPluginRuntime/PluginBootstrapScript.swift:27-33`,
`LunaSafari/Resources/plugin_host.js:19-26`, `tools/plugin-sim/bridge.mjs:18-25`

| Backing | signature |
| --- | --- |
| JavaScriptCore (app, share, action) | `constructor(code, message, details)` |
| Safari content script | `constructor(message, code, details)` |
| Node dev harness | `constructor(message, code, details)` |

`docs/plugins/api.md:73` documents `new luna.LunaError(code, message)` — the JSC order. Every
bundled plugin uses that order (`kindle.js:49`, `xteink.js:181`…). So the same source line
produces `code === "hard"` in the app and `code === "the address is wrong"` in Safari and
in the sim. `luna-plugin.d.ts:237-240` declares the class with no constructor, so a plugin
author gets no type error either way.

Today no bundled plugin throws a `LunaError` from a hook that runs in Safari, so nothing is
broken in-tree — but a media plugin (the kind Safari does run) that branches on `error.code`
would behave differently per process, and the harness would mislead its author.

**Fix:** make `plugin_host.js` and `bridge.mjs` take `(code, message, details)`, and add a
case to the html-subset-style parity spec (or a small new one) that pins the order across all
three.

---

## 7. A settings field's `help` text is never shown for any type except `info`

**bug** — `PluginDetailScreen.swift:188-248`

`PluginSettingField.help` is parsed (`PluginManifestParser.swift:438`), typed
(`luna-plugin.d.ts:43`), stored (`PluginPlatformSeams.swift:147`) and authored — `xteink.js`
sets `help` on both `enabled` and `device`, and the shipped example
`docs/plugins/examples/export-webhook.js:22` sets it on `webhookUrl`. `fieldCell` reads it
only in the `.info` branch (`:245`); every other branch renders `field.label` and, for text
fields, `field.placeholder`. So the one explanatory string the schema offers is silently
discarded for the nine field types that are not `info`.

**Fix:** render `help` as the cell's `detailTextLabel` / footer for every field type
(`.subtitle` style, or a section footer per field group).

---

## 8. `StageCatalog+Plugins.swift`'s `#endif` closes before the fixture class, so a WebKit stage fake compiles into Release

**bug** — `Luna/Stage/StageCatalog+Plugins.swift:289-334`

`#if DEBUG` opens at `:10` and `#endif` lands at `:289`, but `StagePluginBrowserPage` — a
`PluginBrowserPageDriving` fake owning a `WKWebView` and a fixture HTML string — is declared
at `:294-334`, *after* it. It compiles unconditionally into the central Luna app. It is
`private` and its only reference (`lockStages`, `:93`) is inside the DEBUG block, so a
release build ships an unreachable class plus its fixture string.

**Fix:** move the `#endif` to the end of the file.

---

## 9. The browser step hands the site's session cookies to plugin JavaScript, and the consent sentence does not say so

**design** — `PluginBrowserPage.swift:90-110`, `PluginBrowserModels.swift:120-159`,
`Localizable.strings:1237`

`WebKitPluginBrowserPage.capture` reads `httpCookieStore.getAllCookies`, filters by the page
host, and returns every matching cookie's `name`/`value`/`domain` plus a ready-made
`cookieHeader` in `PluginBrowserResult.jsObject`. The default jar is `.default()`
(`:64-65`) — the app's persistent, shared jar, so the cookies are the user's real session
for that site, `HttpOnly` and `Secure` included. A plugin that declares `browser` + `fetch`
(the normal pairing) can POST them anywhere.

The only sentence the user consents to is
`"PluginCapability_browser_Luna" = "Open a web page for you to sign in or solve a challenge."`
Nothing there says the plugin receives the resulting login.

Same class of understatement one line down:
`"PluginCapability_wifi_Luna" = "Check your Wi-Fi connection."` — but `luna.wifi.join`
installs a hotspot configuration and *moves the phone onto a network the plugin names*
(`SystemPluginWiFiJoiner.swift`, `api.md:359`).

**Fix:** reword both keys to name the real reach ("…and give the plugin the page and the
cookies you signed in with", "Join a Wi-Fi network it names"). No code change needed.

---

## 10. Safari installs no `unavailable-here` stand-ins, so the documented "always a catchable LunaError" rule is false there

**docs-drift / bug** — `LunaSafari/Resources/plugin_host.js:275-380` vs
`docs/plugins/api.md:39-42` and `docs/plugins/README.md:539-547`

api.md states: "A namespace you DID declare, in a process that can't serve it, exists but
every call on it rejects with code `unavailable-here`." That holds in the JSC processes —
`PluginContext.swift:86-90` installs `PluginUnavailableNamespace` for any declared
capability with no installer. `plugin_host.js` has no equivalent: it builds namespaces only
under `if (declared.html)`, `if (declared.page)`, `if (declared.fetch)`, `if (declared.storage)`,
`if (declared.settings)`, `if (declared.crypto)`, `if (declared.browser)`. A plugin
declaring `ui`/`mail`/`secrets`/`files`/`notifications`/`bluetooth`/`wifi`/`exports` gets
`undefined` in Safari, so a call is a `TypeError`, not a `LunaError` — uncatchable by
`error.code`.

Finer point in the same file: `luna.settings` in Safari (`:359-366`) exposes **only `get`** —
`luna.settings.all()` is `undefined` there, which api.md's availability table (`:31`,
"get only, relayed") does not spell out and its blanket rule contradicts.

**Fix:** either add the stand-in to `plugin_host.js` (preferred — it makes the contract one
sentence again) or correct both docs to say Safari omits the namespace entirely.

---

## 11. README claims `classify` is restricted to `luna.fetch`/`luna.html`; nothing enforces that anywhere

**docs-drift** — `docs/plugins/README.md:97-98`

> "It cannot call anything else — no `luna.storage`, no `luna.ui` — those calls throw at
> this point in the lifecycle."

There is no per-hook capability gate in the codebase. `PluginContext` installs every
declared capability once, at context construction; `PluginRuntime`/`PluginIngestStage` pass
no hook identity to any bridge; the Safari native handler checks only that the plugin
*declares* the capability (`LunaSafari/SafariPluginMessages+Luna.swift:136-137`,
`pluginDeclares(id:capability:)`), never which hook is running.
`claudedocs/plugins.md:917-920` already admits this for Safari; it is equally unenforced in
the app.

**Fix:** soften the README to "should not" / "is not intended to" (with the 8 s budget as the
real reason), or implement the gate in `PluginCapabilityNamespace`.

---

## 12. A bad argument to `luna.browser.open` / `luna.storage.collection` throws a bare `Error` synchronously, not a `LunaError` rejection

**bug / docs-drift** — `PluginBrowserBridge.swift:64-73`, `PluginStorageBridge.swift:105-110`,
`PluginBridgeSupport.swift:88-90`

```swift
public static func raise(_ message: String, in context: JSContext) {
    context.exception = JSValue(newErrorFromMessage: message, in: context)
}
```

Both call sites use `raise` and return `nil` instead of a rejected promise. So
`luna.browser.open({})` throws synchronously with a plain `Error` that has **no `.code`** —
`await luna.browser.open(bad).catch(e => e.code)` gets `undefined`, and a plugin awaiting it
inside a `try` sees a different failure mode than every other bridge produces. api.md:46 and
:56 promise "Every rejection is a `LunaError` … `bad-argument` | almost every bridge".
32 other bridge call sites do reject with `bad-argument` (grep `code: "bad-argument"`).

**Fix:** in both places build the promise first and `box.fail(…, code: "bad-argument")`, as
every sibling bridge does.

---

## 13. Four real error codes are missing from api.md's table, and one is attributed to the wrong call

**docs-drift** — `docs/plugins/api.md:52-72`

Codes the bridges actually emit but the table omits:

| Code | Source |
| --- | --- |
| `not-configured` | `LunaPluginExport/Bridges/PluginMailBridge.swift:260` — `luna.mail.send` with no account connected. api.md documents only `send-failed`, so the documented branch never fires for the most common failure. |
| `join-failed` | `LunaPluginTransport/SystemPluginWiFiJoiner.swift:106` — `luna.wifi.join` |
| `runtime` | `LunaPluginRuntime/Bridges/PluginCryptoBridge.swift:71` — `luna.crypto.randomBytes` |
| `capability-not-declared` | `LunaSafari/SafariPluginMessages+Luna.swift:184,239,…` — every relayed Safari message |

And `too-large` is attributed only to `collection().put`; `luna.storage.set` also rejects
with it (`PluginStorageBridge.swift:70-74`).

**Fix:** add the four rows and widen the `too-large` row.

---

## 14. `bridge.mjs`'s own header comment claims a capability set it does not implement

**docs-drift / comment standard** — `tools/plugin-sim/bridge.mjs:10-12`

> "Every capability a real plugin declares is available here except `browser`"

The harness installs `html`, `crypto`, `storage`, `settings`, `fetch`, and a rejecting
`browser` (`:284-317`). Absent entirely: `files`, `secrets`, `page`, `ui`, `mail`,
`notifications`, `bluetooth`, `wifi`, `exports`, `downloads`. `claudedocs/plugins.md:851-856`
lists the absences correctly, so it is this file's comment that is wrong — and it is the one
a plugin author reads.

**Fix:** replace the sentence with the real list (or point at `claudedocs/plugins.md` §13.3).

---

## 15. The Node harness diverges from the real bridges in ways that make a broken plugin pass

**docs-drift** — `tools/plugin-sim/bridge.mjs:196-230, 293-300`

Three divergences that turn a real failure into a green sim run:

1. **`luna.fetch` ignores `{multipart}`** — `fetchFactory` handles `string`, `{base64}`,
   `{json}`, `{form}` and nothing else, so a multipart POST silently sends **no body**. The
   real encoder (`PluginFetchRequestDecoder.encodeMultipart`) builds one. `xteink.js`'s
   Wi-Fi upload leg is exactly this shape.
2. **`as: "file"` is ignored** — the harness always returns `text`/`base64`
   (`:222-224`), so `response.file` is never populated and a plugin branching on it takes the
   wrong path in the sim.
3. **`luna.settings` has no schema** — `set` accepts any key (`:296`), while the real bridge
   rejects an undeclared, non-`_` key with `bad-argument`
   (`PluginSettingsBridge.swift:67-71`); `get` returns `undefined` for an unset field instead
   of the manifest's `default` (`PluginSettingsBridge.swift:118`), and never masks a secret
   to `""` (`:119`). A plugin that relies on a default works in the sim and reads `undefined`
   in the app.

**Fix:** implement multipart and `as:"file"` in `fetchFactory`, and hand `createBridge` the
manifest's `settings` array so `get`/`set` apply defaults, secret masking and the key check.

---

## 16. `PluginPlatformBootTests.tearDown` reinstalls the platform without the UI/export/transport bridges, degrading every later suite

**test-gap** — `LunaTests/PluginPlatformBootTests.swift:71-81`

```swift
PluginPlatformComposition.install(
    processKind: .app, bundledPluginsBundle: LunaBundledPluginsBundle.bundle)
```

`additionalBridges:` defaults to `{ _ in [] }`
(`PluginPlatformComposition.swift:49`), but the app's real root composes three groups —
`PluginUIComposition.bridges + PluginTransportComposition.bridges + PluginExportComposition.bridges`
(`Luna/KindWiring+Luna.swift:62-66`). So after this suite runs, the host process's platform
has no `luna.ui`, `luna.settings`, `luna.browser`, `luna.bluetooth`, `luna.wifi`,
`luna.mail`, `luna.notifications` or `luna.exports` — every one of them becomes the
`unavailable-here` stand-in for the remainder of the run. It also never restores
`PluginUIComposition.installAppWitnesses()`. Any later suite reading the shipped platform is
silently running a degraded one, and the result depends on suite ordering.

**Fix:** repeat the exact `additionalBridges:` closure and `installAppWitnesses()` in
`tearDown`, or extract the app's composition into one function both the root and the test call.

---

## 17. Nothing pins that export/transport composition stays out of the extensions

**test-gap** — `LunaTests/KindCompositionRootTests.swift:154-181`

`testOnlyTheCentralRootsInstallThePluginPlatform` greps only for
`PluginPlatformComposition.install(`. `claudedocs/plugins.md:60-63` states that
`PluginExportComposition.install()` and `PluginTransportComposition.install()` "are called
only from `KindWiring+Luna.install()`/`appDidLaunch()` — export and transport never run in
the extensions", and that is true today (verified by grep across the three roots) — but
adding either line to `ShareEntry+Luna.swift` would compile and pass the suite. Likewise
nothing pins `PluginUIComposition.installAppWitnesses()` to the app root.

**Fix:** extend the existing source-read test with two more expected-caller sets, in the
same shape as `pluginRoots`.

---

## 18. `PluginUIBridge` has no test at all, and `PluginSettingsBridge`'s three real rules are untested

**test-gap** — grep over `LunaTests/` finds `PluginUIBridge`/`luna.ui` in **no** test file;
`PluginSettingsBridge` appears only as a registration line in `KindlePluginTests.swift:55`
and `XteinkPluginTests.swift:61`.

Untested behaviour that the brief specifically asks about, all of it branchy:
- `luna.ui.*` rejecting `unavailable-here` in `.share`/`.action` (`PluginUIBridge.swift:108-111`)
- `shareItems` decoding (see finding 3 — a test would have caught the dropped `FileHandle`)
- `luna.settings.set` refusing an undeclared key, and accepting a `_`-prefixed one
  (`PluginSettingsBridge.swift:67-71`) — the reserved-key rule that `_status` depends on
- a secret field reading back as `""` when set and `undefined` when not
  (`PluginSettingsBridge.swift:118-119`)
- a field's `defaultJSON` being returned when nothing is stored

**Fix:** one `PluginBridgeRuntimeTests`-style file per bridge, driven through
`PluginJSFixtureRunner` the way `PluginBrowserBridgeTests` drives the browser bridge.

---

## 19. Fixed-duration pumps stand in for waits in two plugin UI suites, and one comment claims the opposite

**test-gap** — `LunaTests/PluginDetailScreenTests.swift:152-154`,
`LunaTests/PluginImportCoordinatorTests.swift:103-108, 129-132, 155-158, 180-183`

Each waits `DispatchQueue.main.asyncAfter(deadline: .now() + 0.2)` and then asserts. CLAUDE.md
records this exact failure mode ("A fixed-duration pump is not a wait — poll the condition",
after `OnboardingHandoffFullContentTests` began flaking at ~360 ms under a saturated main
thread). `PluginDetailScreenTests` is waiting on a `Task { @MainActor }` hop
(`PluginDetailScreen.swift:287`), the same shape.

Worse, `PluginImportCoordinatorTests.swift:106-107` says
"wait for the presenter to go idle rather than polling a fixed time" immediately above a
fixed 0.2 s sleep — a comment that states the opposite of its code, which the comment
standard forbids.

**Fix:** poll the condition (`invoker.invocations.count == 1`,
`presenter.presentedViewController is …`) with an `XCTNSPredicateExpectation` or a small
poll helper, and delete the false comment.

---

## 20. `PluginLockedSaveRoutingTests` covers the media and product cards but not the article card

**test-gap** — `LunaTests/PluginLockedSaveRoutingTests.swift:73-109`

`claudedocs/plugins.md:513-517` says "the three card presenters (article/media/product)
already check `.needsCaptcha` and route through `chrome.presentUnlockFlow`". The suite tests
`MediaCardPresenter` and `ProductCardPresenter` for both the card face and the tap; the
article presenter — the kind a browser-gated paywall save most often produces — is absent
from the file.

**Fix:** add the two article rows to the existing tests.

---

## 21. An update that adds no capability installs a completely new script with no screen and no confirmation

**design** — `LunaLibraries/Sources/LunaPluginKit/PluginImporter.swift:58`,
`LunaPluginUI/PluginImportCoordinator.swift:69-83`

```swift
requiresConsent: installed == nil || !added.isEmpty,
```

When a plugin with the same `id` is already installed and the new file declares no new
capability, `requiresConsent` is false and `handle(sourceText:origin:)` calls `install`
straight away. The body may be entirely different code. There is no consent screen, no
confirmation alert, and no success feedback at all — the coordinator just calls
`observer?.pluginImportDidFinish` and the list reloads. The user's only evidence that
anything happened is the version string changing in a row they may not be looking at.

Skipping *re-consent* for an unchanged capability set is defensible; skipping every signal is
not. Note the string is already written for the case (`"Plugins_consentUpdateHeadline_Luna"
= "This update wants more access"` only makes sense on the added-capability path).

**Fix:** keep `requiresConsent` as is, but show the consent screen in "review this update"
form (or at minimum a confirmation alert naming the old and new version) for any replacement.

---

## 22. Two near-identical browser-modal presenters

**simplification** — `PluginUIComposition+Bridges.swift:31-66` (`ModalPluginBrowserPresenter`)
and `PluginUnlockFlow.swift:64-116` (`PluginUnlockFlowRunner`)

Both build a `PluginBrowserViewController` with
`L10n.string("PluginBrowser_defaultTitle")` and `pageMaker.makePage(for: request)`, wrap it
in a `UINavigationController`, hold it in a `weak var navigation`, present it, and implement
the same two delegate methods with the same dismiss-then-answer ordering. They differ only in
what they do with the result (resume a continuation vs. write `PluginBrowserRequestStore` and
kick the resumer) and in the single-flight token (`continuation == nil` vs
`presentedSaveID == nil`).

**Fix:** extract one `PluginBrowserModalPresentation` that owns present/dismiss/delegate and
calls a `didFinish(PluginBrowserResult?)` witness, leaving the two call sites as the two
witnesses.

---

## 23. Dead code

**dead code**

- `LunaLibraries/Sources/LunaPluginUI/LunaPluginUIPlaceholder.swift:1-8` — "Holds the target
  until Wave 1 lands Settings → Plugins, import and consent". Wave 1 landed; the module has
  nineteen other files. Delete the file.
- `LunaLibraries/Sources/LunaPluginKit/PluginImporter.swift:30-37` —
  `preview(fileAt url: URL)` is not on the `PluginImporting` protocol
  (`PluginPlatformSeams.swift:234-240`) and has no caller (grep finds only its own
  definition). `PluginImportCoordinator.documentPicker` reads the file itself with
  `String(contentsOf:encoding:)` (`:109`). Delete it, or better, route the coordinator through
  it — it is the version that handles the security-scoped resource and reports `notText` by
  filename.

---

## 24. Stored closures across two component boundaries

**design (owner standard)** — `PluginDetailScreen.swift:427-435`, `PluginChoiceScreen.swift:17-24`

CLAUDE.md: "a stored closure property or a closure parameter stored from `init` is not an
acceptable seam … Component boundaries inside the UI use `*Delegate`/`*DataSource` protocols
with weak references."

- `PluginFieldEditCell.onCommit: (String) -> Void`, stored from `init` and fired from
  `editingEnded` — a cell→controller boundary, the textbook `*Delegate` case (and the cell
  holds the controller strongly through the escaping closure, though the controller does not
  retain the cell, so no cycle today).
- `PluginChoiceScreen.onSelect: (String) -> Void`, stored from `init` — a pushed screen
  reporting back to its pusher.

The rest of the module follows the standard well (`PluginBrowserViewControllerDelegate`,
`PluginConsentDelegate`, `PluginPasteImportDelegate`, `PluginImportObserving`,
`PluginBrowserPresenting`), which makes these two the odd ones out.

**Fix:** a `PluginFieldEditCellDelegate` and a `PluginChoiceScreenDelegate`, both `weak`.

---

## 25. Two doc comments describe behaviour the code does not have; two README cross-references point at the wrong section, and the `settings` schema is documented nowhere

**comment standard / docs-drift**

- `LunaPluginRuntime/Bridges/PluginStorageBridge.swift:47-53`:
  "`undefined` is the answer for a key that holds nothing; `null` is a value a plugin may
  have stored on purpose." Both branches call `box.fulfill(NSNull())`, which reaches JS as
  `null` — the distinction the comment draws does not exist, and `luna-plugin.d.ts:320`
  (`get(key): Promise<unknown | undefined>`) repeats it.
- `LunaPluginUI/PluginUIBridge.swift:122-123` — the `FileHandle`-by-id comment, see finding 3.
- `docs/plugins/README.md:255` — "the cookies a `luna.browser` step just earned — see §7"
  points at §7 *Export plugins*; the browser step is §6.
- `docs/plugins/README.md:277` — "the values your manifest's `settings` schema declares (see
  §7 for the schema itself)" — §7 is Export plugins and describes no settings schema. In fact
  **no prose document describes the `settings` manifest field at all**: README §1's field
  table omits it, and `api.md:428-434` defers to "README §1". A plugin author's only source
  for `type`/`options`/`default`/`required`/`secret`/`pairedDevice`/`action`/`info` is the
  `.d.ts` type. Given finding 7 (a `help` that is never rendered) and finding 1, the settings
  surface is the least-documented part of the API.

**Fix:** correct the two comments to match the code, repoint the two cross-references, and
add a "Settings schema" section to README covering each field type and what the detail screen
actually renders for it.

---

## Also noticed, below the reporting bar but worth knowing

- `PluginUIPresenter.prompt`/`confirm`/`choose` resume their `CheckedContinuation` only from
  an alert action. If `presenter.present` fails — the top view controller is already
  presenting, or is mid-transition — nothing ever resumes and the plugin's promise hangs
  until its hook budget expires (`PluginUIPresenting.swift:64-121`).
- `PluginImportCoordinator.documentPicker` (`:109`) reads the whole picked file into a
  `String` before `PluginManifestParser` applies the 1024 KB cap
  (`PluginManifestParser.swift:35`), so a large `.txt` picked from Files is a memory spike
  before it is a clean error.
- `luna.env.locale` is `Locale.current.identifier` in Swift (`PluginContext.swift:68`, e.g.
  `"en_US"`) but `config.locale || "en"` in both JS backings — a plugin matching on it sees
  two shapes.
- `luna.exports.queued()` rows omit `queuedAt` when the save has no date
  (`PluginExportsBridge.swift:94-96`), while `luna-plugin.d.ts:432` declares it required.
- The plugin stage catalog and `Luna/Stage/StageManifest.json` agree exactly (all seven ids,
  `kind: "plugin"`, `apps: ["luna"]`), and the `project.pbxproj` membership exceptions for
  `StageCatalog+Plugins.swift`, `PluginsSettingsCategory.swift`, `XteinkSettingsScreen.swift`
  and the two `SafariPluginMessages+*` variants are all exactly as `claudedocs/plugins.md`
  describes — no drift found there.
