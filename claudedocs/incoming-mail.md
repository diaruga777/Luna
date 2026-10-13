# Incoming Email → Saves

Turns emails from allowed senders (or matching subject filters) into
saved items. Reuses the send-to-Kindle Gmail account + app password.
Runs on launch/foreground AND on a background schedule (so newsletters reach
Kindle even if the app is never opened).

Only in the apps that do email at all (`LunaApp.sharesByEmail`: the central
**Luna** app and **Luna Reader**). Downloader and Price Tracker connect no account,
so they neither import mail on launch/foreground/pull-to-refresh nor register the
mail-fetch background task — see `claudedocs/social-sharing.md`. Each importing app
still KEEPS only its own kinds from what it imports.

## Key files (`Luna/Mail/`)

- **`GmailIMAPClient`**: a pure IMAP/RFC822 parser bag now — the hand-rolled
  `NWConnection` IMAP client that used to live here was superseded by
  `StreamIMAPClient` (`LunaMailTransport`, over a `URLSessionStreamTask` with
  implicit TLS + STARTTLS) and removed; only its unit-tested parsers and
  `IncomingMessage` remain. **`StreamIMAPClient`** is the live transport:
  `LOGIN` (quoted account + app password) → `SELECT INBOX` → per-sender
  `UID SEARCH CHARSET UTF-8 UID <cursor+1>:* FROM {n}` AND per-filter `…
  SUBJECT {n}` (UTF-8 literals sent only after the server continuation) (results unioned, deduped) → `UID FETCH
  (UID BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE CONTENT-TYPE
  CONTENT-TRANSFER-ENCODING)] BODY.PEEK[TEXT])` → `UID STORE +FLAGS (\Seen)`
  (courtesy) → `LOGOUT`. Literal-aware command loop (`{n}` byte counts). First
  run / UIDVALIDITY change skips the backlog (cursor = `UIDNEXT - 1`).
  `GmailIMAPClient`'s pure parsers (`trailingLiteralCount`, `parseBracketValue`,
  `parseSearchUIDs`, `newSearchUIDs`, `parseHeaders`, `extractURLs` incl.
  HTML `href`) are
  unit-tested.
  - **`newSearchUIDs(lines, afterUID:)`** filters search results to UIDs
    strictly `> afterUID`. CRITICAL: `UID SEARCH UID N:*` returns the highest
    existing UID even when it's ≤ N (the range is order-independent, `*` = last
    message), so without this the newest message re-imports on every poll.
- **`MIMEBody`**: walks a `BODY[TEXT]` MIME tree (using the top-level
  Content-Type boundary + Content-Transfer-Encoding) to the richest text part —
  prefers `text/html`, falls back to `text/plain`, recurses nested multipart,
  decodes base64 / quoted-printable. Newsletters are almost always
  `multipart/alternative` carrying a base64 `text/html` part; the raw blob is
  unreadable without this.
- **`MailArticleBuilder`**: email → `ArticleContent` (subject → title, sender →
  author + `senderName`); body via `MIMEBody` then the readability extractor
  (HTML) or plain-text paragraphs, with footer junk trimmed.
- **`IncomingMailSettings`** (standard defaults; main-app only): `isEnabled`,
  `allowedSenders: [String]`, `subjectFilters: [String]` (case-insensitive
  substring, e.g. "Money Stuff"), `autoSendToKindle`, and the dedupe cursor
  `lastUID` + `uidValidity`.
- **`IncomingMailImporter`** (`.shared`): if configured, fetches new mail and
  routes each message by whether it's a Luna share (carries the
  `X-Luna-Share` marker, recovered from the header or a hidden HTML body
  block — see `social-sharing.md`) vs. a generic newsletter match
  (`allowedSenders`/`subjectFilters`):
  - **Marked Luna share**: imported straight from `marker.url` through the
    normal silent ingest pipeline (real article/video/product/etc., not the
    rendered email). A recognized sender is automatically added to Contacts,
    using the From-header name; the connected account's own address is never
    added as a contact.
  - **`via Lu\u{200C}na:` subject but no recoverable marker** (provider stripped
    the header, or a long article's trailing marker block got clipped by the
    mail fetch size cap) — `importUnmarkedLunaShare`: extracts the
    original-content URL embedded in the body and tries the same silent
    (non-CAPTCHA) resolution; only when that URL is missing or the page needs
    an interactive CAPTCHA does it fall back to saving the email's own rendered
    body as an article. Either way the Luna subject prefix is stripped before
    it can reach a saved title.
  - **Everything else (generic newsletter match)**: saved **as an article**
    (the email body IS the content; `lunamail://<message-key>` item + `saveContent`),
    falling back to the first URL when there's no usable body.
  Before routing, mail from a blocked contact is marked read and ignored.
  Imported items retain the normalized sender email as well as the parsed
  fallback name. Reader cards resolve that email through Contacts at display
  time, so renaming a contact immediately updates the card's “From …” label.
  Items are tagged `captureSource: .email`; auto-send is then handled by
  `ArticleSendCoordinator.saveBecameReady` per the destination's
  email-source setting (Kindle's reuses `autoSendToKindle`; see
  send-to-kindle.md → "Auto-send by capture source"). Advances the cursor.
  Coalesces overlapping runs. Its `isConfigured` gate means the shared account
  is connected and ready (`EmailAccountStore.isReady`).
  A definite IMAP/Graph authentication rejection is persisted by the transport
  as `EmailAccountStore.authenticationIssue`; subsequent background imports
  pause (`accountStore.isReady == false`) until Settings → Email reconnects the
  account. Connectivity and server failures do not mark the login invalid.

