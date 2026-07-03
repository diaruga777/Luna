# Social Sharing (Friends via Email)

Friend sharing is **email-based**, universal across all three apps (no
CloudKit, no separate identity/crypto system, no per-app gating). A friend is
just an email address; sharing an item sends a nicely-formatted email that a
recipient's Luna app recognizes and offers to import.

## Key files

- **`LunaSocial/FriendsStore.swift`** — `Friend` (`email` [the stable
  identifier, lowercased], optional `name`, `dateAdded`, `notifyOnEveryShare`,
  `hasReceivedShare`). `FriendsStore` persists `friends.json` in the App Group
  container (`ReadingListStore` pattern: lock-serialized mutations, posts
  `.friendsListChanged`). `add` is idempotent by email and updates the name;
  `markReceivedShare` tracks whether a friend's first share has landed yet (so
  it can always notify once).
- **`LunaSocial/PendingRequestsStore.swift`** — `PendingRequest` (sender email/
  name, url, title, advisory `ContentKind` string, provider message id, date).
  Persists `pendingRequests.json` in the App Group container. A moderation
  queue for Luna shares from senders who aren't yet an accepted friend —
  guards against importing from arbitrary senders. Deduped by
  (url, senderEmail).
- **`LunaSocial/NotificationManager.swift`** — local notifications only (no
  remote push/APNs): `postShareReceived` (friend's import landed),
  `postPendingRequest` (stranger's share needs review), `postPriceDrop`.
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
  snapshot/thumbnail, detail lines for creator/media title), builds the raw
  MIME with the `X-Luna-Share` header via `EmailMIMEBuilder`, and sends through
  the connected account's `EmailTransport` (`MailTransportFactory.make`).
  Records every recipient as a friend on send (the user chose them, so no
  moderation needed outbound).
- **`LunaReadingList/IncomingMailImporter.swift`** (see `incoming-mail.md` for
  the IMAP/mail-fetch mechanics) — `handleLunaShare` parses the marker off an
  incoming message and routes by sender: an accepted friend → `autoImport`
  (adds to the reading list tagged `source: .email`, sets `channelName` to the
  friend's display name, ingests, marks `hasReceivedShare`/notifies per the
  friend's `notifyOnEveryShare` toggle); anyone else → `queuePending` (adds a
  `PendingRequest`, posts a "wants to share with you" notification, does NOT
  import). The originating mail is marked read either way — accepting later is
  a purely local decision.

## UI (`LunaSocialUI/`, shared by all three apps)

- **`FriendsViewController`** — friends list (swipe to delete), a badged entry
  to Pending Requests when any are queued, "Add by Email" / "Add from
  Contacts" (`CNContactPickerViewController` — no Contacts permission needed).
  Tapping a friend pushes `FriendDetailViewController` (notify-on-every-share
  toggle, remove).
- **`PendingRequestsViewController`** — the moderation queue. Tapping a
  request offers "Add Friend & Import" (adds sender to `FriendsStore` +
  imports), "Import Once" (imports without adding as a friend), or "Delete".
- **`RecipientPickerViewController`** — used from the reader share sheet /
  reading-list context menu to pick send targets: multi-select from friends,
  "Enter email address…", or "Add from Contacts". Returns the chosen addresses
  to `EmailShareCenter`.
- **`SendToFriendSheet`** / **`ReaderShareSheet`** — present the recipient
  picker from the reading-list long-press menu and the reader's share button
  respectively.

## Notifications

Local only (`UNUserNotificationCenter`, no APNs/remote push — the old CloudKit
silent-push wake-up is gone). `NotificationManager.requestAuthorization()` is
called at launch. Tapping a "share received" notification just opens the app;
these are cleared once the user reaches the reading list
(`ReadingListViewController` → `NotificationManager.clearShareNotifications()`).
Tapping a "pending request" notification should route to
`PendingRequestsViewController` (see `AppDelegate`/`SceneDelegate` routing).

## Wiring

- Sharing Account (any provider) is set up once via `EmailLoginFlow` (see
  `incoming-mail.md`) and powers import, friend sharing, AND Send-to-Kindle
  from one connected account — Settings → "Email & Sending".
- No App-Group-only queuing needed for extensions: the Share/Action
  extensions don't send friend emails themselves (`EmailShareCenter` is
  main-app only); they queue through the normal share-sheet/URL ingest path.
- Capture source `.friendShare` (`CaptureSource` in `LunaModels`) marks items
  that arrived via `autoImport`/`queuePending`-then-accept, so send-by-source
  rules (see `send-to-kindle.md`) and the reading list's "from <name>"
  attribution can key off it.

## Tests

`FriendsStoreTests`, `PendingRequestsStoreTests`, `LunaShareMarkerTests`,
`SourceSendSettingsTests` (per-friend override matrix), plus
`SocialAndSeederTests` and `CaptureSourceCodableTests` for the broader
capture-source plumbing.
