# Send to Kindle

Background delivery of saved articles to an ereader. The article is rendered
to EPUB on-device for each destination's output profile, then delivered to
each configured destination.
There are two destinations:

- **Kindle** — emailed to the user's `@kindle.com` address through the
  connected Luna email account (the same account used for sign-in and friend
  sharing; `EmailAccountStore`). That account's address must be on Amazon's
  approved-sender list (amazon.com → Preferences → Personal Document
  Settings). There is no separate SMTP credential for Kindle.
- **Xteink** — uploaded over local Wi-Fi straight to the e-reader's
  stock-firmware file manager; see `claudedocs/xteink.md`.

No UI taps needed once configured: an incoming article either goes out
automatically per its capture source (below), or the user sends it explicitly
from the saves list's long-press menu.

## Where the Kindle destination lives, per app

**Central Luna sends to Kindle through the bundled `kindle.js` plugin**
(`claudedocs/plans/plugin-platform.md` §9.5); **Luna Reader keeps
`KindleDestination`**. The plugin keeps the `kindle` destination id
(`PluginDestinationLegacyIDs`), so everything below — the send states, the
sent dates, the retry counts, the per-source auto-send toggles — applies to it
unchanged. What differs in the central app:

- The address and the sender-note toggle are the plugin's own settings, in
  Settings → Plugins → Kindle. The one-time migration seeds the address from
  `KindleSendSettings` at launch, and re-seeds it while the plugin's own
  setting is empty (which is what carries an address typed in Luna Reader
  across). Editing it in one app after that does not reach the other.
- The Kindle settings CATEGORY is gone from the central app, so Kindle's
  auto-send-by-source screen is reachable in Luna Reader only.
- The EPUB is built by `ExportInputProducer` rather than the coordinator, from
  the same `EpubBuilder` and the same image preparation.
- `PluginDestination.isConfigured` still requires a connected account: the
  plugin declares the `mail` capability, and a mail-sending export plugin is
  no more configured than the account is.

## Destinations

`ArticleDestination` (`LunaLibraries/Sources/LunaSend/ArticleSendCoordinator.swift`)
abstracts a destination's `id`/`displayName`, `isConfigured`,
`sendMode(for: SavedItem)` (source-aware auto-send), `appIntentsSendMode`
(the mode governing App-Intents/in-app saves, consulted for double-save-press
detection), and `send(epubData:fileName:title:)`. The coordinator itself is
destination-agnostic and holds an `[ArticleDestination]`.

`KindleDestination` is the sole conformer: it delegates to an
`ArticleEmailSending` (`AccountEmailSender` in production, injectable for
tests), and its `isConfigured`/`sendMode`/`appIntentsSendMode` all forward to
`KindleSendSettings`/`SourceSendSettings`. `AccountEmailSender` builds a
`MIMEMessage` addressed to `KindleSendSettings.kindleAddress` and hands it to
the connected account's `EmailTransport`. Because `LunaSend` sits below
`LunaMailTransport` in the dependency graph, the transport is supplied through
a static closure, `ArticleEmailTransportProvider.make`, set once at launch in
`Luna/AppDelegate.swift` (`{ MailTransportFactory.make() }`); in contexts that
never send (extensions) it stays `{ nil }`, so email sends there fail as
not-configured rather than crash.

`KindleSendSettings.isConfigured` requires
`EmailAccountStore.shared.isReady`, not merely stored metadata. A definite
provider authentication rejection therefore pauses new/retried Kindle mail and
routes the user to Email recovery instead of repeatedly retrying a known-invalid
credential.

## Auto-send by capture source

Each item records where it came from: `SavedItem.captureSource`
(`CaptureSource` in `LunaModels`; nil legacy items → `.manual` via
`effectiveCaptureSource`). Cases and where they're actually set today:

- **`.email`** — `IncomingMailImporter` (`LunaLibraries/Sources/LunaSaves/`),
  for every mail-sourced save: matched newsletters, Luna-prefixed shares
  without a recoverable marker, **and accepted friend shares** (`autoImport`
  tags these `.email` too — see the friend-share caveat below).
- **`.appIntent`** — `IntentIngestHelper.handleSavePressWithTimeout`
  (`LunaIntents`), for saves made through the Action Button / Shortcuts.
- **`.shareSheet`** — the share extension inserts through the same
  `SavesStore`, which stamps `capture_source` on the row.
- **`.paste`** — pasteboard-URL saves from the permanent util card
  (`ArticleCardsViewController`, `SavedMediaCardsViewController`, and
  `PriceTrackerCardsViewController`).
