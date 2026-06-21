# Social Sharing (Friends + CloudKit Messages)

> `MessageBody` cases: `friendAdd`, `readingListItem(urlString,title)`,
> `mediaItem(kind,creator,title)` (URL-less music/podcast — see
> `content-platforms.md`), `priceTracker(PriceTrackerShare)` (a shared price
> tracker — see `price-tracking.md`; `sendPriceTracker` sends it, the receive
> branch recreates it via `share.makeTracker()`), `unknown`.
> `SocialMessageCenter.sendMediaItem` sends the media case; the receive branch
> materializes it via `createURLlessMediaItem`. URL-based platform items share via
> `readingListItem`.

Users get a durable identity (UUID + X25519 encryption keypair + Ed25519
signing keypair) created during first-launch onboarding and stored in the
**iCloud-synchronized Keychain** (survives reinstall, roams devices). Username
(≤20 chars), email, phone are cosmetic profile fields. Friends exchange
identities via QR / `clipreader://` links; messages flow through the CloudKit
**public database** — friend adds are bi-directional and friends can push
articles into each other's reading lists.

## Key files (`Clip/Social/`)

- `UserIdentity.swift` — `UserIdentity` (private half) / `IdentityCard`
  (public half: uuid, username, email?, phone?, both public keys);
  `ProfileValidation` (username 1–20 chars, contact fields ≤60).
- `IdentityStore.swift` — `IdentityStoring`: `loadIdentity`,
  `createIdentity`, `updateProfile`. `KeychainIdentityStore` persists JSON in
  a synchronizable generic-password item (service `com.hpiddy.clip.identity`,
  `kSecAttrSynchronizable`, AfterFirstUnlock); `InMemoryIdentityStore` for tests.
- `FriendsStore.swift` — `friends.json` in the app group (ReadingListStore
  pattern: lock-serialized mutations, `.friendsListChanged`). `add` is
  idempotent by uuid and refreshes profile/keys.
- `FriendLink.swift` — `clipreader://friend?u=<uuid>&n=<name>&ke=<b64url
  x25519>&ks=<b64url ed25519>[&e=<email>&p=<phone>]` codec. Same URL in QR
  codes, shared links, system-camera scans.
- `MessageEnvelope.swift` — `MessageBody`: `friendAdd(IdentityCard)`,
  `readingListItem(urlString:title:)`, `.unknown(type:)` for any
  unrecognized `type` string (ignored — forward compatible).
- `MessageCrypto.swift` — body signed with sender Ed25519 →
  body+signature+senderSigningKey encrypted to recipient X25519 via **HPKE**
  (Curve25519_SHA256_ChachaPoly, info `clip-message-v1`). `open` verifies
  the signature and returns the signer key for the caller's trust decision.
- `MessageTransport.swift` — protocol (`send`/`fetchInbox`/`delete`/
  `ensureSubscription`/`availability`) + `InMemoryMessageTransport` mock.
- `CloudKitMessageTransport.swift` — public DB of `iCloud.com.hpiddy.clip`,
  record type `Message` {`recipientUUID` String (queryable), `senderUUID`
  String, `payload` Bytes}. Delete treats `.unknownItem` as success (two
  devices, one identity). Subscription `inbox-<uuid>`, `.firesOnRecordCreation`,
  silent (`shouldSendContentAvailable`).
- `SocialMessageCenter.swift` — orchestrator. `processInbox()` (serialized):
  fetch → decrypt → route → **delete record**. Routing: `friendAdd` accepted
  trust-on-first-use IF embedded card uuid == record senderUUID AND card
  signing key == actual signer; `readingListItem` accepted ONLY from a stored
  friend whose stored signing key matches the signer → `ReadingListStore.add`
  + ingest (NOT `handleSavePress` — must not trip double-save Kindle logic).
  Ingest runs the SAME shared `IngestPipeline.process` as every other surface
  (Stage 3) — incoming shares unwrap + classify + bound identically; the
  `.friendShare` source keeps a `.product` save silent (no interactive price UI).
  unknown/undecryptable → deleted, ignored. `sendFriendAdd`, `sendArticle`.