## Settings

Grouped under `Settings → Email` (`EmailAndKindleSettingsScreen`): the
one connected "Sharing Account" (any provider) powers friend sharing, import,
and Send to Kindle. "Import from Email" section: on/off toggle, **"Also Send to
Kindle"** toggle (`autoSendToKindle`), add/remove allowed senders (swipe to
delete). A separate **"Subject Filters"** section adds/removes fuzzy subject
phrases (swipe to delete).

If that account's credential expires or is revoked, the Sharing Account section
keeps the address visible and adds the authentication error plus **Reconnect
Email**. The top-level Email settings row also says “Sign-in required,” and the
Settings → Email & Sending exposes the recovery state and reconnect action.

## Background delivery

`AppDelegate` registers two `BGTaskScheduler` tasks: the existing
`com.hsanabria.luna.inboxRefresh` (`BGAppRefreshTask`, ~15 min — now also imports
mail) and `com.hsanabria.luna.mailFetch` (`BGProcessingTask`, ~12 h,
`requiresNetworkConnectivity`) dedicated to mail import + Kindle forwarding.
Both identifiers are in `Info.plist` `BGTaskSchedulerPermittedIdentifiers`;
`UIBackgroundModes` includes `fetch` + `processing`. iOS schedules these
opportunistically — there's no true cron, so cadence is best-effort.

## URL extraction

Gmail bodies are usually quoted-printable. `GmailIMAPClient.extractURLs` detects
QP (soft break / `=3D`) and fully decodes via `decodeQuotedPrintable` BEFORE
NSDataDetector + href parsing. Decode iterates **Unicode scalars** — Swift
clusters `\r\n` into one `Character`, which would hide the soft break and leave
split URLs broken (the original "imported 0 of N" bug).

## Wiring

`IncomingMailImporter.shared.importNewMail()` is called from
`AppDelegate.didFinishLaunching`, `SceneDelegate.sceneWillEnterForeground`, the
two background tasks above, and immediately when the toggle is turned on.

## Notes / caveats

- Gmail IMAP is always on (the enable/disable toggle was removed in 2025); an
  **app password** (2-Step Verification) is required — the same one used for
  SMTP send. Plain account passwords don't work over IMAP.
- Automatic polls use the highest processed UID per UIDVALIDITY; durable
  `processed_mail` receipts in `saves.sqlite` dedupe both automatic and recent
  scans (`\Seen` is only a courtesy). The same URL from two emails dedupes at the saves layer.
- Live IMAP round-trip can only be verified on a real device with a real Gmail
  app password.

## Pull Recent Emails

Settings → Email → Import from Email includes **Pull Recent Emails**. It reapplies
current sender and subject filters, plus the built-in Luna-share searches, to the
past seven days (starting at midnight UTC seven days ago; IMAP SINCE has date-only
precision). IMAP searches INBOX; Outlook searches the account's messages and
follows Graph pagination. Read mail is included. A connected, ready account is
required; the action is explicit and also works when automatic newsletter import
is off. The row shows progress, then a processed/skipped summary or the fetch error.
Overlapping automatic checks coalesce; a manual action during a check asks the user
to retry after it finishes.

Recent scans do not reset or advance the automatic cursor, so applying a newly
added filter can recover older mail without skipping another automatic match.
Both paths share the importer and persistent SQLite processing receipts (schema
18), independent of saved-item deletion. Receipt keys include the account/provider
and IMAP host, then Message-ID when available, otherwise the provider ID plus
IMAP UIDVALIDITY. Synthetic email URLs use the same hashed key. Existing ready
`lunamail://<provider-id>` imports are recognized for compatibility. URL-based
shares still dedupe through `addIfAbsent`. Receipts are written after processing;
failed fetches/saves leave the automatic cursor untouched and retryable. Repeated
pulls do not rewrite articles or trigger their readiness/auto-send hook again.

## October 2026 search rejection

The supplied build-129 diagnostics show a successful initial cursor anchor at
2026-10-13 09:34 UTC, followed by `a4 BAD Could not parse command` on every later
poll, beginning at 17:53 UTC (04:53 Sydney time on October 14). In the command
sequence, a4 is the built-in Luna SUBJECT fallback, before user sender/subject
filters. Its `via Lu\u{200C}na:` prefix contains non-ASCII bytes, which the old
client placed in an IMAP quoted string without a charset. RFC 3501 quoted strings
allow only 7-bit characters. Searches now specify CHARSET UTF-8 and use byte-counted
synchronizing literals, including the server continuation handshake. This fix
covers the built-in prefix and non-ASCII user filters.
