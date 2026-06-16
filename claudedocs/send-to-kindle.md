# Send to Ereaders (Kindle & Boox)

Background delivery of saved articles to an ereader. The article is rendered to
EPUB on-device once, then delivered to each configured destination:

- **Kindle** — emailed to the user's `@kindle.com` address through their own SMTP
  account (Gmail app password or custom host, implicit TLS port 465 only).
- **Boox** — uploaded to the user's Onyx account via the **unofficial** Send2Boox
  service; the device pulls it over WiFi. See "Boox" below.

No UI taps needed once configured.

## Destinations

`ArticleDestination` (`Clip/Send/ArticleSendCoordinator.swift`) abstracts a
target: `id` (`ArticleDestinationID.kindle` / `.boox`), `displayName`,
`isConfigured`, `sendMode` (`ArticleSendMode`), and `send(epubData:fileName:title:)`.
`KindleDestination` wraps `SMTPArticleEmailSender`; `BooxDestination` wraps
`Send2BooxClient`. `ArticleSendCoordinator` holds `[ArticleDestination]` and is
destination-agnostic.

## Gating (save-press state machine)

All save entry points (`ClipSafariPageIntent`, `SaveLinkIntent`, in-app add)
funnel through `ReadingListIngestor.handleSavePress(urlString:)`:

1. URL not in list → save + ingest.
2. URL already in list AND previous press < 12 s ago → send to every
   destination currently in `.doubleSave` mode that hasn't been sent in the past
   24 h (`SavePressPolicy.Decision.sendToEreaders(destinationIDs:)`).
3. Any other press on an existing URL → ignored entirely (no re-ingest).

Decision logic is pure: `SavePressPolicy.decide(…, doubleSaveDestinationIDs:)`
where the caller supplies `ArticleSendCoordinator.doubleSaveDestinationIDs()`.
Modes (`ArticleSendMode`): `off` / `allSaves` (send after every ingestion) /
`doubleSave`. Long-press a reading-list row → "Send to Kindle" / "Send to Boox"
context-menu rows, each shown only when that destination is configured.

## Coordinator

`ArticleSendCoordinator.swift`:
- `send(_:toDestinationID:)` — explicit single-destination send (context menu).
- `articleBecameReady(_:)` (called by the ingestor post-`saveContent`) — per
  destination, fires queued sends and, in `allSaves` mode, everything new.
- `retryPendingSends()` — pull-to-refresh; per destination retries `.queued`/`.failed`.
- `sendTestDocument(toDestinationID:)` — backs each settings test row.
- EPUB built once per delivery; in-flight dedup keyed `"<itemID>|<destID>"`;
  `.queued` written first so a mid-send process death is retried.

## Boox (Send2Boox — unofficial)

Ported from `hrw/onyx-send2boox`. Files in `Clip/Send/Boox/`:
- `BooxAuthClient.swift` — OTP login: `users/sendMobileCode` (request code) →
  `users/signupByPhoneOrEmail` (code → long-lived token). Token in Keychain.
- `Send2BooxClient.swift` — `upload(epubData:fileName:title:)`: `users/me` (uid) →
  `users/getDevice` + `im/getSig` (best-effort session pings, mirroring the
  reference) → `config/buckets` (bucket + OSS endpoint) → `config/stss` (OSS STS
  creds) → **signed OSS PUT** of the EPUB to `<uid>/push/<uuid>.epub` →
  `push/saveAndPush` (registers the object; `resourceType` is `"txt"` to match
  the reference). `BooxDestination` is the `ArticleDestination`.
- `BooxAPIClient.swift` — `https://{host}/api/1/{path}`; Bearer token; a JSON body
  implies POST; decodes the `{data:…}` envelope. Response models incl. tolerant
  string-or-int `uid`.
- `OSSRequestSigner.swift` — Alibaba OSS **V1 HMAC-SHA1** request signing
  (StringToSign = VERB\n\nContent-Type\nDate\nCanonicalizedOSSHeaders +
  CanonicalizedResource; `x-oss-security-token` header; virtual-hosted URL).
- `BooxSendSettings.swift` — `sendMode`, `accountIdentity`, `region`
  (eur.boox.com / send2boox.com), `isConfigured` (token present).

**CAVEAT (unverified):** Send2Boox is unofficial and the OSS signing is
reproduced by hand (the reference used the `oss2` SDK). It is NOT validated
against a live Onyx account/device — gated behind explicit setup with an in-app
disclosure; a friend tests post-publication. Known risk: `URLSession` may strip
the signed `Date` header (→ switch to a presigned URL if uploads 403).

## Other shared send files (`Clip/Send/`)

- `EpubBuilder.swift` — EPUB 3 from `ArticleContent` (mimetype stored first,
  container.xml, content.opf, nav.xhtml, one chapter.xhtml, embedded jpg/png/gif/webp).
- `ZipArchiveWriter.swift` — minimal stored-entry ZIP (own CRC32, no deps).
- `MIMEMessage.swift` — multipart/mixed, base64 EPUB, RFC 2047 subject.
- `SMTPClient.swift` — `SMTPTransport`; EHLO → AUTH PLAIN (LOGIN fallback) →
  MAIL/RCPT/DATA → QUIT; `TLSConnectionTransport` = NWConnection implicit TLS
  (30 s timeout + cancellation). STARTTLS/587 NOT supported.
- `KindleSendSettings.swift` — Kindle SMTP settings; `SendMode` is a typealias of
  `ArticleSendMode`.
- `SendCredentialsStore.swift` — Keychain for the SMTP password AND the Boox token
  (`smtpPassword`/`booxToken`; in-memory mock for tests).

## Model & store

`ReadingListItem`: `sendStates: [String: SendState]` and `datesSent: [String: Date]`
keyed by destination id (`sendState(for:)` / `dateSent(for:)` helpers). A Codable
migration folds the legacy single `sendState`/`dateSent` under `"kindle"`.
`ReadingListStore.setSendState(_:for:destination:)` stamps `datesSent[destination]`
on `.sent`.

## UI

- Settings → "Email & Kindle" (mode, address/account fields, test) and a separate
  "Send to Boox" screen (`BooxSettingsScreen`: region, OTP login/logout, mode,
  test send, unofficial-API disclosure footer).
- `ReadingListViewController`: per-destination context-menu rows; subtitle shows
  `sent to Kindle` / `Boox send failed` / `sending to …` per destination.

## Tests (`ClipTests/`)

`ZipArchiveWriterTests`, `EpubBuilderTests`, `MIMEMessageTests`, `SMTPClientTests`,
`SavePressPolicyTests` (per-destination eligibility matrix), `ArticleSendCoordinatorTests`
(multi-destination fan-out via a mock destination), `OSSRequestSignerTests`
(canonicalization + signing), `BooxClientTests` (auth + upload happy-path via a
mock `URLProtocol`), plus send-state + legacy-migration cases in `ReadingListStoreTests`.
