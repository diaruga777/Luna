# Social Sharing (Friends + CloudKit Messages)

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
  + ingest (NOT `handleSavePress` — must not trip double-save Kindle logic);
  unknown/undecryptable → deleted, ignored. `sendFriendAdd`, `sendArticle`.
- UI: `OnboardingViewController` (gates the app in SceneDelegate when no
  identity), `FriendsViewController` (My Code QR + editable profile + share
  link + friends list + scan; iCloud banner), `QRScannerViewController`
  (AVCaptureMetadataOutput), `SendToFriendSheet` (action sheet: one action
  per friend + "Share Link…" system-sheet fallback; used by reading-list
  context menu AND reader share button), `FriendAddFlow.confirmAndAdd`
  (confirm alert → add → sendFriendAdd; self-add allowed in DEBUG only),
  `ICloudGate.requireICloud` ("iCloud Required" alert with Open Settings).

## Flows

- **Add friend**: A scans/opens B's code → confirm alert → A stores B +
  sends `friendAdd(A.card)` to B → B's processInbox adds A. Bi-directional.
- **Share article**: list long-press → "Send to Friend…" or reader share
  button → sheet → seal + `Message` record. Recipient ingests on next
  processInbox if sender is a friend.
- **Inbox drains** on: launch (AppDelegate), foreground (SceneDelegate),
  silent push (`didReceiveRemoteNotification`), pull-to-refresh. Push is
  best-effort (coalesced, dead after force-quit) — polling is authoritative.

## Wiring

- `Info.plist`: `CFBundleURLTypes` scheme `clipreader`; `UIBackgroundModes`
  audio + `remote-notification`; camera usage string covers QR scanning.
- `Clip.entitlements`: iCloud container `iCloud.com.hpiddy.clip` + CloudKit
  service + `aps-environment` (+ existing app group).
- Deployment target: **iOS 26.0** all targets (no iOS-27-only APIs; gate any
  future ones with `#available(iOS 27)`).

## CloudKit ops (NOT in code — Console steps)

1. Dev env: run a debug build once (just-in-time schema), then verify/add
   **queryable indexes** on `recipientUUID` and `recordID` for `Message`.
2. Security Roles: grant **`_icloud` Create + Write** on `Message` (Write
   includes delete — recipients must delete senders' records; default
   `_creator`-only Write breaks the flow with permissionFailure).
3. **Deploy Schema Changes to Production** before TestFlight (prod has no
   just-in-time schema; debug ↔ TestFlight builds can't message each other —
   different environments).

## Intents (orthogonal change, same round)

`ClipSafariPageIntent` / `SaveLinkIntent` now return
`some IntentResult & ReturnsValue<String?>`: the saved URL (also for ignored
duplicates — it's in the list), nil if the 12 s intent timeout hit first;
hard failures still throw.

## Tests

`MessageCryptoTests`, `MessageEnvelopeTests`, `FriendLinkTests`,
`FriendsStoreTests`, `SocialMessageCenterTests` (mock transport; full routing
matrix), `IdentityStoreTests`.
