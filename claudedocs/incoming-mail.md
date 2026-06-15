# Incoming Email → Reading List

Turns emails from allowed senders into reading-list items. Reuses the
send-to-Kindle Gmail account + app password. Runs on launch/foreground only
(no background fetch).

## Key files (`Clip/Mail/`)

- **`GmailIMAPClient`** (`IMAPFetching`): hand-rolled minimal IMAP4rev1 over
  `NWConnection` TLS to `imap.gmail.com:993`. `LOGIN` (quoted account + app
  password) → `SELECT INBOX` → per-sender `UID SEARCH UID <cursor+1>:* FROM
  "<sender>"` → `UID FETCH (UID BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE)]
  BODY.PEEK[TEXT])` → `UID STORE +FLAGS (\Seen)` (courtesy) → `LOGOUT`.
  Literal-aware command loop (`{n}` byte counts). First run / UIDVALIDITY
  change skips the backlog (cursor = `UIDNEXT - 1`). Pure parsers
  (`trailingLiteralCount`, `parseBracketValue`, `parseSearchUIDs`,
  `parseHeaders`, `extractURLs` incl. HTML `href`) are unit-tested.
- **`IncomingMailSettings`** (App Group `UserDefaults` not needed — standard
  defaults; main-app only): `isEnabled`, `allowedSenders: [String]`, and the
  dedupe cursor `lastUID` + `uidValidity`.
- **`IncomingMailImporter`** (`.shared`): if configured, fetches new mail and
  turns the **first URL** of each message into a reading-list item
  (`store.add` + ingest), then advances the cursor. Coalesces overlapping
  runs. `isConfigured` = enabled + senders + Gmail account + app password.

## Settings

Merged into `Settings → Email & Kindle` (`EmailAndKindleSettingsScreen`): one
shared "Email Account" section (provider + Gmail address + app password) powers
both Send-to-Kindle and import. The "Import from Email" section has the on/off
toggle, an **"Also Send to Kindle"** toggle (`IncomingMailSettings.autoSendToKindle`
— forwards imported articles to Kindle after they're ingested, when Kindle send
is configured), and add/remove allowed senders (swipe to delete).

## URL extraction

Gmail bodies are usually quoted-printable. `GmailIMAPClient.extractURLs` detects
QP (soft break / `=3D`) and fully decodes via `decodeQuotedPrintable` BEFORE
NSDataDetector + href parsing. Decode iterates **Unicode scalars** — Swift
clusters `\r\n` into one `Character`, which would hide the soft break and leave
split URLs broken (the original "imported 0 of N" bug).

## Wiring

`IncomingMailImporter.shared.importNewMail()` is called from
`AppDelegate.didFinishLaunching` and `SceneDelegate.sceneWillEnterForeground`,
and immediately when the toggle is turned on.

## Notes / caveats

- Gmail IMAP is always on (the enable/disable toggle was removed in 2025); an
  **app password** (2-Step Verification) is required — the same one used for
  SMTP send. Plain account passwords don't work over IMAP.
- Dedupe is by highest processed UID per UIDVALIDITY (robust; `\Seen` is only a
  courtesy). The same URL from two emails dedupes at the reading-list layer.
- Live IMAP round-trip can only be verified on a real device with a real Gmail
  app password.
