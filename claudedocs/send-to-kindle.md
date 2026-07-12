
Background delivery of saved articles to an ereader. The article is rendered to
EPUB on-device once, then delivered to each configured destination:

- **Kindle** — emailed to the user's `@kindle.com` address through the connected
  Luna email account (the same account used for sign-in and friend sharing). That
  account's address must be on Amazon's approved-sender list.

No UI taps needed once configured.

## Destinations

`ArticleDestination` (`Luna/Send/ArticleSendCoordinator.swift`) abstracts a
`isConfigured`, `sendMode(for: ReadingListItem)` (source-aware), `appIntentsSendMode`
(the App-Intents/in-app mode, for double-save press detection), and
`send(epubData:fileName:title:)`. `KindleDestination` wraps `AccountEmailSender`;
`[ArticleDestination]` and is destination-agnostic.

## Auto-send by capture source

Each item records where it came from: `ReadingListItem.captureSource`
(`CaptureSource` in `ReaderKit`; nil legacy items → `.manual` via
`effectiveCaptureSource`). Cases: `email`, `appIntent`, `friendShare`,
`shareSheet`, `paste`, `manual`. Set at each entry point:

- **email** — `IncomingMailImporter` (`store.add(…, source: .email)`).
- **appIntent** — `IntentIngestHelper.handleSavePressWithTimeout` (→ `.appIntent`).
- **friendShare** — `SocialMessageCenter` (`store.add(…, source: .friendShare)`;
  resolution keys on `sharedByUsername`).
