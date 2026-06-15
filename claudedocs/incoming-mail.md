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

`Settings → Import from Email` (`IncomingMailSettingsScreen`): on/off toggle +
add/remove allowed sender addresses (swipe to delete). Footer warns if the
Send-to-Kindle account isn't set up.

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