- **`.manual`** — the default: typed URL, reader save button, deep links.
- **`.friendShare`** — declared in `CaptureSource` and handled by
  `SourceSendSettings`/`SurfaceSupport`/`SavesIngestor`, but **no
  production code path currently assigns it**: the one place a friend share
  is actually imported (`IncomingMailImporter.autoImport`) tags the item
  `.email`, and `SavedItem.sharedByUsername` (the field the friend-share
  branch below keys its per-friend overrides on) is likewise never set outside
  test fixtures. In practice, then, a friend-shared article's auto-send
  behavior today is governed by the plain **email** toggle, not the
  friend-share-specific one — and there's no Settings UI for the
  friend-share toggle either (see "UI" below). Flagged here as a known gap
  between the code that exists and the code that's reachable, not something
  this doc's rewrite fixes.

`SourceSendSettings` (`LunaLibraries/Sources/LunaSend/SourceSendSettings.swift`)
resolves, per destination, a capture source → `ArticleSendMode`
(`off`/`allSaves`/`doubleSave`):

- **App Intents (Shortcuts) & manual saves** → the destination's existing
  `appIntentsMode` (Kindle: `KindleSendSettings.sendMode`) — the only source
  whose double-save press is detected at save time (see Gating below).
- **Email** → on/off. Kindle reuses `IncomingMailSettings.autoSendToKindle`
  (the same key as the mail importer's "Also Send to Kindle" toggle, so the
  two surfaces never diverge) rather than its own key.
- **Share sheet & paste** → one on/off toggle.
- **Friend shares** → an on/off default plus per-friend overrides
  (`friendShareEnabled(forDestination:username:)`, JSON map in
  `UserDefaults`) — unreachable in production today per the caveat above.

Sources other than App Intents default to whatever the destination's legacy
`appIntentsMode` was (`legacyDefault`: on if it was `.allSaves`), so existing
setups keep behaving the same until the user touches the new per-source
controls.

## Gating (save-press state machine)

Every save funnels through
`SavesIngestor.handleSavePress(urlString:source:...)`, which asks the
pure `SavePressPolicy.decide(...)` what a press on this URL means:

1. **URL not in the list** → `.saveNew`: save (tagged with `source`) and
   ingest.
2. **URL already in the list, second press within the window** →
   a double-save decision (see the two regimes below).
3. **Any other press on an existing URL** → `.ignore` (no re-ingest).

Two double-save regimes coexist, distinguished by whether the caller passes
an `intentAction` (only the Action Button's Save App Intent does, via
`doubleSaveActionSurface`):

- **Legacy (in-app saves), 12 s window** — `.sendToEreaders(destinationIDs:)`:
  sends to every destination whose `appIntentsSendMode == .doubleSave`
  and that hasn't already sent this item within the last 24 h
  (`SavePressPolicy.resendCooldown`). `ArticleSendCoordinator.doubleSaveDestinationIDs()`
  supplies the eligible, configured destination ids.
- **Action Button (Save App Intent), 7 s window** —
  `SavesIngestor.resolvedIntentAction` resolves to `.sendToKindle` when
  Kindle is configured, and nil otherwise. `SavePressPolicy` turns the former
  into `.sendToEreaders`; there is no contact action or user-facing double-save
  setting.

Either way, platform items (videos, posts, tracks — no article EPUB target)
never trigger an ereader send; a double press on one is always `.ignore`.

