# Double-save action (Reader, Action Button only)

Saving the **exact same URL twice within 7 seconds** through the **Action
Button intents** (`ProvideContextIntent`'s immediate Safari save and
`SaveIntent`'s screenshot save — see `app-intents.md`) in **Luna Reader** runs
a configurable action on the already-saved item. `SaveIntent` additionally
detects the repeat press by screenshot **digest** (a visually-similar
screenshot within the same 7 s window re-runs the previous save with no model
call), since a second screenshot of the same screen resolves to the same URL.
No other save surface triggers it: share/action/Safari extensions, paste,
manual add, mail import, and the other two apps all keep plain save semantics,
as does the pre-existing **legacy in-app double-save regime** (12 s window,
ereader destinations whose App-Intents mode is "Double Save" — see below).

## Setting (Settings → Email & Sending → Double Save; Reader only)

`LunaStorage.DoubleSaveActionStore` (App Group defaults, per-surface keys):

- **Action** (`DoubleSaveAction`): `sendToKindle` (default) or `sendToFriend`.
- **Friend mode** (`DoubleSaveFriendMode`): `preset` (one or more friend emails,
  picked in `DoubleSaveRecipientsScreen` from `FriendsStore`) or `askEveryTime`
  (default).
- The store also carries the one-shot **pending friend prompt** hand-off
  (`setPendingFriendPrompt` / `takePendingFriendPrompt`, 5-minute lifetime) used
  by the ask-every-time path below.

## Flow

The Action Button intents (and only they) call
`IntentIngestHelper.handleSavePress(urlString:doubleSaveActionSurface:)` with a
non-nil surface when `AppSurfaceConfig.current == .reader`
(`ActionButtonIntentSupport.doubleSaveSurface`); that threads
`doubleSaveActionSurface` into `ReadingListIngestor.handleSavePress`, which
resolves the configured action (`resolvedIntentAction`) and passes it as
`SavePressPolicy.decide(intentAction:)`:

- With `intentAction` non-nil, a repeat press within
  `SavePressPolicy.intentDoublePressWindow` (7 s) decides:
  - `.sendToKindle` → `.sendToEreaders([kindle])`, reusing the 24 h resend
    cooldown; ignored for platform items (no EPUB) or when Kindle isn't
    configured (resolver returns nil).
  - `.sendToFriends(emails)` → the ingestor emails the item via
    `EmailShareCenter.shared.send(item:to:)` (errors are logged to the
    diagnostic log, never fail the intent) → result `.sentToFriends`.
  - `.promptFriendSelector` → the ingestor records the pending friend prompt
    and returns `.friendPromptRequested`; the intent then foregrounds Luna
    itself via `ForegroundContinuableIntent.requestToContinueInForeground()`
    (no shortcut branch involved). On foreground,
    `SceneDelegate.applyPendingFriendPrompt()`
    consumes the prompt (only once the main UI is up, so onboarding never
    swallows it) and presents `SendToFriendSheet` for the item.
  - A repeat press with `intentAction` armed NEVER falls back into the legacy
    12 s regime (a 9 s repeat press is ignored, not sent).
- Resolver fallbacks: `preset` with no emails picked, or no sharing account
  configured → treated as `askEveryTime` (the sheet guides account setup);
  Kindle unconfigured → nil (repeat press ignored).

The legacy regime is unchanged for in-app saves: within 12 s, sends to every
configured destination whose App-Intents send mode is `.doubleSave`
(`ArticleSendCoordinator.doubleSaveDestinationIDs()`).

## Tests

- `SavePressPolicyTests` — both regimes: 6.9 s / 7.1 s boundaries, no legacy
  fallback at 9 s, Kindle cooldown + platform-item exclusion, friend send on
  platform items, prompt case.
- `DoubleSaveActionStoreTests` — defaults, round-trip, per-surface isolation,
  one-shot + expiring pending prompt.
