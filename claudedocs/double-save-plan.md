# Double-save action — plan

> **Historical snapshot** (implemented; living doc: `double-save.md`). Intent
> names below predate the two-intent capture flow (`ProvideContextIntent`/
> `SaveIntent`, 2026-07) — see `app-intents.md`.

Feature: in **Luna Reader**, when the user saves the **exact same URL twice within
7 seconds via the Save App Intent** (Action Button path only — NOT share sheet /
action extension / Safari extension / mail import), trigger a configurable action:

- **Send to Kindle** (reuses the existing emailed send-to-Kindle pipeline), or
- **Send to Friend**, with a sub-setting:
  - **Preset friends**: one or more friends chosen in Settings; the item is emailed
    to them immediately (existing email-based friend-sharing machinery), or
  - **Ask every time**: the intent opens the Luna Reader app and navigates straight
    to the friend-selector share screen for that item.

## Decisions taken (flag if wrong)

- Setting default: **Send to Kindle** (the picker has exactly the two actions, per
  spec; there is no "off"). A double save that previously was just a redundant save
  now performs the chosen action.
- "Exact same URL": compare the *ingest-normalized* URL (whatever key the reading
  list already dedupes on), not the raw string — the same link saved twice should
  match even if the intent trims tracking params differently. Verify during recon;
  fall back to raw-string equality if there is no canonical form at intent time.
- Scope: Reader surface only (setting shown only in Reader's Settings; detection
  gated on `LunaApp.current` == reader).
- The 7s window + last-URL memory lives in App Group defaults so it survives the
  intent running before the app is foregrounded.

## Steps

1. **Recon** (read, no edits):
   - `Luna/Intents/SaveFromAppIntent.swift` + `LunaLibraries/Sources/LunaIntents/`
     — where a save lands, what identifies the URL at that moment, how the intent
     opens/foregrounds the app (it already relaunches Luna for onboarding's Action
     Button step), and how it interacts with `ActionButtonOnboardingStore`.
   - Send-to-Kindle entry point (`claudedocs/send-to-kindle.md` → the service the
     reader UI calls) — need a programmatic "send item X to Kindle" call.
   - Friend sharing (`claudedocs/social-sharing.md`, `SocialMessageCenter`,
     `FriendsViewController`, the share/friend-selector screen) — need (a) a
     programmatic "share item X to friends [emails]" call and (b) the existing
     navigation route to the friend-selector for an item (there is a
     `com.hsanabria.luna.friend` URL-scheme route; reuse it or the internal router
     in SceneDelegate/AppDelegate).
   - `Luna/Settings/SettingsViewController.swift` — row/picker patterns; how other
     stores back settings rows.
2. **Store** (`LunaLibraries/Sources/LunaStorage/`): `DoubleSaveActionStore`
   (App Group `UserDefaults`, keyed per surface like the other stores):
   - `action: .sendToKindle | .sendToFriend` (default `.sendToKindle`)
   - `friendMode: .preset(emails: [String]) | .askEveryTime`
   - plus `recordSave(url:at:) -> Bool` double-save detector: returns true iff same
     normalized URL was recorded < 7s ago (monotonic-safe: use Date but clamp
     negative deltas), then clears so a *third* save doesn't re-trigger.
3. **Intent hook** (`LunaIntents` + `Luna/Intents/SaveFromAppIntent.swift`):
   after a successful save in the intent path, ask the detector. On double-save:
   - `.sendToKindle` → call the Kindle send service for the saved item.
   - `.sendToFriend` + `.preset` → call the friend-share send for those emails.
   - `.sendToFriend` + `.askEveryTime` → open the app (App Intent
     `openAppWhenRun`/existing relaunch mechanism) and route to the friend-selector
     share screen with the saved item (injected closure installed in AppDelegate,
     same pattern as `SocialMessageCenter.ingestHandler`).
   - All fire-and-forget with diagnostics via `DiagnosticLog`; a failure must not
     fail the save intent itself.
4. **Settings UI** (Reader): "Double-Save Action" row → picker (Send to Kindle /
   Send to Friend). When Send to Friend: sub-rows — friend multi-select (from the
   existing friends store; disabled/empty state if no friends yet) and an
   "Ask every time" toggle/choice. Match existing Settings row idioms.
5. **Tests** (`LunaTests`): detector window edges (6.9s yes / 7.1s no / different
   URL no / third save), store round-trip + defaults, intent dispatch (mock the
   Kindle/friend send closures), surface gating. Snapshot for the new Settings
   rows if that's the existing pattern.
6. **Docs**: new `claudedocs/double-save.md` + pointer updates in
   `claudedocs/save-link-intent.md` / `app-intents.md`.
7. **Workflow**: implement on a worktree branch (`EnterWorktree`), build + full
   `LunaTests` on the iOS 26 sim (`DEVELOPER_DIR` Xcode 27 beta,
   `DIAGNOSE_MISSING_TARGET_DEPENDENCIES=NO`), verify live in sim (Action Button
   intent double-fire), then merge the branch to `main`. Known pre-existing
   failures to ignore: 6 in `ReadingListScreenTests` (cross-image `is` flake).