Separately from double-press gating, `ArticleSendCoordinator.articleBecameReady(_:)`
(called by the ingestor once an item's content is ready) drives the *ordinary*
auto-send: for each configured destination, it sends anything the item has
queued, plus — when that destination's `sendMode(for: item)` resolves to
`.allSaves` — every new item regardless of a double press ever happening.

## Coordinator

`ArticleSendCoordinator` (`.shared`) orchestrates delivery across
destinations — gating, queueing while an article is still ingesting, EPUB
generation, delivery, and per-destination per-item state:

- `send(_:toDestinationID:)` — explicit single-destination send (the
  long-press context menu).
- `articleBecameReady(_:)` — see above.
- `retryPendingSends()` — launch, foreground, pull-to-refresh, background
  entry, and the existing overnight mail/price background tasks reconcile
  ready items whose source mode is `.allSaves` into `.queued`, then sweep all
  `.queued` sends whose backoff has elapsed. This reconciliation covers
  share/action extensions, which persist ready article content without running
  the app-only readiness observer.
- `sendTestDocument(toDestinationID:)` — backs each destination's Settings
  test row with a small literal `ArticleContent`.
- The EPUB is built once per delivery attempt; in-flight sends are deduped by
  an `"<itemID>|<destinationID>"` key; `.queued` is written to the item
  *before* the network call, so a mid-send process death is retried rather
  than silently lost.
- Soft failures stay `.queued`, with `sendFailureCounts`, `sendNextAttemptDates`,
  and `sendLastErrors` persisted on the save row. Backoff starts at
  15 minutes and doubles up to 12 hours (`RetryPolicy`); after 5 soft
  failures, or immediately for a hard failure (not-configured, auth, or a
  malformed message), the row becomes `.failed` and stops retrying.
- Terminal failures set `pendingSendFailureNotices`; the saves list consumes
  that flag and shows a one-shot bottom pill immediately if foregrounded, or
  on the next launch/foreground presentation if the failure happened in a
  background wakeup.

## EPUB & MIME

- `EpubBuilder` (`LunaLibraries/Sources/LunaEpub/EpubBuilder.swift`) — builds a
  minimal EPUB 3 from `ArticleContent` (mimetype stored first, then
  `META-INF/container.xml`, `OEBPS/content.opf`, `OEBPS/nav.xhtml`, one
  `OEBPS/chapter.xhtml`), embedding the article's downloaded jpg/png/gif/webp
  images. This is the format Amazon recommends for Send to Kindle (converted
  to AZW3 on their side).
- `ZipArchiveWriter` — a minimal ZIP writer with its own CRC32 and stored
  entries by default; selected text entries can use raw DEFLATE. The standard
  Kindle/export profile remains stored, while the Xteink profile requests
  DEFLATE when it reduces bytes.
- `MIMEMessage` (`LunaLibraries/Sources/LunaEpub/MIMEMessage.swift`) — an RFC
  5322 message with one attachment, rendered `multipart/mixed`, CRLF
  throughout, RFC 2047-encoded subject via the shared `MIMEHeaderEncoding`.
  Built by `AccountEmailSender` and handed to the connected account's
  `EmailTransport` as raw MIME bytes.
- `KindleSendSettings` (`LunaLibraries/Sources/LunaSend/KindleSendSettings.swift`) —
  the Kindle address and `sendMode` (a typealias of `ArticleSendMode`);
  `isConfigured` is true when a Kindle address is set *and* an email account
  is connected. No Keychain entry of its own — Kindle authenticates purely as
  "mail from an approved sender," so the only secret involved is the
  connected email account's own credential (`CredentialKeychain`, shared
  across the App Group so all three Luna apps see one account).

## Model & store

`SavedItem` carries `sendStates: [String: SendState]` and
`datesSent: [String: Date]`, both keyed by destination id
(`sendState(for:)`/`dateSent(for:)` helpers; `SendState` is `.queued`/`.sent`/
`.failed`). A `Codable` migration folds the legacy single `sendState`/`dateSent`
(from when Kindle was the only possible destination) under `"kindle"`.
`SavesStore.setSendState(_:for:destination:)` stamps
`datesSent[destination]` when transitioning to `.sent`.

## UI

- Settings → "Email" (`EmailAndKindleSettingsScreen`) groups the connected
  sharing account, import toggle/senders, and subject filters.
- Settings → "Kindle" (`KindleSettingsScreen`) owns the Kindle address, test
  send, and forwarding-settings disclosure. Its top-level row is dimmed until
  email is connected; tapping it offers to open Email with the address field
  focused. Action Button double save has no setting: it sends to configured
  Kindle or does nothing.
- `AutoSendBySourceScreen` — three rows today: App Intents mode
  (off/all-saves/double-save) and on/off for email and for share-sheet-&-paste.
  There is no row for friend shares (see the capture-source caveat above).
- the deck's card menu — a per-destination entry in the item's
  long-press context menu (`sendToEreader`, gated on
  `ArticleSendCoordinator.isConfigured(destinationID:)`), and a bottom pill
  for a terminal send failure.

## Tests (`LunaTests/`)

`ZipArchiveWriterTests`, `EpubBuilderTests`, `MIMEMessageTests` cover the
EPUB/MIME building blocks. `DoubleSavePolicyTests` and
`ScreenshotDoublePressTests` cover the newer Action-Button 7 s double-save
regime; the legacy `DoubleSaveActionStoreTests` cover
that store directly. There is currently **no** dedicated test coverage for
`SourceSendSettings`'s per-source resolution or for `ArticleSendCoordinator`'s
multi-destination fan-out/retry/backoff, or for the legacy 12 s regime in
`SavePressPolicy` — all three had test files at one point that were deleted as
collateral damage in an unrelated cleanup commit; restoring them is tracked
separately, not part of this doc.

## Images

`sendBuildingEPUB` calls `ArticleExportService.prepareImages` before building
the book. An auto-send fires the moment an article becomes ready — which is
before its pictures have finished downloading — so without this the Kindle got
an illustration-free copy. See article-export.md.