- UI: `OnboardingViewController` (gates the app in SceneDelegate when no
  identity), `FriendsViewController` (My Code QR + editable profile + share
  link + friends list + scan; iCloud banner), `QRScannerViewController`
  (AVCaptureMetadataOutput), `SendToFriendSheet` (action sheet: one action
  per friend + "Share Link…" system-sheet fallback; used by reading-list
  context menu AND reader share button), `FriendAddFlow.confirmAndAdd`
  (confirm alert → add → sendFriendAdd; self-add allowed in DEBUG only),
  `ICloudGate.requireICloud` ("iCloud Required" alert with Open Settings).

## Share suggestions (`Social/ShareSuggestionStore.swift`)

Per suggestion key (`ShareSuggestionStore.suggestionKey`): host minus www. for
the web, but **YouTube keys on the channel** (`youtube-channel:<name>`) since the
host is always youtube.com — so streaks are per-channel. YouTube's channel is
only known post-oEmbed, so its `handleNewSave` runs in `ReadingListIngestor`
after ingest (not at save time, where the channel is nil and it no-ops);
`recordManualShare`/`suggestedFriend` resolve the channel from the reading-list
item. Each key tracks: consecutive-share streak to one friend, suppressed set,
always-share set, plus one shared `pendingSuggestion` slot.
- A `pendingSuggestion` may instead be `isSemantic` (armed by the semantic
  index, see `semantic-sharing.md`); those never promote to always-share.
- `recordManualShare` — from `sendArticle(countsAsManualShare: true)` (in-app
  sheet sends, Share Once); same friend streak+1, new friend resets to 1,
  clears that friend's suppression.
- `handleNewSave` — called ONLY for newly saved URLs (`handleSavePress`
  `.saveNew`): returns always-share targets (auto-sent via
  `SocialMessageCenter.autoShare`, which never feeds the streak) and arms
  `pendingSuggestion` when streak ≥ 2 (not suppressed/always).
- Choices (via `SetShareChoiceIntent`): Don't Share = suppress until next
  manual share; Share Once = send + streak; Always Share = auto-share future
  saves of that site.
- Friends screen: friend subtitle lists auto-shared sites; tapping a friend
  opens a sheet with per-site "Stop auto-sharing" + "Reset Share Suggestions"
  (full wipe for that friend).

## Notifications & per-friend settings

- **Push**: silent CKQuerySubscription pushes (`shouldSendContentAvailable`)
  wake the app to drain the inbox; they carry no content (the body is
  encrypted). The distribution build is correctly `aps-environment =
  production` (verified in the exported IPA) — TestFlight push works; debug
  builds use the dev environment. AppDelegate logs register/fail under the
  `push` category for diagnosis.
- **Authorization**: `NotificationManager.requestAuthorization()` at launch —
  required before any notification can appear (silent pushes show nothing on
  their own).
- **Local notifications** (`SocialMessageCenter.notifyOfReceivedShare`, both the
  article and media-item branches): the **first share EVER from a friend always
  notifies**, regardless of the toggle — `NotificationManager.postFirstShare` →
  "{username} shared with you" / "To get notified of future shares from {username},
  go to Queue settings". `FriendNotificationSettings.hasSharedBefore`/`markHasShared`
  track this (separate UserDefaults set). After that first share, it honors the
  per-friend "Notify When They Share" toggle → `NotificationManager.postArticleShared`
  "X shared an article: <title>". Both closures are injected into `SocialMessageCenter`
  for testing. Force-quit apps won't wake on a silent push (Apple limitation) — the
  notification then appears the next time the app runs `processInbox`.
- **Friend detail page** (`FriendDetailViewController`, pushed from a friend
  row): Auto-Send Websites sub-page (`AutoSendWebsitesViewController` —
  per-base-URL toggles over the reading list's hosts, via
  `ShareSuggestionStore.setAlwaysShare`), Notify-When-They-Share switch, and
  Remove Friend (deletes friend + wipes suggestion/notify state).

## Intent donation + share-sheet friend target