- **shareSheet** — `SharedReadingListAppender` writes `"captureSource":"shareSheet"`
  (raw string — the extension doesn't link ReaderKit).
- **paste** — `ReadingListViewController` pasteboard saves.
- **manual** — default (typed URL, reader save button, deep links).

`SourceSendSettings` (`Luna/Send/SourceSendSettings.swift`) resolves, per
destination, a source → `ArticleSendMode`:

- **App Intents (Shortcuts) & in-app saves** → the destination's existing
  `sendMode` (`off`/`allSaves`/`doubleSave`); the only source whose double-save
  press is detected at save time.
- **Email** → on/off. Kindle reuses `IncomingMailSettings.autoSendToKindle`.
- **Share sheet & paste** → one on/off.
- **Friend shares** → an on/off default plus per-friend overrides
  (`friendShareEnabled(forDestination:username:)`, JSON map in defaults).

Sources other than App Intents default to the legacy "all saves" behavior
(`appIntentsMode == .allSaves`) so existing setups are unchanged until touched.

## Gating (save-press state machine)

All save entry points (the Action Button intents, in-app add)
funnel through `ReadingListIngestor.handleSavePress(urlString:source:)`:

1. URL not in list → save (tagged with `source`) + ingest.
2. URL already in list AND previous press < 12 s ago → send to every
   destination whose **App-Intents mode** is `.doubleSave` and that hasn't been
   sent in the past 24 h (`SavePressPolicy.Decision.sendToEreaders(destinationIDs:)`).
3. Any other press on an existing URL → ignored entirely (no re-ingest).

Decision logic is pure: `SavePressPolicy.decide(…, doubleSaveDestinationIDs:)`
where the caller supplies `ArticleSendCoordinator.doubleSaveDestinationIDs()`
(destinations whose `appIntentsSendMode == .doubleSave`). On ingestion,
`articleBecameReady` consults `destination.sendMode(for: item)` — the item's
capture source decides whether (and where) it auto-sends. Long-press a
shown only when that destination is configured.

## Coordinator

`ArticleSendCoordinator.swift`:
- `send(_:toDestinationID:)` — explicit single-destination send (context menu).
- `articleBecameReady(_:)` (called by the ingestor post-`saveContent`) — per
  destination, fires queued sends and, in `allSaves` mode, everything new.
- `retryPendingSends()` — launch, foreground, pull-to-refresh, background entry,
  and the existing overnight mail/price BG tasks all sweep `.queued` sends whose
  backoff has elapsed.
- `sendTestDocument(toDestinationID:)` — backs each settings test row.
- EPUB built once per delivery; in-flight dedup keyed `"<itemID>|<destID>"`;
  `.queued` written first so a mid-send process death is retried.
- Soft failures stay `.queued`, with per-destination `sendFailureCounts`,
  `sendNextAttemptDates`, and `sendLastErrors` persisted on the reading-list row.
  Backoff starts at 15 minutes and doubles up to 12 hours; after 5 soft failures,
  or immediately for hard setup/auth failures, the row becomes `.failed`.
- Terminal send failures set `pendingSendFailureNotices`; the reading list consumes
  that flag and shows a one-shot bottom pill immediately if foregrounded, or on the
  next launch/foreground presentation if the failure happened in a background wakeup.


  `users/signupByPhoneOrEmail` (code → long-lived token). Token in Keychain.
  `users/getDevice` + `im/getSig` (best-effort session pings, mirroring the
  reference) → `config/buckets` (bucket + OSS endpoint) → `config/stss` (OSS STS
  creds) → **signed OSS PUT** of the EPUB to `<uid>/push/<uuid>.epub` →
  `push/saveAndPush` (registers the object; `resourceType` is `"txt"` to match
  implies POST; decodes the `{data:…}` envelope. Response models incl. tolerant
  string-or-int `uid`.
  (StringToSign = VERB\n\nContent-Type\nDate\nCanonicalizedOSSHeaders +
  CanonicalizedResource; `x-oss-security-token` header; virtual-hosted URL).

reproduced by hand (the reference used the `oss2` SDK). It is NOT validated
disclosure; a friend tests post-publication. Known risk: `URLSession` may strip
the signed `Date` header (→ switch to a presigned URL if uploads 403).

## Other shared send files (`Luna/Send/`)

- `EpubBuilder.swift` — EPUB 3 from `ArticleContent` (mimetype stored first,
  container.xml, content.opf, nav.xhtml, one chapter.xhtml, embedded jpg/png/gif/webp).
- `ZipArchiveWriter.swift` — minimal stored-entry ZIP (own CRC32, no deps).
- `MIMEMessage.swift` — multipart/mixed, base64 EPUB, RFC 2047 subject. Built by
  `AccountEmailSender` and handed to the connected account's `EmailTransport`
  (`ArticleEmailTransportProvider.make`, injected at app launch in `AppDelegate`).
- `KindleSendSettings.swift` — Kindle address + `sendMode` (a typealias of
  `ArticleSendMode`); `isConfigured` is true when a Kindle address is set and an
  email account is connected.
  in-memory mock for tests). Kindle needs no secret here — it reuses the email
  `CredentialKeychain`: `kSecAttrAccessibleAfterFirstUnlock` (migratable, not
  `ThisDeviceOnly`) plus `kSecAttrSynchronizable=true`, so encrypted device restore
  and iCloud Keychain can preserve them when the user's system settings allow it.

## Model & store

`ReadingListItem`: `sendStates: [String: SendState]` and `datesSent: [String: Date]`
keyed by destination id (`sendState(for:)` / `dateSent(for:)` helpers). A Codable
migration folds the legacy single `sendState`/`dateSent` under `"kindle"`.
`ReadingListStore.setSendState(_:for:destination:)` stamps `datesSent[destination]`
on `.sent`.

## UI

- Settings → "Email & Sending" (`EmailAndKindleSettingsScreen`): the connected
  sharing account, a Send-to-Kindle section (Kindle address + test), a
  unofficial-API disclosure footer), and the import-from-email settings — all on
  Source"** disclosure row pushing the shared `AutoSendBySourceScreen`
  (`Luna/Settings/`): App Intents mode + email / share-sheet-&-paste / friend
  toggles + a per-friend list.
- `ReadingListViewController`: per-destination context-menu rows; subtitle shows

## Tests (`LunaTests/`)

`ZipArchiveWriterTests`, `EpubBuilderTests`, `MIMEMessageTests`,
`SavePressPolicyTests` (per-destination eligibility matrix), `ArticleSendCoordinatorTests`
(multi-destination fan-out + capture-source gating via a mock destination),
`SourceSendSettingsTests` (per-source resolution + per-friend overrides + legacy
mock `URLProtocol`), plus send-state + legacy-migration cases in `ReadingListStoreTests`.
