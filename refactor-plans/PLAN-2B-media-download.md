# Wave 2B — LunaMediaDownload

Read `PLAN.md` hard rules and `audits/downloader-media.md` §2.3B/C, §2.4 first.
Files: `LunaLibraries/Sources/LunaMediaDownload/*` only (Wave 3C owns
`SavedMediaCardsViewController`). One commit per item.

1. **Split `LiveMediaDownloadManager.swift` (1462 lines) into four files** — pure moves,
   zero code edits beyond access-level adjustments that the move forces:
   - `LiveMediaDownloadJob.swift` (the model, ~lines 1255-1337)
   - `LiveMediaDownloadJobStore.swift` (`JobStore`, ~1339-1462; keep the type name unless
     a rename is free)
   - `LiveMediaDownloadManager+ActivityKit.swift` (the self-contained ActivityKit
     extension, ~1114-1253, `#if canImport(ActivityKit)` preserved)
   - the manager keeps the rest.
   The module has no test of its own file layout; `LiveMediaDownloadJobTests` must stay
   green.

2. **Dedupe `copyToClipboardIfEnabled`** (§2.3B): the two byte-identical `@MainActor`
   private funcs (`LiveMediaDownloadManager.swift`, `MediaDownloadService.swift`) become
   one shared `@MainActor` function (natural home: `MediaItemProvider.swift` next to
   `MediaPasteboard`), called from both.

3. **`mediaAssetRequest(assetURL:sourceURL:)` helper** (§2.3C): collapse the 4 verbatim
   URLRequest-construction sites (UA header + conditional TikTok Referer, 60s timeout).

4. **Thumbnail-write tail dedupe** (§2.3C): one private `writeThumbnail(cgImage:jobID:)`
   used by both `makeThumbnail` and `makeVideoThumbnail`.

5. **Merge the two pending-Wi-Fi loops** (§2.3C): `resumePendingWiFiDownloads` /
   `startAllPendingWiFiDownloads` → one parameterized implementation; keep both public
   entry points if both have callers.

6. **Split the `start(urlString:...)` god method** (§2.4 region map, ~125 lines) into the
   three named phases the audit identified: gate-and-prepare (through the Wi-Fi/Photos
   gates), attach-to-existing-job, create-and-start-new-job. Preserve every early-return
   and its exact ordering — the gates are sequenced deliberately.

7. **`resolveKind` enum** (§2.4): replace the stringly-typed 9-literal mini state machine
   with a private `enum ResolveKind: String` whose raw values are the EXACT current
   strings. First check whether `resolveKind` is persisted in `jobs.json` (it lives on
   the job model) — if yes, the enum must encode/decode via the same raw strings so
   in-flight jobs from earlier builds still decode; add a decode-unknown fallback
   matching current behavior for unrecognized strings.

8. **Facebook fallback chain single source of truth** (§2.3B, top-10 #6): give the
   plugin→desktop→mobile→canonical order ONE definition (e.g. a static ordered array on
   `SocialMediaResolver` or on the new `ResolveKind`) that both the foreground resolver
   and the background state machine derive their next-step from. If you cannot do that
   without changing either engine's observable sequencing, fall back to: keep both, and
   strengthen the two mirroring comments to name the exact counterpart function that must
   change in lockstep. `SocialMediaResolverTests` covers the foreground chain — green
   required.

9. **`restartTransfer` recursion comment** (§2.4): add the one-line comment noting the
   `.resolving` reset recursion is deliberately single-level and why it can't loop.

Verification: build-for-testing per commit; at wave end run
`-only-testing:LunaTests/LiveMediaDownloadJobTests -only-testing:LunaTests/SocialMediaResolverTests -only-testing:LunaTests/RedditMediaParserTests -only-testing:LunaTests/SavedMediaStoreTests -only-testing:LunaTests/AutoDownloadSettingsTests -only-testing:LunaTests/IntentMediaExportNamingTests`.