- **`ShareIntentDonor`**: on every friend share (`SocialMessageCenter.sendArticle`
  success) donates an outgoing `INSendMessageIntent` (recipient `INPerson` with
  an email>phone>username handle; `conversationIdentifier` = friend UUID). This
  teaches iOS the conversation so friends surface in the system share sheet's
  people row and learns the share habit. Tested: handle preference.
- **Share-sheet target**: the extension declares `IntentsSupported` +
  `NSUserActivityTypes` = `INSendMessageIntent`. Tapping a Queue friend
  suggestion launches the extension with that intent; it reads the conversation
  UUID and queues the URL via `PendingFriendShareStore` (the extension has no
  crypto/CloudKit). The main app's `SocialMessageCenter.drainPendingFriendShares`
  (launch + foreground) performs the real send. Suggestions only appear on a
  physical device.

## Onboarding (`OnboardingFlow`, `OnboardingStepViewController`)

First launch (no identity) runs a 4-step nav flow: username (existing
`OnboardingViewController`, creates identity) → notifications (Enable) → Safari
extension (Open Settings; explains data is local-only) → shortcut/Action Button
(Install Shortcut) → Done. Each step skippable. `AppDelegate` only auto-requests
notification authorization for already-onboarded users, so new users get the
prompt (with context) during the notifications step.

**Small-screen + keyboard handling.** Every onboarding screen is fully scrollable
so 100% of its content (icon/title/body/fields/buttons) is reachable on an
iPhone-mini-sized screen:

- `OnboardingStepViewController` — title/body in a `UIScrollView` that centers when
  content fits and scrolls when it doesn't; primary/continue buttons pinned to the
  bottom safe area (never compressed).
- `OnboardingViewController` (identity entry) — title + username/email/phone fields
  in a `UIScrollView`; the **Continue button is pinned to `view.keyboardLayoutGuide`**
  (priority `.defaultHigh`, capped at the bottom safe area) so it rises just above the
  keyboard while editing and returns when it hides. Keyboard avoidance: observes
  `keyboardWillShow/ChangeFrame/Hide` (`[weak self]`, removed in `deinit`), sets the
  scroll view's bottom content/indicator inset to the keyboard overlap, and scrolls
  the focused field into the still-visible region. A background `UITapGestureRecognizer`
  (`cancelsTouchesInView = false`) ends editing without swallowing field/button taps.
  `textFieldShouldReturn` advances username → email.

The keyboard-frame math (`bottomInset`, `contentOffsetToReveal`) is factored into the
pure `KeyboardAvoidance` enum (`Clip/Social/KeyboardAvoidance.swift`), unit-tested by
`ClipTests/KeyboardAvoidanceTests.swift`. Small-screen layout is asserted by
`OnboardingScreenTests` (`testIdentityStepFitsSmallScreen`, `testSetupStepsFitSmallScreen`,
hosted at 375×812).

## Diagnostics (`Clip/Diagnostics/`)

On-device log capture, because Console.app can't read an iOS-beta device's
log archive on an older macOS (format-version mismatch), and `log collect`
needs root.

- **`DiagnosticLog`** (`DiagnosticLogging` protocol + `.shared`): appends
  timestamped `[category] message` lines to `clip-diagnostics.log` in the App
  Group container. Serialized on a private queue; trimmed to the most recent
  half once it passes `maxBytes` (1 MB). `exportFile()` writes a `.txt` with a
  header (app version/build, iOS version, identity UUID, container) for
  sharing. Survives relaunches and background (push / bg-refresh) wakeups.
- **Instrumented sites** (mirror their `os.Logger` calls): AppDelegate —
  launch, identity + iCloud availability snapshot, remote-notification
  register success/failure, remote notification received, bg-refresh fired/
  expired; `NotificationManager` — authorization granted/error;
  `SocialMessageCenter` — subscription ensured/failed, `processInbox`
  fetched-count/failed, article sent/send-failed, accepted shared article.
- **UI**: Settings → **Diagnostics** (`DiagnosticsViewController`) shows the log
  in a monospaced text view with Share (`UIActivityViewController` over the
  `.txt`) and Clear.
- Tests: `DiagnosticLogTests` (append order, clear, export header+body, size-
  cap trim).

## Recipient-side rules

