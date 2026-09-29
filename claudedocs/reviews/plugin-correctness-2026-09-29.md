# Plugin correctness review — 2026-09-29

Reviewed the current contract in `claudedocs/plugins.md`, the AI handoff plan,
authoring reference, bundled plugins, runtime, native bridges, composition,
settings, draft import and export delivery. Baseline: `58fa252b7`.

## Findings fixed

| Priority | Defect and consequence | Correction |
| --- | --- | --- |
| P1 | Destination share rows called the hook directly. Xteink's `retry` did not enqueue a send; Kindle delivery bypassed send bookkeeping. | Route destination taps through `ArticleSendCoordinator`. Regression covers a tap remaining queued, followed by a successful tap being recorded as sent. |
| P1 | The destination registry captured launch-time declarations. Imported destinations and changed export declarations were stale until relaunch. | Resolve destinations from the current runtime on every lookup. Keep central Luna's Swift replacements retired even when their plugins are disabled. |
| P1 | Secret settings were plaintext in `plugin_kv`, while `luna.secrets.get` read a separate Keychain item. Plugins could not use tokens entered in their settings as documented. Settings-change callbacks also received the plaintext. | Add schema-aware Keychain storage, migrate old values, mask callbacks, and recognize configured secret fields. Verify actual bridge reads and stored values. |
| P1 | Draft validation used the process-wide JavaScript VM and queue. A looping draft could block installed plugins. Launch/reload also evaluated top-level source synchronously without a deadline. | Give validation a separate VM/queue and bound all loads. A finite busy-loop regression verifies deadline return and concurrent progress in the live runtime. |
| P1 | ChatGPT used undocumented `chatgpt://new-chat?prompt=…`. Successful URL dispatch was mistaken for prompt delivery. | Use the existing HTTPS `q` route as primary. The actual open completion now controls fallbacks. Provider-side consumption remains a device verification item. |
| P2 | A Unicode prompt within the character budget could exceed the encoded URL limit; Create/Generate Again silently ignored the tap. | Copy the generated prompt, open an empty provider composer, and show a paste instruction. |
| P2 | Draft validation skipped host matching when given a target URL without a recovery-case object, yielding a misleading pass for a plugin the real walk would never select. | Match against the effective target URL. |
| P2 | The draft review rejected every export-only plugin even though the platform supports them. | Check registration and required hooks; clearly state that delivery/device hooks were not exercised. |
| P2 | Both provider buttons used invented geometric approximations. | Bundle the providers' unmodified template marks. Visually inspected both in the simulator. |
| P2 | The reference linked from the prompt advertised nonexistent setting type `secret`, omitted `await`, and suggested swallowing browser deferrals. | Correct the source reference and generated `site/dist/p1`. These website changes are prepared locally; they have not been deployed. |

## Remaining gaps

1. **Create with AI is still an ingest-oriented authoring flow.**
   `LLMHandoffPrompts.pluginCreation` and the linked compact reference teach
   URL → Model plugins. They do not provide a complete export or Bluetooth/Wi-Fi
   authoring contract. Those capabilities work through manually authored plugins,
   but the generic Create UI overstates how much the current prompt can generate.
   The full contracts are in `docs/plugins/api.md` and the bundled examples.
2. **A passing draft is not an end-to-end success guarantee.**
   `PluginDraftValidator` checks registration and Model decoding, serving only
   fetch/html. It does not download media, run transcription, adopt an article,
   exercise authenticated settings, deliver an export, or use a device. A valid
   but wrong Model can pass. Warnings identify untested capabilities; Save Anyway
   remains available after failures.
3. **A newly generated plugin may not replace an existing extractor.**
   The generated skeleton omits priority (default 0); bundled platform plugins
   use priority 100. A new ID runs after a matching bundled plugin, and a valid
   but incorrect bundled result prevents the new plugin being called. Authors
   must choose priority or an intentional replacement ID, or disable the old
   plugin. The prompt does not currently explain this decision.
4. **JavaScript execution is not interruptible.**
   Deadlines release callers; they do not kill a loop or reclaim its thread.
   An installed plugin can still wedge the shared live runtime until process
   restart. Draft isolation prevents the draft from taking live plugins with it,
   but is not a resource sandbox. This is an existing platform limitation.

## Can the bundled plugins do what they claim?

| Plugins | What the implementation and fixtures establish | What remains unverified live |
| --- | --- | --- |
| YouTube, Instagram, TikTok, Facebook, Reddit, X | Platform URL matching and fixture extraction match the Swift resolvers, including supported fallback shapes. | Current upstream markup/endpoints, authenticated content and successful CDN downloads. One public YouTube probe returned `ingest: null`; it did not establish a working live extraction. |
| Direct media | Supported file-extension URLs become media assets without fetching the page. | Availability and content of any particular remote file. |
| Seven transcript counterparts | Caption-first, then available audio/video transcription recipes; explicit transcribe intent routes correctly. | Current caption endpoints and actual on-device speech transcription of live media. |
| Kindle | EPUB input, account/settings gating and mail bridge contract are tested. Manual destination taps now use the queue correctly. | An email arriving on a real Kindle; no real mail was sent. |
| Xteink | Pairing/protocol fakes, BLE/Wi-Fi routing, retry and queued-send bookkeeping are covered. | A real reader transfer, device firmware compatibility and background radio behavior. |

Article and product ingest are supported by custom plugins and native adopters;
there are no bundled general-purpose article/product plugin extractors. Swift
extraction remains the floor when plugin ingestion declines or fails.

## Verification

- 684 native tests passed across 73 plugin/handoff test classes on iOS 26.2.
- Node harness tests passed; shared HTML/text spec: 108/108.
- Provider artwork inspected in the staged Create screen on an iOS simulator.
- Final focused rerun: 52 tests passed, covering the last clipboard and
  registry-disable changes.
- The hosted `/p1` reference was blocked by this environment (HTTP 403/browser
  `ERR_BLOCKED_BY_CLIENT`); this is not evidence that the public site is down.
- No physical iPhone automation, WebDriverAgent, real mail delivery or reader
  hardware was used. ChatGPT/Claude iOS prompt consumption was not verified.

The Node harness's `ok: true` means the return shape is valid; `ingest: null`
is a legal decline, not proof that a plugin resolved content successfully.
