# Wave 2D — mail / social / onboarding animation

Read `PLAN.md` hard rules and `audits/mail-social.md` first. You exclusively own
`LunaSocialUI/OnboardingAnimationView.swift` this wave (Wave 1 deliberately skipped it).
One commit per item.

1. **Delete the orphaned legacy Action-Button-Settings scene** in
   `OnboardingAnimationView.swift` (audit finding: lines ~1457-1813, 357 lines —
   `legacyBuildActionButtonSettings`, `legacyAnimateActionButtonSettings`,
   `absOptionCard`, `darkActionRow`, and their 10 dedicated stored properties). Re-verify
   with grep that nothing outside that region references them. Also delete the dead
   `sheetShell` factory, and fix the now-dangling "Current"-vs-legacy comment framing the
   audit flagged (the surviving builder is just *the* builder — no qualifier needed).

2. **Split `OnboardingAnimationView.swift` into per-scene files** (audit top-10 #4): same
   type, extensions in sibling files (`OnboardingAnimationView+ActionButton.swift`,
   `+ActionExtension.swift`, `+SafariExtension.swift`, `+ShortcutInstall.swift`,
   `+ActionButtonSettings.swift`, `+SharedRows.swift` — adjust names to the actual scene
   seams you find). Members that were `private` but are needed across the new file
   boundary become `internal` with no added `public` surface. Pure move — the animation
   choreography must be untouched. Do NOT introduce a scene protocol or data-drive the
   scenes; the audit explicitly recommends against it (scenes are too bespoke).

3. **Generic App-Group JSON store helper** (audit top-10 #6): `FriendsStore`,
   `PendingRequestsStore`, `RecentFriendRecipientsStore` share identical
   `fileURL`/`mutationLock`/`save()` boilerplate — extract one generic helper (in
   `LunaSocial`, where all three live) preserving the exact lock→write→notify order.
   Existing store tests must stay green.

4. **`OnboardingFlow` observer-skeleton dedupe** (audit top-10 #9): the one-shot-advance
   + `ActionButtonOnboardingStore.stateDidChangeNotification` observer block duplicated
   verbatim between `shortcutInstallStep` and `actionButtonStep` → one shared helper.
   Preserve observer-removal timing exactly (the audit flags this as the risk).

5. **Rewrite `claudedocs/send-to-kindle.md`** (audit top-10 #2): it's corrupted with
   leftover Boox/OSS fragments and stale `Luna/Send/*` paths from commit `97833a34`.
   Read the actual send path (`LunaSend/ArticleSendCoordinator.swift`, EpubBuilder,
   MIMEMessage, the connected-account transport) and write the doc fresh to match the
   code as it exists.

Explicitly NOT in scope: `SendToFriendSheet.accountSetupLauncher` and
`ArticleEmailTransportProvider.make` stay closures (single-closure launch-time DI is this
codebase's blessed pattern per the app-shell audit); `ReadingListItem.sharedByUsername`
stays untouched (dead in production, but wiring or removing it is a product decision —
already on the master out-of-scope list).

Verification: build-for-testing per commit; at wave end run
`-only-testing:LunaTests/FriendsStoreTests -only-testing:LunaTests/OnboardingScreenTests`
plus any test file matching the types you touched (grep names in `LunaTests/`; the
onboarding animation itself has snapshot coverage via `OnboardingScreenTests` — snapshot
diffs mean you broke the pure-move rule: fix the code, never re-record).
