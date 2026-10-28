# Luna Reader and companion apps

## Device automation rule

- Never install, launch, or use `WebDriverAgentRunner` / WebDriverAgent on a
  user's iPhone. This prohibition is absolute and applies to build, test,
  debugging, and UI-inspection workflows.

Luna is a family of native apps (UIKit, deployment target iOS 26).

- **Luna Reader** (`com.hsanabria.luna`, Xcode target `LunaReader`) — the
  single link app, combining articles/documents, scrolling and RSVP readers,
  Send to Kindle, social/video/audio saves, friend sharing, and product price
  tracking. This is the former Luna Core app, now called Luna Reader in code,
  on the phone, and in chats. Its App Store listing remains **Luna: Save Anything**.
  The former standalone Reader, Shopping/Price Tracker, and Downloader apps
  and their extensions are retired. The shared App Group and `saves.sqlite` stay
  unchanged. Legacy surface identifiers and file types remain for compatibility.
- **Luna Keyboard** (`com.hsanabria.luna.keyboard`, target `LunaKeyboard`) —
  standalone keyboard, shortcuts, swipe typing, emoji and recent Luna link/video
  suggestions. Its extension uses the shared App Group and saves database. See
  `claudedocs/keyboard.md`.
- **Luna Music** (`com.hsanabria.luna.music`, target `LunaMusic`) — a standalone
  MusicKit/MediaPlayer library player with search on foreground, playlist-aware
  shuffle continuation, Siri, widgets and a queue Live Activity. See
  `claudedocs/music.md`. Links `LunaMusicKit`; reads `saves.sqlite` only to browse and render Reader text saves for the podcast queue.
- **Luna Vault** (`com.hsanabria.luna.vault`, target `LunaVault`) — an encrypted,
  search-first arbitrary-file surface. Vault v1 stores on device, in iCloud
  (with optional local eviction), or on a user-owned Mac. AWS/S3-compatible
  providers and hosted Luna infrastructure are deferred.