Incoming `readingListItem`: dropped entirely when the URL is already saved
(no re-ingest, no attribution change). New items record
`sharedByUsername` (sender's username) — shown in the list as "from <name>".

## Flows

- **Add friend**: A scans/opens B's code → confirm alert → A stores B +
  sends `friendAdd(A.card)` to B → B's processInbox adds A. Bi-directional.
- **Share article**: list long-press → "Send to Friend…" or reader share
  button → sheet → seal + `Message` record. Recipient ingests on next
  processInbox if sender is a friend.
- **Inbox drains** on: launch (AppDelegate), foreground (SceneDelegate),
  silent push (`didReceiveRemoteNotification`), pull-to-refresh. Push is
  best-effort (coalesced, dead after force-quit) — polling is authoritative.
- **Push handling = fetch-by-ID, not query.** A silent push (`CKQueryNotification`)
  carries the triggering record's ID, so `processPush` fetches THAT record via
  `database.record(for:)` — **strongly consistent**, so it sees the just-created
  record immediately (no query-index lag, no retry, and no per-device read-delay
  asymmetry from query-index replicas converging at different rates).
  `transport.recordID(fromPush:)` + `fetchRecord(recordID:)`. Falls back to a
  query drain (`processInbox`, which keeps the `[2,4,8]`s retry-on-empty for the
  `bgRefresh`/fallback paths) only if the push had no usable record ID.
- **Do NOT set `CKSubscription.NotificationInfo.desiredKeys`** — including the
  Bytes `payload` field makes CloudKit reject the subscription with `CKError
  12/2018 "unsupported field type in notification"`. (The encrypted payload
  can't ride an APNs push anyway; that's why we fetch by ID instead.)
- **First-run CloudKit gotcha (resolved):** creating the query subscription in
  the **production** container fails with `CKError 2006 "attempting to create a
  subscription in a production container"` until the subscription *shape*
  (record type + predicate fields + options — value-agnostic) has been
  registered in **Development** and deployed Dev→Prod once. After that, every
  client creates its own `inbox-<uuid>` at runtime with no further steps. The
  shape was bootstrapped by running a dev-signed build once; see the
  `clip-weblink-reader` memory for the exact recovery steps.

## Wiring

- `Info.plist`: `CFBundleURLTypes` scheme `clipreader`; `UIBackgroundModes`
  audio + `remote-notification`; camera usage string covers QR scanning.
- `Clip.entitlements`: iCloud container `iCloud.com.hpiddy.clip` + CloudKit
  service + `aps-environment` (+ existing app group).
- Deployment target: **iOS 26.0** all targets (no iOS-27-only APIs; gate any
  future ones with `#available(iOS 27)`).

## CloudKit ops (NOT in code — Console steps)

The container `iCloud.com.hpiddy.clip` was created by automatic signing
during the build-20 archive. Before messaging works:

1. One-time token: `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app xcrun cktool save-token --type management`
   (opens the Console token page; human step).
2. Import the prepared schema (`claudedocs/cloudkit-schema.ckdb` — record
   type, queryable indexes on `recipientUUID` + `recordID`, `_icloud`
   Create+Write grant) into BOTH environments:
   `xcrun cktool import-schema --team-id MM5QBNLXR6 --container-id iCloud.com.hpiddy.clip --environment development --file claudedocs/cloudkit-schema.ckdb`
   then `--environment production`. (If the GRANT lines are rejected by an
   older cktool, set Security Roles in the Console instead: `_icloud` =
   Create + Write on `Message`.)
3. Note: TestFlight uses the **production** environment; debug builds use
   development — the two can't message each other.

## Intents (orthogonal change, same round)

`ClipSafariPageIntent` / `SaveLinkIntent` now return
`some IntentResult & ReturnsValue<String?>`: the saved URL (also for ignored
duplicates — it's in the list), nil if the 12 s intent timeout hit first;
hard failures still throw.

## Tests

`MessageCryptoTests`, `MessageEnvelopeTests`, `FriendLinkTests`,
`FriendsStoreTests`, `SocialMessageCenterTests` (mock transport; full routing
matrix), `IdentityStoreTests`.
