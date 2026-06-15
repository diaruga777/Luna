# Incoming Email → Reading List

Turns emails from allowed senders (or matching subject filters) into
reading-list items. Reuses the send-to-Kindle Gmail account + app password.
Runs on launch/foreground AND on a background schedule (so newsletters reach
Kindle even if the app is never opened).

## Key files (`Clip/Mail/`)

- **`GmailIMAPClient`** (`IMAPFetching`): hand-rolled minimal IMAP4rev1 over
  `NWConnection` TLS to `imap.gmail.com:993`. `LOGIN` (quoted account + app
  password) → `SELECT INBOX` → per-sender `UID SEARCH UID <cursor+1>:* FROM
  "<sender>"` AND per-filter `… SUBJECT "<phrase>"` (results unioned, deduped)
  → `UID FETCH (UID BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE CONTENT-TYPE
  CONTENT-TRANSFER-ENCODING)] BODY.PEEK[TEXT])` → `UID STORE +FLAGS (\Seen)`
  (courtesy) → `LOGOUT`. Literal-aware command loop (`{n}` byte counts). First
  run / UIDVALIDITY change skips the backlog (cursor = `UIDNEXT - 1`). Pure
  parsers (`trailingLiteralCount`, `parseBracketValue`, `parseSearchUIDs`,
  `newSearchUIDs`, `parseHeaders`, `extractURLs` incl. HTML `href`) are
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
  author + `channelName`); body via `MIMEBody` then the readability extractor
  (HTML) or plain-text paragraphs, with footer junk trimmed.
- **`IncomingMailSettings`** (standard defaults; main-app only): `isEnabled`,
  `allowedSenders: [String]`, `subjectFilters: [String]` (case-insensitive
  substring, e.g. "Money Stuff"), `autoSendToKindle`, and the dedupe cursor
  `lastUID` + `uidValidity`.
- **`IncomingMailImporter`** (`.shared`): if configured, fetches new mail and
  saves each message **as an article** (the email body IS the content;
  `clipmail://<uid>` item + `saveContent`), falling back to the first URL when
  there's no usable body. Forwards to Kindle when `autoSendToKindle`. Advances
  the cursor. Coalesces overlapping runs. `isConfigured` = enabled + (senders
  OR subject filters) + Gmail account + app password.

## Settings

Merged into `Settings → Email & Kindle` (`EmailAndKindleSettingsScreen`): one
shared "Email Account" section (provider + Gmail address + app password) powers
both Send-to-Kindle and import. "Import from Email" section: on/off toggle,
**"Also Send to Kindle"** toggle (`autoSendToKindle`), add/remove allowed
senders (swipe to delete). A separate **"Subject Filters"** section adds/removes
fuzzy subject phrases (swipe to delete).

## Background delivery

`AppDelegate` registers two `BGTaskScheduler` tasks: the existing
`com.hpiddy.clip.inboxRefresh` (`BGAppRefreshTask`, ~15 min — now also imports
mail) and `com.hpiddy.clip.mailFetch` (`BGProcessingTask`, ~12 h,
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
- Dedupe is by highest processed UID per UIDVALIDITY (robust; `\Seen` is only a
  courtesy). The same URL from two emails dedupes at the reading-list layer.
- Live IMAP round-trip can only be verified on a real device with a real Gmail
  app password.
