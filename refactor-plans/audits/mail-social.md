# Mail / Social audit

Scope: `LunaLibraries/Sources/{LunaMail,LunaMailAccount,LunaMailTransport,LunaSend,LunaSocial,LunaSocialUI}`,
`Luna/Mail/`, `Luna/Social/`. Read-only audit for a strictly behavior-preserving refactor;
no functionality-change proposals. All 40 files in scope were read in full. Cross-references
outside scope (`LunaReadingList`, `Luna/AppDelegate.swift`, etc.) were grep-verified but not
audited themselves.

Baseline: two prior cleanup passes already landed (`CODE_REVIEW_PLAN.md` @ 2026-07-02,
commits through `632882b`; `PERF_REVIEW_PLAN.md` @ 2026-07-05). Items they already fixed are
**not** re-reported here; see "Already fixed — verified, not re-reported" at the end of each
relevant section where it matters for context.

---

## 1. Structure map

### LunaMail (pure, no UIKit)

| File | Responsibility | Public API | Callers (outside file) |
|---|---|---|---|
| `IncomingMailSettings.swift` | UserDefaults-backed settings: `isEnabled`, `allowedSenders`, `subjectFilters`, `autoSendToKindle`, dedupe cursor (`lastUID`/`uidValidity`) | enum, static props | `LunaReadingList/IncomingMailImporter.swift`, `Luna/Settings/EmailAndKindleSettingsScreen.swift` |
| `MIMEBody.swift` | Recursive MIME-part walker to the richest text part (html > plain), base64/QP decode | `MIMEBody.extract`, `.boundary`, `.decode` | `MailArticleBuilder`, `LunaReadingList/IncomingMailImporter.swift` |
| `GmailIMAPClient.swift` | **Pure parsers only** post-6197673 (`trailingLiteralCount`, `parseBracketValue`, `parseSearchUIDs`, `newSearchUIDs`, `parseHeaders`, `extractURLs`) + `IncomingMessage` struct — no live IMAP client remains in this type | static funcs, `IncomingMessage` | `StreamIMAPClient` (LunaMailTransport), `IncomingMailImporter` |
| `MailArticleBuilder.swift` | Email → `ArticleContent` (title/author/blocks, footer trim, RFC 2047 decode) | `MailArticleBuilder.build(...)` | `IncomingMailImporter` |

### LunaMailAccount (pure, no UIKit)

| File | Responsibility | Public API | Callers |
|---|---|---|---|
| `FilterGuide.swift` | Per-provider inbox-filter copy/links/Sieve script; the `via Lu‌na:` subject marker constants | `FilterGuide`, `subjectMatch`/`subjectPrefix` | used everywhere Luna-share subject detection happens (mail importer, social) |
| `MailProvider.swift` | Provider registry (Gmail/iCloud/Yahoo/Outlook/generic): server config, auth kind, app-password URL | `MailProvider` enum + static registry | `EmailLoginFlow`, `MailTransportFactory` |
| `EmailTransport.swift` | `EmailTransport` protocol + wire types (`OutgoingEmail`, `FetchedMessage`, `MailCursor`, `FetchResult`, `FilterOutcome`) | protocol + structs | implemented by `IMAPSMTPTransport`/`GraphMailTransport` |
| `ProviderInference.swift` | Domain→provider inference + Thunderbird ISPDB autodiscovery/XML parse | static funcs | `EmailLoginFlow` |
| `EmailAccountStore.swift` | `EmailAccountStore.shared`: App-Group defaults (metadata) + Keychain (secret), `accountChanged` notification | class, `.shared` | `EmailLoginFlow`, `CredentialViewController`, `ArticleSendCoordinator`/`AccountEmailSender`, `MailTransportFactory`, `GraphMailTransport`, `LunaReadingList/{IncomingMailImporter,EmailShareCenter}` |
| `EmailContentRenderer.swift` | Pure HTML/plaintext renderer for share emails (`renderArticle`/`renderCard`) | static funcs | `LunaReadingList/EmailShareCenter.swift` |
| `LunaShareMarker.swift` | `X-Luna-Share` marker codec — header + hidden-HTML-block carriage | `LunaShareMarker` struct, encode/decode | `StreamIMAPClient`, `GraphMailTransport`, `EmailContentRenderer`, `IncomingMailImporter` |
| `MailCredentialStorage.swift` | `MailCredentialStorage` protocol + `KeychainCredentialStorage`/`InMemoryCredentialStorage` | protocol + 2 impls | in-memory impl used by tests + onboarding-replay overlay (`Luna/Social/OnboardingStores.swift`) |
| `EmailAccount.swift` | `EmailAccount`/`OAuthTokens` models, `fromHeader` (RFC 5322-safe From formatting) | struct + static helper | widely used across mail layer |
| `MicrosoftOAuth.swift` | PKCE + Graph OAuth URL/body builders, pure | static funcs | `EmailLoginFlow` |
| `EmailMIMEBuilder.swift` | Assembles the multipart/related share email; delegates header encoding to `LunaModels.MIMEHeaderEncoding` | static builder | `LunaReadingList/EmailShareCenter.swift` |

### LunaMailTransport (network)

| File | Responsibility | Callers |
|---|---|---|
| `IMAPSMTPTransport.swift` | `EmailTransport` impl for app-password providers; thin adapter over Stream{IMAP,SMTP}Client | `MailTransportFactory` |
| `StreamIMAPClient.swift` | Real IMAP4rev1 client (login/fetchShares/markSeen) over `MailStream`, reusing `GmailIMAPClient`'s parsers | `IMAPSMTPTransport` |
| `MailStream.swift` | Line/byte TLS stream over `URLSessionStreamTask` (implicit TLS + STARTTLS) | `StreamIMAPClient`, `StreamSMTPClient` |
| `GraphMailTransport.swift` | `EmailTransport` impl for Outlook via Microsoft Graph REST | `MailTransportFactory` |
| `StreamSMTPClient.swift` | ESMTP submission (AUTH PLAIN/LOGIN, STARTTLS, dot-stuffing, chunked DATA) | `IMAPSMTPTransport` |
| `MailTransportFactory.swift` | `EmailTransport?` factory keyed on stored credential kind | `Luna/AppDelegate.swift:105` (`ArticleEmailTransportProvider.make = { MailTransportFactory.make() }`), `EmailLoginFlow.swift:374`, `IncomingMailImporter.swift:57`, `EmailShareCenter.swift:76` |