- **Orbit** is the standalone source editor, Mac build/install companion and
  JavaScript widget host in `/Users/hsp/Desktop/Orbit` and the
  [Orbit repository](https://github.com/diaruga777/Orbit). Luna Mac serves Vault
  and Music; Orbit owns its own pairing, app identities, signing and refresh.

Vault-to-Mac reachability may use the user's separately installed Tailscale
client (MagicDNS/Tailscale IP) or same-LAN discovery. Tailscale is transport
and discovery only; Vault still pairs/authenticates an app-level encrypted
protocol and does not embed a Tailscale SDK or relay service.

**`luna` is a placeholder namespace** — rename it by editing the two top lines of
`Config/Luna.xcconfig` (`LUNA_NAMESPACE`, `COMPANY_PREFIX`). Everything derives from
there: bundle ids (`$(PRODUCT_BUNDLE_PREFIX).<app>`), the **shared** App Group
(`group.com.hsanabria.luna`) and iCloud container (`iCloud.com.hsanabria.luna`), display
names (`$(DISPLAY_NAME_PREFIX) …`), and — via Info.plist keys `LunaAppGroupID` /
`LunaICloudContainerID` read by the `LunaAppConfig` library (`AppConfig`) — the in-code
identifiers. Entitlements reference `$(APP_GROUP_ID)` / `$(ICLOUD_CONTAINER_ID)`.

**Shared store.** Saves from Luna, its share/action/Safari extensions and App
Intents use the shared ingest pipeline and `saves.sqlite` in the App Group.
Luna Reader accepts every content kind. The store uses SQLite, typed columns,
child tables under `ON DELETE CASCADE`, trigger-queued file reaping and WAL.
See `claudedocs/saves.md`. Keep feature docs in `claudedocs/` current.

**Targets.** `LunaReader` links `LunaKit` and embeds its own Share, Action, Safari and
Live Activity extensions. `LunaTests` hosts on Luna Reader. Vault, Music,
Keyboard and Writer remain independent. Dev uses Xcode 27 beta; archive/upload
uses stable Xcode 26.2. Preserve the existing handmade Action extension icons.

**Luna Mac signing.** `script/build_and_run.sh` stages and signs the
`LunaVaultMacCompanion` app. Its default is ad-hoc signing, which changes the
app's designated signing requirement and can make macOS ask for Files and
Folders access again. For any Luna Mac build that will be used on this Mac,
always set `LUNA_MAC_SIGNING_IDENTITY` to the same valid Apple Development
certificate used for the existing Luna Mac app, using its exact certificate
name or SHA-1 from `security find-identity -v -p codesigning`. Keep the bundle
identifier and app bundle location unchanged as well. Do this for every build,
including worktree builds and `--build-only` builds that will later be launched.
Never run the default ad-hoc signing path to relaunch a persistent client. If
the matching certificate cannot be identified or is unavailable, inspect the
existing app and keychain; if it is still uncertain, ask the user instead of
guessing or signing ad hoc. Verify the staged app's signature before launch
with `codesign -dv --verbose=2`.

**Plugins and premium.** Only the six non-media scripts under
`LunaLibraries/Sources/LunaBundledPlugins/Plugins` ship in app resources. Media
and transcript sources live under `docs/plugins/media`; regenerate the optional
`docs/plugins/bundles/Luna-Media.lunabundle` with
`scripts/build_media_plugin_bundle.py` after changing those sources. Never copy
that bundle into app resources. Plugin bundle import previews and consents each
member before activation. Plugin creation is gated by `LunaPremium`; paid access
is shared in the App Group after StoreKit verification. Free access is strictly
in memory for the current app launch. See `claudedocs/premium.md`.

## User-facing copy

- Write like a person: short, casual, and clear. Never put prompt instructions,
  acceptance criteria, implementation plans, or descriptions of the UI into
  display text. Do not narrate controls or content the user can already see.
- Omit redundant helper text. Keep explanations only when they help someone
  decide, recover from an error, understand permissions/privacy, or discover an
  interaction. Describe the outcome or next step in familiar words.
- Keep technical details in diagnostics and source comments unless they are
  needed for the user's task (for example, an Xcode scheme in Orbit).

**Orbit extraction.** Phone-side cached-build signing, LocalDevVPN refresh,
Code agent tools and the Mac setup wizard live in Orbit. Do not restore Code
services or credentials into Luna Mac. Existing Luna Code data is left in place;
Orbit does not silently adopt Luna’s App Group, Keychain or pairing records.

## Agent workflow

- Keep publisher-specific ingestion fixes in the owning JavaScript plugin (and
  its source under `docs/plugins/lib/`); regenerate bundled helpers when needed.
  The Swift host stays site-agnostic: bridges, lifecycle, validation and storage,
  not publisher selectors, text extraction, paywall rules or recovery strategies.
- Commit completed work in small, logical chunks as it is verified. Do not bundle unrelated changes into the same commit.
- Unless told otherwise, do all work in your own worktree taken off `main`, not a
  shared checkout. Commit as you go, then merge the worktree's branch into `main`
  and delete both the worktree and the branch once the task is done — handle any
  merge conflicts yourself rather than leaving them for later. Repeat the same
  cycle for follow-up work (new worktree off the updated `main`, commit, merge,
  delete) rather than reusing a stale one. Never end a task with finished work
  still sitting unmerged in a worktree, including one left over from an earlier
  task in the same session.

## Module structure

Almost all code lives in the local SwiftPM package `LunaLibraries/` (layered: config/models
→ URL/HTML parsing → fetch/bypass/ingest → services → UIKit feature libs →
orchestration/intents; `LunaAppConfig` at the bottom is the App-Group/iCloud id source of
truth). The Xcode targets are thin shells: the `Luna/` folder holds the shared app shell
(AppDelegate/SceneDelegate), per-app Settings, the main-screen composition
(the card deck), composition wiring (AppReaderProviders/
OnboardingFlow/AppSurfaceConfig), the App Intent **definitions** (`Luna/Intents/*` — business
logic is in the `LunaIntents` library) — and is used by the Luna Reader app. The Share/Action extensions
link only `LunaShareSurface` (+ transitive), `LunaSafari` links nothing (it reads the App
Group id from its own Info.plist via `SafariAppGroup`). Cross-tier wiring uses injected
closures/protocols installed at launch in AppDelegate (e.g.
`SocialMessageCenter.ingestHandler`/`shareRecorder`, `DiagnosticLog.export*`,
`PriceTrackingViewController.intelligentPriceResolver`). The package is pinned to Swift
5 language mode. Reusable modules need `public` API + explicit `public init`s.

## Running the unit tests (CLI — works headless, no Blitz needed)

The full `LunaTests` suite runs from the command line on an **iOS 26.x simulator**
(deployment target is iOS 26) via the **`LunaReader`** scheme (Luna Reader is the test host). Recipe:

```sh
DD=<a derivedDataPath>
SIM=<a booted iOS 26.x simulator UDID>   # e.g. xcrun simctl list devices | grep -A8 'iOS 26'
xcodebuild test -scheme LunaReader -destination "platform=iOS Simulator,id=$SIM" \
  -configuration Debug -derivedDataPath "$DD"
```

- **The `Embedded binary is not signed with the same certificate as the parent app`
  error is permanently fixed.** The Luna app target has a **"Re-sign embedded
  extensions (debug)"** build phase (after Embed Foundation Extensions) that re-signs
  each `PlugIns/*.appex` with the app's OWN resolved identity
  (`codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY"`) so they always match the
  parent app on incremental builds — ad-hoc on the simulator, the Apple Development cert
  on a physical device. It's scoped to `CONFIGURATION == Debug` (no-op on Release /
  archive, so distribution/TestFlight signing is untouched), and covers both simulator
  AND device builds. You no longer need to delete the built `.app`/`.appex` products
  before each run. (Old escape hatch if it ever resurfaces:
  `rm -rf "$DD/Build/Products/Debug-iphone"*/*.app …/*.appex`.)
