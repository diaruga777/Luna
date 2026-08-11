# Social Sharing (Contacts via Email)

Contact sharing is **email-based** (no CloudKit, no separate identity/crypto
system). A contact is
just an email address; sharing an item sends a nicely-formatted email that a
recipient's Luna app recognizes and imports.

**Only the apps that do email have it**: `LunaApp.sharesByEmail` — the central
**Luna** app and **Luna Reader**. **Downloader** and **Price Tracker** share a save
as a plain URL through the system share sheet instead, so they show no Contacts
button or settings row, offer no "Send to Contact…" row action, connect no account,
and run no mail import (see `claudedocs/incoming-mail.md`). Everything below
therefore describes those two apps. An account connected in either is visible to
both — the metadata lives in App Group defaults and the secret in the shared
App-Group keychain access group.

## Key files

- **`LunaSocial/FriendsStore.swift`** — `Friend` (`email` [the stable
  identifier, lowercased], optional `name`, `dateAdded`, `notifyOnEveryShare`,
  `hasReceivedShare`, `isBlocked`). `FriendsStore` persists `friends.json` in the App Group
  container with coordinated load-mutate-save transactions and posts
  `.friendsListChanged`. `add` is idempotent by email and updates the name;
  `markReceivedShare` tracks whether a contact's first share has landed yet (so
  it can always notify once). Active and blocked projections feed separate UI
  sections and recipient pickers.
- **`LunaSocial/PendingRequestsStore.swift`** — `PendingRequest` (sender email/
  name, url, title, advisory `ContentKind` string, provider message id, date).
  Persists legacy `pendingRequests.json` entries in the App Group container.
  The queue remains visible so requests created by older builds can be handled,
  but new recognized senders are added to Contacts and imported automatically.
- **`LunaSocial/NotificationManager.swift`** — local notifications only (no
  remote push/APNs): `postShareReceived` (a contact import landed) and
  `postPriceDrop`. Legacy pending-request notification routing remains so
  notifications delivered by older builds still open the preserved queue.
  `clearShareNotifications()` removes delivered "share received" notifications
  once the user reaches the reading list.
- **`LunaMailAccount/LunaShareMarker.swift`** — the machine-readable marker
  stamped on every share email: schema version, url, title, advisory `kind`,
  sender display name. Carried two ways for robustness — an `X-Luna-Share`
  header (base64 JSON) and a hidden `<div>` block in the HTML body as a
  fallback if a provider strips custom headers.
- **`LunaReadingList/EmailShareCenter.swift`** — `EmailShareCenter.shared.send(item:to:)`
  / `.share(urlString:title:to:)`: validates/normalizes recipient addresses,
  renders the item as a full article (`EmailContentRenderer.renderArticle`,
  inline images) or a compact card (`renderCard` — hero image from a price
  snapshot/thumbnail, detail lines for a tracked price), builds the raw
  MIME with the `X-Luna-Share` header via `EmailMIMEBuilder`, and sends through
  the connected account's `EmailTransport` (`MailTransportFactory.make`).
  Records every recipient as a contact on send.
- **`LunaReadingList/IncomingMailImporter.swift`** (see `incoming-mail.md` for
  the IMAP/mail-fetch mechanics) — `handleLunaShare` parses the marker off an
  incoming message, ignores blocked senders, automatically adds new recognized
  senders to Contacts (except the connected account's own address), and imports
  through the normal pipeline. Each item stores the sender email for live name
  resolution plus the From-header name as a fallback.

## UI (`LunaSocialUI/`, shared by all three apps)

- **`FriendsViewController`** — presented to users as **Contacts** from the
  top-level Settings page. It shows separate Contacts and Blocked sections,
  a badged legacy Pending Requests entry, and "Add by Email" / "Add from Phone
  Contacts" (`CNContactPickerViewController` — no Contacts permission needed).
  Tapping a contact pushes `FriendDetailViewController` (rename,
  notify-on-every-share, block/unblock, remove).
- **`PendingRequestsViewController`** — the moderation queue. Tapping a
  request offers "Add Contact & Import" (adds sender to `FriendsStore` +
  imports), "Import Once" (imports without adding as a friend), or "Delete".
- **`RecipientPickerViewController`** — the full recipient picker: multi-select
  from active contacts, "Enter email address…", or "Add from Phone Contacts". Returns the
  chosen addresses to `EmailShareCenter`.
- **`RecentFriendRecipientsStore`** — records successful sent-to addresses in
  App Group JSON (`recentFriendRecipients.json`), newest first, for quick send.
- **`SendToFriendSheet`** / **`ReaderShareSheet`** — "Send to Contact" first
  shows a bottom sheet with up to 5 recent sent-to emails plus "Other…" for the
  full picker. With no past sends, it skips straight to the full picker.

## Notifications

Local only (`UNUserNotificationCenter`, no APNs/remote push — the old CloudKit
silent-push wake-up is gone). `NotificationManager.requestAuthorization()` is
called at launch. Tapping a "share received" notification just opens the app;
these are cleared once the user reaches the reading list
(`CardCarouselHostViewController.viewDidAppear` → `NotificationManager.clearShareNotifications()`, so every app's deck root clears them).
Tapping a "pending request" notification should route to
`PendingRequestsViewController` (see `AppDelegate`/`SceneDelegate` routing).

## Wiring

- Sharing Account (any provider) is set up once via `EmailLoginFlow` (see
  `incoming-mail.md`) and powers import, friend sharing, AND Send-to-Kindle
  from one connected account — Settings → "Email".
- No App-Group-only queuing needed for extensions: the Share/Action
  extensions don't send friend emails themselves (`EmailShareCenter` is
  main-app only); they queue through the normal share-sheet/URL ingest path.
- New email imports use capture source `.email`; `.friendShare` remains
  decodable for items written by older builds. Incoming sender fields drive
  send-by-source rules (see `send-to-kindle.md`) and the reading list's
  "From <name>" attribution.

## Tests

`FriendsStoreTests`, `PendingRequestsStoreTests`, `LunaShareMarkerTests`,
`SourceSendSettingsTests` (per-friend override matrix), plus
`SocialAndSeederTests` and `CaptureSourceCodableTests` for the broader
capture-source plumbing.