### LunaSend (pure business logic)

| File | Responsibility | Callers |
|---|---|---|
| `SavePressPolicy.swift` | Pure double-press decision matrix (legacy 12s regime + Action-Button 7s regime) | `Luna/Mail/Intents/SaveIntent.swift`, app-shell save paths |
| `ArticleSendMode.swift` | `off`/`allSaves`/`doubleSave` enum | `KindleSendSettings`, `SourceSendSettings` |
| `KindleSendSettings.swift` | Kindle address + send mode, routed through the connected email account | `EmailAndKindleSettingsScreen`, `ArticleSendCoordinator` |
| `SourceSendSettings.swift` | Per-capture-source auto-send resolution + per-friend overrides | `ArticleSendCoordinator` |
| `ArticleSendCoordinator.swift` | `.shared`: destination-agnostic fan-out/retry/backoff/EPUB-build/delivery orchestrator; `KindleDestination`/`AccountEmailSender` | `Luna/ReadingList/*`, `Luna/CatchUp/*`, `Luna/Settings/EmailAndKindleSettingsScreen.swift`, `LunaReadingList/{ArticleExportService,ReadingListIngestor}` — 17 call sites total |

### Luna/Mail/ (app-shell, UIKit)

| File | Responsibility |
|---|---|
| `EmailLoginFlow.swift`, `CredentialViewController.swift`, `EmailLoginShared.swift`, `EmailLoginLoadingCover.swift` | The 2-screen sign-in flow (entry → credential), documented accurately in `claudedocs/email-login.md` |
| `Intents/{ArticleEntity,ProvideContextIntent,LunaShortcuts,SaveIntent,ReadArticleIntent,CaptureIntentResult}.swift` | **Not mail-related** — Action-Button/Siri/Spotlight App Intent definitions (screenshot capture, TTS playback, Shortcuts discovery). See Finding B-2. |

### LunaSocial (pure, no UIKit)

| File | Responsibility | Callers |
|---|---|---|
| `FriendsStore.swift` | `Friend` model + App-Group JSON store (add/update/remove/markReceivedShare), posts `.friendsListChanged` | `LunaReadingList/IncomingMailImporter.swift:32-43`, `Luna/Settings/{DoubleSaveRecipientsScreen,EmailAndKindleSettingsScreen}.swift` |
| `PendingRequestsStore.swift` | Moderation queue for shares from non-friends, deduped by (url, senderEmail) | `IncomingMailImporter.swift:33-43` only |
| `NotificationManager.swift` | Local `UNUserNotificationCenter` wrapper (enum, static methods): `postShareReceived`, `postPendingRequest`, `postPriceDrop`, `clearShareNotifications` | `AppDelegate.swift`, `ReadingListViewController.swift:281`, `CredentialViewController.swift:202`, `EmailLoginFlow.swift:341`, `OnboardingFlow.swift:113`, `PriceRefreshCoordinator.swift:38`, `IncomingMailImporter.swift:133,150` |
| `RecentFriendRecipientsStore.swift` | Send-recency JSON store (`recentFriendRecipients.json`) | `SendToFriendSheet.swift` only |

### LunaSocialUI (UIKit, shared by all 3 apps)