- **Do NOT pass `CODE_SIGNING_ALLOWED=NO`** — it strips the `group.com.hsanabria.luna`
  app-group entitlement, so the test host crashes at launch (early-exit, "external
  symbol") on app-group container access. Default ad-hoc signing applies the
  entitlement and the app group works on the simulator.
- **The full suite is green on the iOS 26.x sim: 904 tests, 2 skipped, 0 failures.**
  (The 2 skips are intentional `XCTSkip`s — `PriceTrackingScreenTests.testPriceTracking{,Alerting}EditorSnapshot`.)
  The ~36 failures previously documented here were all stale test data, not the
  environment, and have been fixed: snapshot reference PNGs are device-specific and
  were re-recorded on this sim with `RECORD_SNAPSHOTS=1` (re-record after intentional
  UI changes via `TEST_RUNNER_RECORD_SNAPSHOTS=1 xcodebuild test …` — the build-setting
  form does NOT reach the runner's environment); and the two extraction tests were
  aligned to the 1200 threshold. If snapshots fail again on a *different* device,
  re-record there rather than treating it as a regression.
- For a compile-only check (fast, no run): `xcodebuild build-for-testing -scheme LunaReader
  -destination 'generic/platform=iOS Simulator'`.

# Swift Project — Blitz AI Agent Guide

## blitz-macos

This project is opened in **Blitz**, a native macOS iOS/macOS development IDE with integrated simulator streaming. The user sees Build, Release, Insights, Testflight tab groups, and can see simulator view in Build>Simulator tab.

### MCP Servers

Two MCP servers are configured in `.mcp.json`:

- **`blitz-macos`** — Controls the Blitz app: project state, tab navigation, App Store Connect forms, build pipeline, settings.
- **`blitz-iphone`** — Controls the iOS device/simulator: tap, swipe, type, screenshots, UI hierarchy. See [iPhone MCP docs](https://github.com/blitzdotdev/iPhone-mcp).
- **`asc` CLI** — A bundled Go binary at `~/.blitz/bin/asc` for direct App Store Connect API access. Shares credentials with Blitz MCP tools automatically (no separate login needed).

### MCP Tools vs `asc` CLI vs Direct API Calls

**Priority order: MCP tools → `asc` CLI → direct API calls (last resort).**

**Default to MCP tools** for common workflows — they are opinionated, safe, and integrate with Blitz's UI (approval prompts, progress tracking, form validation). **When MCP tools don't cover an operation, use `asc` CLI** — it has 60+ subcommands covering nearly every ASC API endpoint and handles JWT auth, pagination, and retries. **Direct API calls (python scripts, curl to api.appstoreconnect.apple.com, urllib) should be an absolute last resort** — only when both MCP tools AND `asc` CLI genuinely cannot accomplish the task. Before writing any script, run `asc --help` and `asc <command> --help` to confirm the CLI doesn't already support it.

**Use MCP tools for:** filling ASC forms (`asc_fill_form`), reading tab/app state (`get_tab_state`), the build pipeline (`app_store_setup_signing` → `app_store_build` → `app_store_upload`), creating IAPs/subscriptions, setting prices, managing screenshots, and submitting for review.

**Use `asc` CLI for:** listing builds (`asc builds list`), TestFlight beta management (`asc testflight`), certificate/profile inspection (`asc certificates list`, `asc profiles list`), analytics & finance reports (`asc analytics`, `asc finance`), release management (`asc releases`), submission management (`asc submit create`, `asc submit cancel`), custom product pages (`asc product-pages`), Xcode Cloud (`asc xcode-cloud`), Game Center, offer codes, bulk localization updates, and any ASC operation without a dedicated MCP tool.

| Task | MCP (preferred) | `asc` CLI (fallback) |
|---|---|---|
| Set app information metadata | `asc_fill_form` tab="appInformation" | `asc metadata update --locale en-US ...` |
| Check submission readiness | `get_tab_state` tab="ascOverview" | `asc versions list` + manual checks |
| Create subscription | `asc_create_subscription` (one call) | `asc subscriptions create` + localization + pricing (3 steps) |
| Cancel stuck submission | N/A | `asc submit cancel --id "..."` |
| List all builds | N/A | `asc builds list` |
| Add beta testers | N/A | `asc testflight add-tester --email ...` |
| Upload IPA | `app_store_upload` (with polling) | `asc builds upload --path ./app.ipa` |
| Financial reports | N/A | `asc finance download --period 2026-01` |

Both tools share the same API key via Blitz's auth bridge (`~/.blitz/asc-agent/config.json`). If `asc` is not on PATH: `export PATH="$HOME/.blitz/bin:$PATH"`

### Testing Workflow

After making code changes:
1. Wait briefly for hot reload / rebuild
2. Use `blitz-iphone` `describe_screen` to verify the UI updated as expected
3. Use `blitz-iphone` `device_action` to interact (tap buttons, enter text, navigate)
4. Use `blitz-iphone` `describe_screen` again to verify the result

## App Store Connect Tools

### asc_fill_form

Fill App Store Connect form fields. Auto-navigates to the tab (if auto-nav permission is on).

#### Tabs and fields

**appInformation**
| field | type | required | notes |
|---|---|---|---|
| title | string | yes | App name (max 30 chars) |
| subtitle | string | no | (max 30 chars) |
| description | string | yes | (max 4000 chars) |
| keywords | string | yes | comma-separated, max 100 chars total |
| promotionalText | string | no | (max 170 chars) |
| marketingUrl | string | no | |
| supportUrl | string | yes | |
| whatsNew | string | no | first version must omit |
| privacyPolicyUrl | string | yes | |
| copyright | string | yes | e.g. "2026 Acme Inc" |
| primaryCategory | string | yes | GAMES, UTILITIES, PRODUCTIVITY, SOCIAL_NETWORKING, PHOTO_AND_VIDEO, MUSIC, TRAVEL, SPORTS, HEALTH_AND_FITNESS, EDUCATION, BUSINESS, FINANCE, NEWS, FOOD_AND_DRINK, LIFESTYLE, SHOPPING, ENTERTAINMENT, REFERENCE, MEDICAL, NAVIGATION, WEATHER, DEVELOPER_TOOLS |
| contentRightsDeclaration | string | yes | DOES_NOT_USE_THIRD_PARTY_CONTENT / USES_THIRD_PARTY_CONTENT |

Legacy aliases accepted: `storeListing`, `appDetails`

**monetization**
| field | type | required | values |
|---|---|---|---|
| isFree | string | yes | "true" / "false" |

To set a paid price, use the `asc_set_app_price` tool (not `asc_fill_form`). For in-app purchases and subscriptions, use `asc_create_iap` and `asc_create_subscription` — see dedicated tool docs below.

**review.ageRating**
Boolean fields (value "true"/"false"):
`gambling`, `messagingAndChat`, `unrestrictedWebAccess`, `userGeneratedContent`, `advertising`, `lootBox`, `healthOrWellnessTopics`, `parentalControls`, `ageAssurance`

Three-level string fields (value "NONE"/"INFREQUENT_OR_MILD"/"FREQUENT_OR_INTENSE"):
`alcoholTobaccoOrDrugUseOrReferences`, `contests`, `gamblingSimulated`, `gunsOrOtherWeapons`, `horrorOrFearThemes`, `matureOrSuggestiveThemes`, `medicalOrTreatmentInformation`, `profanityOrCrudeHumor`, `sexualContentGraphicAndNudity`, `sexualContentOrNudity`, `violenceCartoonOrFantasy`, `violenceRealistic`, `violenceRealisticProlongedGraphicOrSadistic`

**review.contact**
| field | type | required |
|---|---|---|
| contactFirstName | string | yes |
| contactLastName | string | yes |
| contactEmail | string | yes |
| contactPhone | string | yes |
| notes | string | no |
| demoAccountRequired | string | no |
| demoAccountName | string | conditional |
| demoAccountPassword | string | conditional |

**settings.bundleId**
| field | type | required |
|---|---|---|
| bundleId | string | yes |

### get_tab_state

Read the structured data state of any Blitz tab. Returns form field values, submission readiness, versions, builds, localizations, etc. **Use this instead of screenshots to read UI state.**

| param | type | required | notes |
|---|---|---|---|
| tab | string | no | Tab to query. Defaults to currently active tab. |

Valid tabs: `ascOverview`, `appInformation`, `screenshots`, `monetization`, `review`, `analytics`, `reviews`, `builds`, `groups`, `betaInfo`, `feedback`

Legacy aliases accepted: `storeListing`, `appDetails`

### asc_open_submit_preview

No arguments. Checks all required fields and either opens the Submit for Review modal or returns missing fields.

### app_store_setup_signing

Set up code signing for App Store distribution (iOS or macOS — auto-detected from project). Idempotent — re-running skips already-completed steps. For macOS, also creates MAC_INSTALLER_DISTRIBUTION certificate for .pkg signing.

| param | type | required | notes |
|---|---|---|---|
| teamId | string | no | Apple Developer Team ID. Saved to project metadata after first use. |

### app_store_build

Build an IPA for App Store submission. Archives the Xcode project and exports a signed IPA.

| param | type | required | notes |
|---|---|---|---|
| scheme | string | no | Xcode scheme (auto-detected if omitted) |
| configuration | string | no | Build configuration (default: "Release") |

### app_store_upload

Upload an IPA to App Store Connect / TestFlight. Optionally polls until build processing completes.

| param | type | required | notes |
|---|---|---|---|
| ipaPath | string | no | Path to IPA (uses latest app_store_build output if omitted) |
| skipPolling | boolean | no | Skip waiting for build processing (default: false) |

### asc_set_app_price

Set the app's price on the App Store.

| param | type | required | notes |
|---|---|---|---|
| price | string | yes | Price in USD (e.g. "0.99", "0" for free) |
| effectiveDate | string | no | ISO date for scheduled price change (e.g. "2026-06-01"). Omit for immediate. |

### asc_create_iap

Create an in-app purchase. Creates the IAP, adds en-US localization, and sets the price.

| param | type | required | notes |
|---|---|---|---|
| productId | string | yes | Unique product identifier (e.g. com.app.coins100) |
| name | string | yes | Internal reference name |
| type | string | yes | CONSUMABLE, NON_CONSUMABLE, or NON_RENEWING_SUBSCRIPTION |
| displayName | string | yes | User-facing display name (en-US) |
| price | string | yes | Price in USD (e.g. "0.99") |
| description | string | no | User-facing description |

### asc_create_subscription

Create an auto-renewable subscription. Creates or reuses a subscription group.

| param | type | required | notes |
|---|---|---|---|
| groupName | string | yes | Subscription group name (created if doesn't exist) |
| productId | string | yes | Unique product identifier |
| name | string | yes | Internal reference name |
| displayName | string | yes | User-facing display name (en-US) |
| duration | string | yes | ONE_WEEK, ONE_MONTH, TWO_MONTHS, THREE_MONTHS, SIX_MONTHS, ONE_YEAR |
| price | string | yes | Price in USD (e.g. "4.99") |
| description | string | no | User-facing description |

### Recommended full workflow (code + build + submission)

0. Code the app in the pwd, using the current pwd's framework language
1. Check submission readiness: call `get_tab_state` with `tab: "ascOverview"` — check `submissionReadiness.isComplete` and review `submissionReadiness.missingRequired` for any missing fields
2. Fill all required ASC forms until submission readiness is complete:
    - `asc_fill_form` tab `"appInformation"` — title, description, keywords, supportUrl, privacyPolicyUrl, copyright, primaryCategory, contentRightsDeclaration
    - `asc_fill_form` tab `"monetization"` — isFree (use `asc_set_app_price` for paid pricing)
    - `asc_fill_form` tab `"review.ageRating"` — set all applicable content descriptors
    - `asc_fill_form` tab `"review.contact"` — contactFirstName, contactLastName, contactEmail, contactPhone
    - Screenshots: `screenshots_switch_localization` → `screenshots_put_track_slot` / `screenshots_remove_track_slot` / `screenshots_reorder_track` → `screenshots_save` for APP_IPHONE_67/APP_IPAD_PRO_3GEN_129 (iOS) or APP_DESKTOP (macOS)
    - Re-check `get_tab_state` tab `"ascOverview"` to confirm all required fields are filled
3. **Manual step:** Tell the user to set Privacy Nutrition Labels manually in [App Store Connect](https://appstoreconnect.apple.com) — this is not exposed in Apple's REST API
4. `app_store_setup_signing` teamId=YOUR_TEAM_ID (one-time per bundle ID)
5. `app_store_build`
6. `app_store_upload`
7. `asc_open_submit_preview` — fix any flagged missing fields, then submit
