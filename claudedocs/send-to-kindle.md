# Send to Kindle

Background delivery of saved articles to the user's `@kindle.com` address: the
article is rendered to EPUB on-device and emailed through the user's own SMTP
account (Gmail app password or custom host, implicit TLS port 465 only). No UI
taps needed once configured.

## Gating (save-press state machine)

All save entry points (`ClipSafariPageIntent`, `SaveLinkIntent`, in-app add)
funnel through `ReadingListIngestor.handleSavePress(urlString:)`:

1. URL not in list → save + ingest.
2. URL already in list AND previous press < 12 s ago AND mode == `.doubleSave`
   AND configured AND NOT sent within past 24 h → send to Kindle.
3. Any other press on an existing URL → ignored entirely (no re-ingest).

Decision logic is pure: `SavePressPolicy.decide(...)` (`Clip/Send/SavePressPolicy.swift`).
Modes (`KindleSendSettings.SendMode`): `off` / `allSaves` (send after every
ingestion) / `doubleSave`. Long-press a reading-list row → "Send to Kindle"
context menu, always available when configured.

## Key files (`Clip/Send/`)

- `ArticleSendCoordinator.swift` — orchestration. `send(item)` queues if the
  article is still `.pending`, else EPUB → email → `sendState` `.sent`/`.failed`
  (`.queued` is written first so a process death mid-send is retried).
  `articleBecameReady(item)` (called by ingestor post-`saveContent`) fires
  queued sends and, in `allSaves` mode, everything new. `retryPendingSends()`
  runs on pull-to-refresh. `sendTestDocument()` backs the settings test row.
  `SMTPArticleEmailSender` is the production `ArticleEmailSending`.
- `EpubBuilder.swift` — EPUB 3 from `ArticleContent`: `mimetype` (stored,
  first), container.xml, content.opf, nav.xhtml, single chapter.xhtml,
  downloaded images embedded (jpg/png/gif/webp only).
- `ZipArchiveWriter.swift` — minimal stored-entry ZIP (own CRC32, no deps).
- `MIMEMessage.swift` — multipart/mixed, base64 EPUB attachment, RFC 2047
  subject.
- `SMTPClient.swift` — `SMTPTransport` protocol; EHLO → AUTH PLAIN (LOGIN
  fallback) → MAIL/RCPT/DATA (dot-stuffed) → QUIT. `TLSConnectionTransport` =
  NWConnection implicit TLS. STARTTLS/587 NOT supported (iCloud won't work).
- `KindleSendSettings.swift` — UserDefaults-backed settings: `sendMode`,
  `kindleAddress`, `provider` (gmail/custom), `customHost`, `smtpUsername`,
  fixed `port` 465. `isConfigured(credentials:)`.
- `SendCredentialsStore.swift` — Keychain for the SMTP app password
  (`SendCredentialsStoring`; in-memory mock for tests).

## Model & store

`ReadingListItem`: `sendState` (`queued`/`sent`/`failed`, nil = never),
`dateSent`, `lastSaveAttemptDate` (all `decodeIfPresent` back-compat; mirrored
in `ClipShare/SharedReadingListAppender.swift`). Store mutations:
`setSendState(_:for:)` (stamps `dateSent` on `.sent`),
`recordSaveAttempt(for:) -> Date?` (returns previous press time, defaults to
`dateAdded`), `item(forURLString:)`, `item(withID:)`.

## UI

- `SettingsViewController` "Send to Kindle" section: mode menu button, Kindle
  address / email / app-password field cells (persist on editingDidEnd; password
  in Keychain), provider segmented control (custom shows a host row —
  `sendRows` computed), "Send Test to Kindle" row. Footer covers Gmail app
  passwords + Amazon approved-sender setup.
- `ReadingListViewController`: context menu (long-press) send; subtitle gains
  `sent to Kindle` / `send failed` / `sending…`.

## Constraints

- Kindle accepts mail only from addresses on the user's Approved Personal
  Document E-mail List; the From = `smtpUsername`.
- EPUB is the recommended Send-to-Kindle format; 50 MB cap (article EPUBs are
  far below).
- Direct/unauthenticated email from a phone isn't deliverable (port 25, SPF) —
  hence the embedded authenticated SMTP submission client.

## Tests (`ClipTests/`)

`ZipArchiveWriterTests`, `EpubBuilderTests`, `MIMEMessageTests`,
`SMTPClientTests` (scripted transport), `SavePressPolicyTests` (full gating
matrix), `ArticleSendCoordinatorTests` (mock sender; settings keys snapshotted
and restored), plus send-field cases in `ReadingListStoreTests`.