| File | Responsibility | Callers |
|---|---|---|
| `FriendsViewController.swift` | Friends list (swipe-delete, badge to Pending Requests, add-by-email/contacts) | `SettingsViewController.swift:65`, `ReadingListViewController.swift:812`, `UITestScreen.swift` |
| `RecipientPickerViewController.swift` | Full multi-select recipient picker | `SendToFriendSheet.swift:73` (trailing-closure construction — a plain-call grep misses it) |
| `SendToFriendSheet.swift` | Entry point: bottom sheet of recent recipients → picker → `EmailShareCenter` | `AppDelegate.swift`, `ReadingListViewController.swift`, `SceneDelegate.swift`, `AppReaderProviders.swift` |
| `PendingRequestsViewController.swift` | Moderation UI; imports via `ReadingListStore`/`ReadingListIngestor` directly | `FriendsViewController.swift:100`, `SceneDelegate.swift:94` |
| `FriendDetailViewController.swift` | Per-friend notify toggle + remove | `FriendsViewController` |
| `ReaderShareSheet.swift` | Generic row-list share sheet for readers | `AppReaderShareProvider` (Luna/Social) |
| `EmailRecipientPrompt.swift` | Shared "add email / add from contacts" helper (from 632882b dedup) | `FriendsViewController`, `RecipientPickerViewController` — confirmed both call sites use it |
| `OnboardingStepViewController.swift` | Per-step onboarding screen (icon tile or `OnboardingAnimationView`, title/body, buttons) | `OnboardingFlow` |
| `OnboardingDotMatrixProgressView.swift` | CALayer-based progress dots, unrelated animation mechanism to `OnboardingAnimationView` | `OnboardingStepViewController.swift:171` |
| `OnboardingAnimationView.swift` | 2460-line illustration player for 6 onboarding screens (see §2's dedicated deep dive) | `OnboardingStepViewController.swift:89`; `OnboardingGuideVideo.swift:130` (via `.currentBundle`) |

### Luna/Social/ (app-shell)

| File | Responsibility |
|---|---|
| `OnboardingStores.swift` | Ephemeral-store overlay for onboarding replay (accessor-only rule enforced by doc comment) |
| `AppReaderProviders.swift` | `AppReaderShareProvider` — main-app `ReaderShareProviding` impl wiring `SendToFriendSheet`/`EmailShareCenter`/`ArticleExportService` |
| `OnboardingFlow.swift` | Linear onboarding step-builder chain (email → Safari → shortcut-install/action-extension → Action Button) |

### Cross-cutting: the `SocialMessageCenter` claim is stale

CLAUDE.md states: *"Cross-tier wiring uses injected closures/protocols installed at launch in
AppDelegate (e.g. `SocialMessageCenter.ingestHandler`/`shareRecorder`, ...)."*

Verified by repo-wide grep (`grep -rn "SocialMessageCenter"`, excluding the stray
`.claude/worktrees/agent-a44f9578d823e01c8/` duplicate tree): **this type does not exist
anywhere in the codebase.** It appears only in two comments outside this audit's scope —
`Luna/AudioPlaybackWiring.swift:22` and `LunaLibraries/Sources/LunaReaderUI/ReaderAudioLauncher.swift:10`
— both citing it as an analogy ("the injected-closure composition pattern the app shell
already uses (`SocialMessageCenter.ingestHandler`, ...)"). It was apparently renamed or
removed at some point; the real friend-share ingest path (`IncomingMailImporter` calling
`FriendsStore`/`PendingRequestsStore`/`NotificationManager`, `EmailShareCenter.shared`) is
wired as direct singleton calls, not injected closures. **CLAUDE.md's own architecture
description is stale on this point** — flagged for whoever maintains it; not something this
read-only audit can fix. The closest living analog of that pattern in-scope is
`SendToFriendSheet.accountSetupLauncher` (see Finding A-1) and
`ArticleEmailTransportProvider.make` (Finding A-2).

---

## 2. Findings

### A. Stored-callback communication

1. **`SendToFriendSheet.accountSetupLauncher`** — `LunaLibraries/Sources/LunaSocialUI/SendToFriendSheet.swift:19` (`public static var (UIViewController) -> Void`). Set once in `Luna/AppDelegate.swift:98`; invoked from `promptAccountSetup` (`SendToFriendSheet.swift:143-147`). This is a real AppDelegate-injected static closure, structurally identical to the (now nonexistent) `SocialMessageCenter` pattern CLAUDE.md describes. A `protocol AccountSetupLauncher { func launch(from:) }` would be marginally more testable, but it's a single setter / single call site today — low risk either way, not urgent.

2. **`ArticleEmailTransportProvider.make: () -> EmailTransport?`** — `LunaLibraries/Sources/LunaSend/ArticleSendCoordinator.swift:50`. Static stored closure, defaults to `{ nil }`, overwritten once at launch in `Luna/AppDelegate.swift:105` (`ArticleEmailTransportProvider.make = { MailTransportFactory.make() }`). Exists because `LunaSend` sits below `LunaMailTransport` in the dependency graph and can't import it directly. `AccountEmailSender` has a parameterless `init()` and reaches for this global at call time, so it can't be unit-tested without mutating global state — this plausibly explains why `ArticleSendCoordinatorTests` (now deleted, see Finding E-4/Top-10 #1) used an in-memory `MockDestination` rather than exercising `AccountEmailSender` directly. Converting to a protocol injected via `AccountEmailSender.init(transportProvider:)` would make this testable; worth doing alongside restoring the test coverage.

3. **Onboarding step lifecycle closures** — `OnboardingStepViewController.onDidAppear`/`onWillEnterForeground` (`LunaLibraries/Sources/LunaSocialUI/OnboardingStepViewController.swift:53,56`), set per-step by `OnboardingFlow` (e.g. `Luna/Social/OnboardingFlow.swift:160-170, 207-223, 272-294`), invoked from `viewDidAppear`/a foreground observer. These are one-shot-per-appearance step wiring rebuilt fresh per step object, not a cross-component singleton seam — fine as-is; a delegate protocol would just add ceremony.

4. **`AppReaderShareProvider`'s `onPickFriend`/`onShareLink`/`onCopyLink`/`onShareEbook`** — `Luna/Social/AppReaderProviders.swift:34-55` — and **`ReaderShareSheet.Row.action`** are one-shot construction-time closures, not stored mutable seams. Fine.

5. **`EmailLoginFlow.present(from:accountStore:completion:)`** / **`CredentialViewController.init(...completion:)`** — one-shot `completion: ((Bool) -> Void)?`, acceptable per the audit's own carve-out for one-shot completions. Noted only because the `Bool` conflates cancellation and failure (both `false`) across two hand-plumbed screens — not a structural violation, just a minor signal-loss point if anyone later wants to distinguish the two.

No other persistent closure-typed stored properties for cross-component communication were found in scope. `EmailLoginFlow`'s `authSession`/`loadingCover` are stored *objects*, not callbacks.

### B. View/container boundary violations

1. **`PendingRequestsViewController.importAndRemove`** — `LunaLibraries/Sources/LunaSocialUI/PendingRequestsViewController.swift:76-81` — reaches directly into `ReadingListStore.shared` and `ReadingListIngestor.shared` (both `LunaReadingList`/`LunaStorage`) from a `LunaSocialUI` view controller, with no coordinator/protocol indirection (contrast with `AppReaderShareProvider`'s pattern of injecting a provider into the reader layer). `SendToFriendSheet` also imports `LunaReadingList` directly. This is the established convention throughout this module (same `XStore.shared` pattern used everywhere else in the codebase, e.g. `ReadingListStore.shared`), so it's flagged for awareness rather than as a regression or an outlier needing fixing in isolation.

2. **`Luna/Mail/Intents/` misplacement** — `ProvideContextIntent.swift`, `SaveIntent.swift`, `ReadArticleIntent.swift`, `ArticleEntity.swift`, `CaptureIntentResult.swift`, `LunaShortcuts.swift` have zero mail-related content (Action Button / screenshot-vision / Siri / TTS / Spotlight intents). They're filed under `Luna/Mail/` with no apparent connection to mail. Pure organizational smell, no functional risk — likely inherited from an earlier layout where mail-adjacent intents lived there and the directory kept growing. `Luna/Social/` is the only comparable "topic" directory at that level, and `Luna/Intents/` doesn't currently exist as a sibling, so moving this needs a home decided first, not just an audit note.

3. **`EmailEntryViewController`/`CredentialViewController`** (Luna/Mail) perform network I/O (`resolveServer`, OAuth token exchange, `transport.verifyCredentials()`) inline in view-controller methods, not through a separate service/coordinator object. This is consistent house style across the codebase (same shape in onboarding, settings, etc.) — not singled out as a mail-specific defect.

4. **`LunaSocial` itself is clean**: verified no UIKit imports anywhere in `FriendsStore.swift`, `PendingRequestsStore.swift`, `RecentFriendRecipientsStore.swift` (only `LunaStorage`/`Foundation`); `NotificationManager.swift` imports `UserNotifications`, a legitimate non-UIKit framework.

### C. Duplicated or disjoint-but-related logic

1. **Three near-identical App-Group JSON stores** — `FriendsStore.swift`, `PendingRequestsStore.swift`, `RecentFriendRecipientsStore.swift` each hand-roll the same shape: `fileManager`/`overrideContainerURL`/`mutationLock: NSLock`, an identical `fileURL` computed property (container lookup + `BackupPolicy.includeInBackups`), and a textually identical `save()` body (atomic write + `try?` + `DispatchQueue.main.async { NotificationCenter.post }`) modulo type and notification name. Compare `FriendsStore.swift:79-87,161-170`, `PendingRequestsStore.swift:58-66,103-112`, `RecentFriendRecipientsStore.swift:39-47,78-87`. This is the same duplication class CLAUDE.md/CODE_REVIEW_PLAN already fixed once for `trackerStores` (×3 → one `ProductInfo` extension) — a generic `AppGroupJSONStore<T: Codable>` would collapse this mechanically, same lock/write/notify order, no behavior change.

2. **`OnboardingFlow`'s three step-builders repeat a reentrancy-guard + observer skeleton** — `safariStep` (`Luna/Social/OnboardingFlow.swift:123-172`), `shortcutInstallStep` (`175-231`), `actionButtonStep` (`240-305`) each declare a one-shot `didAdvance`/`didFinish` guard, a `stateObserver: NSObjectProtocol?` (two of the three), and react to both `onDidAppear` and `onWillEnterForeground`. `shortcutInstallStep`/`actionButtonStep` build the *exact same* `NotificationCenter.default.addObserver(forName: ActionButtonOnboardingStore.stateDidChangeNotification, ...)` block (`OnboardingFlow.swift:213-222` vs `284-293`), differing only in the compared state (`.actionButtonSetup` vs `.done`). A small `SingleFireAdvance`/`ActionButtonStateWatcher` helper could extract this without changing timing.

3. **`GmailIMAPClient` vs `StreamIMAPClient`: NOT duplicated** (verified). `grep -rn "GmailIMAPClient\."` finds 9 production call sites, all either `StreamIMAPClient` consuming its pure parsers or `IncomingMailImporter.extractURLs`. The commit-6197673 claim that only static parsers + `IncomingMessage` remain in `GmailIMAPClient` is accurate — there is exactly one live IMAP client (`StreamIMAPClient`) today.

4. **RFC 2047 decode (`MailArticleBuilder`) vs encode (`MIMEHeaderEncoding`): NOT duplicated.** One decodes incoming headers, one encodes outgoing headers; disjoint call sites, no residual overlap. `EmailMIMEBuilder` only encodes, via `MIMEHeaderEncoding`.

5. **Provider-specific behavior is reasonably centralized** — `MailProvider` (registry), `ProviderInference` (domain→ID + autodiscovery), `EmailAccount.fromHeader` (formatting) each own a distinct concern; no overlap found between them.

6. **`FriendsViewController`/`RecipientPickerViewController` — confirmed NOT duplicated post-fix.** Both route "add by email"/"add from contacts" through the shared `EmailRecipientPrompt` helper landed in `632882b` (`FriendsViewController.swift:127-137`, `RecipientPickerViewController.swift:103-122`) — the prior dedup held. Otherwise the two implement genuinely different table structures (single-select-and-navigate vs. multi-select-with-checkmarks), appropriately separate.

7. **`sharedByUsername` is a dead field in production — real finding, verified.** `ArticleSendCoordinator.swift:98` passes `friendUsername: item.sharedByUsername` into `SourceSendSettings.sendMode(forDestination:source:friendUsername:)`, and `SourceSendSettings.friendShareEnabled(forDestination:username:)` (`SourceSendSettings.swift:81-91`) keys the per-friend override map by that string. But `social-sharing.md` states `Friend.email` (lowercased) is the stable identifier, not a username/name. Verified by repo-wide grep:
   ```
   grep -rn "sharedByUsername" --include="*.swift" .
   Luna/UITestFixtures.swift:126:                sharedByUsername: sharedBy,
   Luna/ReadingList/ReadingListViewController.swift:1364:  if let sharedBy = item.sharedByUsername {
   Luna/CatchUp/CatchUpSubviews.swift:221:  if let friend = item.sharedByUsername { text += " · from \(friend)" }
   LunaLibraries/Sources/LunaSend/ArticleSendCoordinator.swift:98: friendUsername: item.sharedByUsername)
   LunaLibraries/Sources/LunaModels/ReadingListItem.swift:105,219,250,276,357  (declaration/init/decode only)
   ```
   `item.sharedByUsername` is **never assigned a non-nil value anywhere in production** — only `Luna/UITestFixtures.swift:126` sets it, for tests. The only setter that could have populated it (`ReadingListStore.setSharedBy`) was deliberately removed in `a605d9b` ("dead-code sweep… + decide `sharedByUsername` story — remove setter only"). Net effect, verified structurally:
   - The per-friend override branch in `SourceSendSettings.sendMode`'s `.friendShare` case can never resolve a per-friend override — always falls through to `friendSharesEnabledDefault`.
   - The "from `<name>`" UI attribution at `ReadingListViewController.swift:1364` and `CatchUpSubviews.swift:221` is dead in practice (condition never true).
   This reads as unresolved fallout from `a605d9b`'s own commit note ("decide `sharedByUsername` story") rather than a deliberate deprecation — flagged for the author to confirm intent before treating it as something to wire up or fully remove.

8. **`OnboardingAnimationView`'s dead "legacy" scene generation — 357 lines, ≈14.5% of the file.** See §D-1/§E below; this is both a complexity and a dead-code finding, cross-referenced here because it's effectively a whole duplicated scene generation (the file ships two complete implementations of the Action Button Settings illustration).

### D. Overly complex code / god methods

**`OnboardingAnimationView.swift` (2460 lines, the single biggest file in the repo) — dedicated deep dive.**

*Internal organizing unit*: "illustration kind." One `Kind` case ↔ one `build*()` (one-time view/constraint setup, gated by `didBuildIllustration`) ↔ one `animate*()` (`reset()` local closure, then a single `UIView.animateKeyframes(..., options: [.repeat])` loop). `start()`/`buildIfNeeded()` dispatch on `kind` via a plain switch (lines 117-124, 184-191) — there is no protocol, enum-driven table, or shared base; each case is fully self-contained with its own prefixed stored properties (`banner`, `island…`, `ax…`, `sx…`, `si…`, `abs…`, `ab…`). All animation is `UIView.animateKeyframes`/`CGAffineTransform`/`alpha`/constraint-constant mutation — **no `CABasicAnimation`/`CAKeyframeAnimation`/`CADisplayLink` anywhere in this file** (that mechanism lives in the sibling `OnboardingDotMatrixProgressView.swift`, an unrelated CALayer pulse).

Six scenes (one dead — see below):

| # | Scene | Lines | What it shows | Owns |
|---|---|---|---|---|
| 1 | Notification banner | 207-264 | Banner slides down, holds, slides back up | 1 property |
| 2 | Action Button | 266-475 | Ripple on hardware button; Dynamic Island expands (constraint-constant + `layoutIfNeeded()`), shows icon+checkmark | 6 properties incl. 2 `NSLayoutConstraint!` |
| 3 | Action extension | 477-842 | Safari page → Share tap → sheet slides up → row list scrolls (`CGAffineTransform` synced between row list + highlight) → tap → sheet drops, extension card slides up | 6 properties |
| 4 | Safari extension | 915-1191 | Page-menu ripple → menu sheet → tap "Manage Extensions" → **crossfade** into extensions panel → toggle flips (`miniToggle()` mutates `frame` directly — the one non-Auto-Layout-animated element in the file) → panel drops | 5 properties incl. a `(track,thumb)` tuple |
| 5 | Shortcut install | 1193-1455 | Toolbar ripple → share sheet → tap Shortcuts icon (scale bump) → hold → reset | 4 properties |
| 6 | ~~Legacy Action Button Settings~~ | 1457-1813 | **Entirely dead**, see below | — |
| 7 | Action Button Settings (current) | 1815-2459 | Settings list → push detail → swipe a two-strip glyph carousel (outer dim strip + inner white strip clipped in a capsule) → choose shortcut → iOS-multitasking-style app-switcher card transition → press button → Island confirmation | ~20 properties, 2 `NSLayoutConstraint!` |

**Repeated pattern proving a genuine template**: every live scene's `animate*()` follows the identical triad — a local `reset()` closure, one call to it before the loop, then `UIView.animateKeyframes`. Example (`animateShortcutInstall`, 1412-1415):
```swift
func animateShortcutInstall() {
    layoutIfNeeded()
    let sheetDrop = CGAffineTransform(translationX: 0, y: siShareSheet.bounds.height + 8)
    func reset() { ... }
    reset()
    UIView.animateKeyframes(withDuration: 5.5, delay: 0.4, options: [.repeat]) { ... }
}
```
Same triad at 435 (`animateActionButton`), 779 (`animateActionExtension`), 1131 (`animateSafariExtension`), 2296 (`animateActionButtonSettings`) — and the dead `legacyAnimateActionButtonSettings` too. Also a repeated **"off-screen drop transform = bounds.height + constant"** idiom for hiding sheets, at 781, 1136-1138, 1414.

**God methods (>40 lines):**

| Method | Lines | Len | What it does |
|---|---|---|---|
| `buildActionButtonSettings` | 1861-2294 | **434** | Builds 3 nested "screens" (Settings detail, Settings root, Safari) inside one phone mockup: ~30 subviews, a 4-symbol two-strip carousel, a `rootRow` local factory called 6×, ~90 constraints in one literal |
| `buildActionExtension` | 486-701 | 216 | Phone + Safari page/toolbar + share sheet (grabber, icon row, 6-row scroll list) + action card, ~70 constraints |
| `legacyBuildActionButtonSettings` | 1537-1743 | 207 | **Dead** — superseded single-carousel-card version of the same scene |
| `buildSafariExtension` | 923-1129 | 207 | Phone + Safari page/address bar + page-menu sheet + extensions-list sheet with a mini toggle, ~75 constraints |
| `buildShortcutInstall` | 1245-1410 | 166 | Phone + a nested "mirror" phone (one-level recursive illustration-of-the-illustration) + toolbar + share sheet |
| `animateActionButtonSettings` | 2296-2459 | 164 | 13 keyframes; each keyframe's start time is hand-tuned against the previous — the most sequentially-dependent animation in the file |
| `buildActionButton` | 278-413 | 136 | Phone + Safari facsimile + Dynamic Island |

`buildActionButtonSettings` (434 lines) is the single largest method in the repo's largest file. It interleaves three unrelated concerns with zero internal structure: (a) Settings-detail screen (status bar, back button, carousel, page dots, crossfade label pairs, "Choose a Shortcut" button) 1861-2026; (b) an entirely separate Settings-root screen (nav bar, two grouped-table sections via a locally-nested `rootRow` closure) 2027-2129; (c) the Safari screen (web lines, chrome, hardware button, Island) 2131-2197; then (d) one 95-line `NSLayoutConstraint.activate([...])` covering all three at once, 2199-2293. None of the three screens' state overlaps — nothing requires them to share a function.

Elsewhere in scope: `EmailLoginFlow.EmailEntryViewController.viewDidLoad` (~120 lines, pure view construction, not algorithmically complex — matches `CredentialViewController.viewDidLoad`'s shape, not flagged as a real problem). `GraphMailTransport.fetchShares` (48-122, 75 lines) is genuinely dense — per-clause request fan-out around Graph's `InefficientFilter`, dedupe-by-id merge, client-side fallback, first-run cursor bootstrap all interleaved; well-commented, but has zero test coverage (see §3), which raises the stakes of touching it. `OnboardingStepViewController.viewDidLoad` (78-219, ~140 lines) is one long but linear, non-nested view-building method; low-value/low-risk extraction candidate only. `Luna/Mail/Intents/SaveIntent.swift.perform()` (93-219, ~125 lines) is a genuine god method (model invocation, response parsing, per-platform/Safari branching, double-press short-circuit, interop-block handling, media-download handoff all inline) — flagged for awareness only, since it's an Action-Button/Siri intent, not mail logic, and belongs to whoever owns `LunaIntents`.

### E. Dead/unused code (every claim grep-verified)

1. **`OnboardingAnimationView`'s "legacy" Action Button Settings generation — dead, 357 lines.**
   ```
   grep -n "legacyBuildActionButtonSettings" OnboardingAnimationView.swift
   → 1537:    private func legacyBuildActionButtonSettings() {     (definition only)
   grep -n "legacyAnimateActionButtonSettings" OnboardingAnimationView.swift
   → 1745:    private func legacyAnimateActionButtonSettings() {   (definition only)
   ```
   `start()`/`buildIfNeeded()`'s switches (117-124, 184-191) call only the block explicitly marked `// MARK: - Current Action Button guide` (1815-2459) — never the `legacy*` pair. The dead block 1457-1813 comprises: stored properties 1462-1472 (`absCardStep`, `absCarouselStack`, `absCardPrev`, `absCardShortcut`, `absCardNext`, `absChooseRow`, `absRowRipple`, `absOptionsSheet`, `absSendHighlight`, `absCheckmark`), `absOptionCard(_:symbol:literalCaption:)` (1477-1517), `darkActionRow(icon:placeholderWidth:)` (1521-1535), `legacyBuildActionButtonSettings()` (1537-1743), `legacyAnimateActionButtonSettings()` (1745-1813) — confirmed disjoint from the live block by distinct property prefixes (`abs…` vs `ab…`), no cross-references either direction.

2. **`OnboardingAnimationView.sheetShell(cornerRadius:)`** (861-865) — dead:
   ```
   grep -n "sheetShell" OnboardingAnimationView.swift
   → 861:    private func sheetShell(cornerRadius: CGFloat = 18) -> UIView {   (definition only)
   ```
   Every real use goes through `configureSheetShell(_:cornerRadius:)` applied to an already-instantiated view (999, 1020, 1312) instead of this factory wrapper.

3. **`GmailIMAPClient` dead NWConnection machinery — confirmed already removed** (6197673); no further orphans found in this file.

4. **`MailProvider.selectable` — confirmed already removed**: `grep -rn "\.selectable"` → zero hits.

5. **No new dead code found** in `LunaMail`/`LunaMailAccount`/`LunaMailTransport`/`LunaSend`: `KindleSendSettings.isConfigured`, `MailCredential`, `sendTestDocument`, `epubFileName`, `InMemoryCredentialStorage`, `EmailContentRenderer.*`, `FilterGuide.*`, `createLunaFilter`, `doubleSaveDestinationIDs`, `MicrosoftOAuth.formEncode`, `ProviderInference.parseISPDB` all have live non-test call sites (1-17 each).

6. **No new dead code found** in `LunaSocial`/`LunaSocialUI`/`Luna/Social`: `RecipientPickerViewController` is used (single call site via trailing closure in `SendToFriendSheet.swift:73`, easy to miss with a naive grep for `RecipientPickerViewController(`); `OnboardingDotMatrixProgressView` has a single live call site (`OnboardingStepViewController.swift:171`) — not dead, just narrow; `NotificationManager.postPriceDrop`/`clearShareNotifications` both have live external callers. Consistent with `a605d9b` having already swept `SendToFriendSheet.present`'s unused `sourceView` param and the duplicate send-to-friend menu actions.

### F. Comment hygiene

1. `Luna/AudioPlaybackWiring.swift:22` and `LunaLibraries/Sources/LunaReaderUI/ReaderAudioLauncher.swift:10` — both cite `SocialMessageCenter.ingestHandler` as an analogy for a pattern, but that type no longer exists anywhere (see §1's cross-cutting note). **Rewrite**: replace `"same composition pattern as SocialMessageCenter.ingestHandler"` with a reference to a symbol that actually exists (e.g. `SendToFriendSheet.accountSetupLauncher`) or describe the pattern without naming a dead type. (Both files are outside this audit's directory scope to edit — flagged here since the dead symbol they cite is fully diagnosed by this audit.)

2. `Luna/Mail/EmailLoginLoadingCover.swift:9` — *"Shared by both the app-password `signIn` path and the Outlook OAuth token exchange (previously the OAuth path had its own private copy of this)."* **Rewrite**: `"Shared by both the app-password sign-in path and the Outlook OAuth token exchange."` (drop the parenthetical narrating history).

3. `Luna/Mail/EmailLoginFlow.swift:246` — *"The only feedback during this network wait used to be nothing at all — now the button itself shows it's busy."* **Rewrite**: `"The button shows it's busy for the only network wait on this screen."`

4. `LunaLibraries/Sources/LunaMail/GmailIMAPClient.swift:36-39` — doc comment narrates history ("was superseded by… has been removed; only its unit-tested parsers… remain") but is genuinely load-bearing: it explains why a file titled `GmailIMAPClient` contains no client. **Leave as-is** — this is the one legitimate exception to the "no change-narration" rule, since without it the file's shape is inexplicable.

5. `OnboardingAnimationView.swift:1815` and its doc comment at `1856-1860` — `// MARK: - Current Action Button guide (accurate Settings → Safari sequence)` and `/// Recreates the current full-height Action Button Settings presentation…`. The word "Current" only makes sense as a contrast against the dead "legacy" scene directly above it (§E-1); once that dead block is deleted, this framing dangles. **Rewrite** (after the dead-code deletion): `// MARK: - Action Button Settings (Settings > Action Button)` and `/// Recreates the real Action Button Settings presentation from device references: circular back button, tall titanium phone, large illuminated hardware control, neighboring action glyphs, page dots, and the selected shortcut. The second page is Safari so the guide demonstrates the complete job rather than ending as soon as Settings is configured.`

6. Non-comment oddity adjacent to hygiene: `OnboardingAnimationView.swift:224` — `bodyText.text = "htest shared an article"` inside the mock notification banner. Reads like a leftover developer-initials placeholder rather than a deliberate generic name (contrast every other mock string in the file: "example.com", or deliberately blank grey bars). Purely cosmetic (illustrative mock UI, never real user data) but looks like an oversight.

7. Everything else checked for narration patterns (`legacy`, `previously`, `used to`, `no longer`, `now fixed`) across all 40 files turned out to be legitimate current-state naming/documentation (e.g. `SavePressPolicy`'s "Legacy (in-app saves)" names a real, still-live regime, not narration) — not re-flagged.

### G. Animation structure assessment (OnboardingAnimationView)

**Verdict: not a good data-driving candidate.** Compared the most- and least-similar scene pairs:

- **Most similar**: `animateShortcutInstall` (1412-1455, 4 keyframes: ripple-in, ripple-out+sheet-up, icon-scale-bump, reset) vs. `animateActionButton` (435-475, 5 keyframes: ripple-in, ripple-out, island-expand, icon-reveal, island-contract). Superficially both look like `(delay, duration, transform)` tuples, but the actual mutated properties differ in kind: `siShortcutIcon.transform` (a plain `CGAffineTransform`) vs. `islandWidthConstraint.constant` + `island.layer.cornerRadius` + `layoutIfNeeded()` (a constraint-driven resize) — no common abstraction covers both without degrading into a closure array, i.e. what the code already is.
- **Least similar**: `animateActionButtonSettings` (2296-2459, 13 keyframes) has hand-tuned, narratively-ordered dependencies — e.g. 2397-2404 exists solely to counteract `.calculationModeCubic` interpolation artifacts, a workaround that only makes sense written out — plus a bespoke multitasking-card transition (2392-2410) with no analog anywhere else in the file.

Since even the closest pair diverges at the property-mutation level, and the outlier encodes animation-engine-specific workarounds inline, **data-driving the keyframes would hurt readability** (it would relocate the meaningful logic into opaque tuples/closures for minimal boilerplate savings — each `addKeyframe` call is already about as terse as a table row would be). The one thing worth extracting as a plain shared **function** (not data) is the "drop transform for an off-screen sheet" idiom used identically at 781, 1136-1138, and 1414 — a 1-line helper, not a structural change.

**Extraction seam recommendation** (behavior-preserving, ranked by risk):
1. Delete the dead 357-line legacy block (§E-1) first — zero risk, drops the file to ~2100 lines, removes the "current" framing problem (§F-5).
2. **Recommended split**: move each scene to its own file as `extension OnboardingAnimationView` in a separate file (`OnboardingAnimationView+ActionButton.swift`, `+ActionExtension.swift`, `+SafariExtension.swift`, `+ShortcutInstall.swift`, `+ActionButtonSettings.swift`, `+SharedRows.swift` for cross-scene helpers like `bar`, `axActionRow`, `configureSheetShell`, `toolbarIcon`) — same type, no new protocol, no behavior change. Requires promoting the per-scene stored properties from `private` to `fileprivate` (a mechanical, behavior-invisible visibility change, since Swift's `private` is file-scoped). The root file keeps only the type declaration, `Kind`/`AppIcon`, `init`, and the `start()`/`stop()`/`buildIfNeeded()` dispatch (~200 lines).
3. **Explicitly flagged over-structuring risk**: do NOT build a generic `OnboardingScene` protocol (`install(on:)`/`animate(completion:)`) or factor the repeated `reset()`-then-`animateKeyframes()` idiom into a shared base/generic animator. Every scene's geometry, property set, and keyframe timing is bespoke — a protocol would add indirection without shrinking any method (the 434-line `buildActionButtonSettings` doesn't get shorter by being called through a protocol instead of a switch case). This matches the codebase's own prior judgment on the structurally identical Settings-effect-screens duplication (CODE_REVIEW_PLAN.md: "the correct fix is a parameterized base; too large/risky for this pass — deferred with this note").

---

## 3. Test coverage

**Well-covered:**
- `MailArticleBuilder` + `MIMEBody` — `LunaTests/MailArticleBuilderTests.swift`
- `GmailIMAPClient` parsers — `LunaTests/GmailIMAPClientTests.swift`
- `EmailAccountStore` — `LunaTests/EmailAccountStoreTests.swift`
- `EmailLoginFlow` pure statics (normalizedPassword/isValidAddress/isConnectivityFailure) — `LunaTests/EmailLoginTests.swift`
- Autofill logic — `LunaTests/EmailEntryAutoFillTests.swift`
- `IncomingMailImporter` subject/title logic (importer itself is out of scope) — `LunaTests/IncomingMailImporterTests.swift`
- `FriendsStore` — `LunaTests/FriendsStoreTests.swift` (add/list/remove, re-add-updates-name, first-share tracking, ordering, email validation)
- `PendingRequestsStore` — `LunaTests/PendingRequestsStoreTests.swift` (add/count/remove, dedupe, distinct senders, display fallback)
- `RecentFriendRecipientsStore` — `LunaTests/RecentFriendRecipientsStoreTests.swift` (ordering, resend-moves-to-top, invalid-email filtering)
- `OnboardingStores` — `LunaTests/OnboardingStoresTests.swift` (ephemeral isolation, teardown, Safari read-through rule, Action Button replay reset/restore) — thorough
- `OnboardingFlow` — `LunaTests/OnboardingScreenTests.swift` (snapshot per step, layout sanity, Skip advances, ephemeral-store isolation) — thorough for layout, but no test exercises `safariStep`/`shortcutInstallStep`/`actionButtonStep`'s actual `onWillEnterForeground`/notification-observer *advance logic* (§C-2's duplication target), only static snapshots of the built VCs
- `ReaderShareSheet` — `LunaTests/ReaderShareSheetTests.swift` — only the static `rows()` factory (count/titles/action firing), not the view controller itself (sheet detent sizing, `viewDidLoad`, dismiss-then-action sequencing)

**Zero test coverage (verified by content-grep across `LunaTests/*.swift`, not just filename guessing):**
- `LunaShareMarker` — **and the doc claim that it's tested is false.** `claudedocs/social-sharing.md:97` states `LunaShareMarkerTests` exists; `git log --all -- '*LunaShareMarkerTests*'` returns no such file having ever existed in this repo.
- `ProviderInference` (domain table, ISPDB XML parsing, autodiscovery) — pure and trivially testable, untested.
- `MicrosoftOAuth` (PKCE challenge/verifier, URL/token-exchange param building) — untested.
- `GraphMailTransport` (`matches`, `odataEscaped`, cursor bootstrapping) — untested; this is also the file flagged as a god-method candidate (§D), raising the stakes.
- `EmailMIMEBuilder` — no direct test of the actual multipart/related wire format Luna sends (inline-image CIDs etc.).
- `FilterGuide` — only incidentally touched via `IncomingMailImporterTests.swift`, never directly.
- `NotificationManager`, `FriendsViewController`, `RecipientPickerViewController`, `SendToFriendSheet`, `PendingRequestsViewController`, `FriendDetailViewController`, `OnboardingDotMatrixProgressView`, `EmailRecipientPrompt`, `AppReaderShareProvider` — no `*Tests.swift` references any of these. Consistent with how the rest of the UI layer is tested in this codebase (snapshot-first for content, untested chrome) — not a gap unique to this module.

**Regression — test coverage that existed and was deleted (see Top-10 #1 for the full account):**
`SavePressPolicy`'s legacy 12s in-app-save regime, `SourceSendSettings` (full per-source/per-friend resolution matrix), and `ArticleSendCoordinator` (multi-destination fan-out/retry/backoff via a `MockDestination`) all had dedicated test files — `LunaTests/SavePressPolicyTests.swift`, `LunaTests/SourceSendSettingsTests.swift`, `LunaTests/ArticleSendCoordinatorTests.swift` — **deleted in commit `97833a34` ("Clean up broken integrations", 2026-07-07)**, which also removed the unrelated Boox e-reader integration (`BooxAPIClient`/`BooxAuthClient`/`BooxSendSettings`/`Send2BooxClient`/`OSSRequestSigner` + their tests) in the same 122-file, -7553/+583-line commit. Verified via `git show --stat 97833a34`; verified these three files remain deleted through the current `HEAD` (`git log --oneline 97833a34..HEAD -- <files>` returns nothing). `SavePressPolicy` is now partially re-covered indirectly (`LunaTests/DoubleSavePolicyTests.swift`, `LunaTests/ScreenshotDoublePressTests.swift`, both scoped to the newer Action-Button 7s regime only) — the original legacy-regime coverage is gone and not replaced. `SourceSendSettings` and `ArticleSendCoordinator` have **no replacement coverage at all** today.

Compounding this: `claudedocs/send-to-kindle.md` still explicitly claims `ArticleSendCoordinatorTests` and `SourceSendSettingsTests` exist (lines 141, 143 per the fork's read) and is independently corrupted by the same commit — verified by reading it directly: lines ~80-101 contain verbatim leftover fragments of the deleted Boox/OSS integration's documentation (OSS bucket/STS creds, signed OSS PUT, `oss2` SDK, `Luna/Send/*.swift` paths that no longer exist — the real paths are `LunaLibraries/Sources/LunaEpub/EpubBuilder.swift` etc.). `git show --stat 97833a34` shows only a partial (`-24` lines) edit to this doc, not a full rewrite, so it now reads as garbled interleaved Kindle-and-Boox content.

---

## Top 10 highest-value changes

Ranked by value; size estimate S/M/L is for a behavior-preserving change only (no functionality change implied by this audit itself).

1. **(L)** Restore or rewrite test coverage for `ArticleSendCoordinator`, `SourceSendSettings`, and `SavePressPolicy`'s legacy regime — all three test files were deleted as collateral damage in commit `97833a34` alongside an unrelated Boox-integration removal, and cover live, non-trivial retry/backoff/fan-out/gating logic with zero tests today.
2. **(S)** Rewrite `claudedocs/send-to-kindle.md` from scratch — it currently contains leftover Boox/OSS documentation fragments and stale `Luna/Send/*` paths interleaved with real Kindle content, from the same corrupting commit as #1.
3. **(S)** Delete `OnboardingAnimationView.swift`'s dead legacy Action Button Settings generation (lines 1457-1813, 357 lines: `legacyBuildActionButtonSettings`, `legacyAnimateActionButtonSettings`, `absOptionCard`, `darkActionRow`, and their 10 dedicated stored properties) — zero risk, ~14.5% file-size reduction, immediately un-blocks the stale "Current"/"legacy" comment framing (Finding F-5).
4. **(M)** Split `OnboardingAnimationView.swift` into per-scene extension files (`+ActionButton.swift`, `+ActionExtension.swift`, `+SafariExtension.swift`, `+ShortcutInstall.swift`, `+ActionButtonSettings.swift`, `+SharedRows.swift`), same type, `fileprivate` visibility promotion only, no protocol — turns the repo's biggest file into seven reviewable ones with no behavior change.
5. **(M)** Resolve the `sharedByUsername` dead-field question (Finding C-7): either wire a real setter keyed on `Friend.email` (the actual stable identifier per `social-sharing.md`) so per-friend send overrides and "from `<name>`" UI attribution actually work, or remove the now-unreachable code paths that depend on a field nothing sets in production. Needs the author's intent confirmed first — this audit only establishes that it's currently dead, not what should happen to it.
6. **(S)** Collapse `FriendsStore`/`PendingRequestsStore`/`RecentFriendRecipientsStore`'s identical App-Group-JSON-store boilerplate (`fileURL`, `mutationLock`, `save()`) into one generic helper — mechanical, same lock/write/notify order, well-covered by existing store tests.
7. **(S)** Add unit tests for `ProviderInference` (domain table + ISPDB XML parsing) and `MicrosoftOAuth` (PKCE/URL building) — both pure, currently untested, both silently break autodiscovery/OAuth if regressed.
8. **(S)** Add a round-trip test for `LunaShareMarker` (header path + hidden-HTML-block fallback path) — `social-sharing.md` claims this test exists (`LunaShareMarkerTests`); it never has.
9. **(S)** Extract `OnboardingFlow`'s repeated one-shot-advance + `ActionButtonOnboardingStore.stateDidChangeNotification`-observer skeleton (duplicated verbatim between `shortcutInstallStep` and `actionButtonStep`) into a small shared helper — needs care around observer-removal timing, so scoped as S but not zero-risk.
10. **(S)** Fix the stale change-narration comments: `EmailLoginLoadingCover.swift:9`, `EmailLoginFlow.swift:246`, and the two dangling `SocialMessageCenter.ingestHandler` references in `AudioPlaybackWiring.swift:22`/`ReaderAudioLauncher.swift:10` (a type that no longer exists anywhere in the codebase — also worth flagging to whoever maintains CLAUDE.md, since its own architecture description repeats the same stale claim).
