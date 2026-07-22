# Catch-Up removal map

Read-only audit for a full deletion of the Catch-Up feature (swipe-card deck modal +
all references). Every claim below was verified with `grep -rn` against the working
tree, excluding `build/`, `.git/`, `.claude/` (which contains a stray
`.claude/worktrees/agent-a44f9578d823e01c8/` copy of the repo — ignore it, it is not
part of the tracked source tree and every "hit" there duplicates a real one below).

## 1. Core files — delete outright

`Luna/CatchUp/` (5 files, 1799 lines, all app-shell tier, all `PBXFileSystemSynchronizedRootGroup`
— no `.pbxproj` edits needed, confirmed no `CatchUp` string anywhere in
`Luna.xcodeproj/project.pbxproj`, so a plain `rm -rf Luna/CatchUp/` removes them from
the Xcode project too):

| File | Types declared |
|---|---|
| `CatchUpViewController.swift` (666 lines) | `CatchUpRouting` (protocol), `CatchUpViewController`, private `Phase`, private `ButtonRowDescriptor` |
| `CatchUpCardView.swift` (301 lines) | `CatchUpCardView`, its `Action` enum, private `Zone` enum |
| `CatchUpDeleteReadView.swift` (139 lines) | `CatchUpDeleteReadView` |
| `CatchUpSubviews.swift` (575 lines) | `CatchUpMessageView`, `CatchUpCardHeader`, `CatchUpMediaCardBody`, `PriceTrackerStoreRowsView`, `CatchUpPriceTrackerCardBody` |
| `CatchUpCardBodyFactory.swift` (118 lines, added in Wave 3C) | `CatchUpCardBodyFactory` enum + its `Result` struct |

Also delete `claudedocs/catch-up.md` (133-line dedicated feature doc). Nothing links to
it by filename (`grep -rln "catch-up.md"` across `claudedocs/*.md` and `CLAUDE.md` is
empty), so no dangling doc link.

## 2. Shared code that must survive — verified

Every type declared inside `Luna/CatchUp/*.swift` was grepped for callers outside that
folder. Result: **none of the 8 types/protocol is used outside `Luna/CatchUp/`** — the
whole directory is a self-contained leaf. The "known suspects" in the task turned out
to be one-way dependencies (CatchUp code calling OUT to shared infra, not the reverse):

- **`CatchUpCardHeader.text(for:)` / `ReaderViewController`'s inline header — NOT a real
  dependency.** `ReaderViewController` takes a generic `inlineHeaderSubtitle: String?`
  init param (`LunaLibraries/Sources/LunaReaderUI/ReaderViewController.swift:67,84,94,156`)
  and never references `CatchUpCardHeader` — it just renders whatever string it's
  handed. The only caller that passes `CatchUpCardHeader.text(for:)` into that
  parameter is `CatchUpCardBodyFactory.make` itself
  (`Luna/CatchUp/CatchUpCardBodyFactory.swift:56`), i.e. app-shell code calling its own
  sibling type, then handing a plain `String` across the library boundary. Other
  callers of `inlineHeaderSubtitle` use a literal string (`Luna/UITestScreen.swift:115`,
  `LunaTests/ReaderScreenTests.swift:75`, both `"Today · from alex"`). **Correction to
  make while deleting:** `refactor-plans/audits/app-shell.md:65-66` describes this as
  "also called by `ReaderViewController`'s inline header via
  `CatchUpCardHeader.text(for:)` — cross-library reuse" — that phrasing is imprecise
  (it's not cross-library reuse, `ReaderViewController` never sees the type); harmless
  to leave since that audit file is a historical snapshot, but don't let it mislead the
  deletion — `CatchUpCardHeader` has zero external callers and deletes cleanly.
  `ReaderViewController`'s `inlineHeaderSubtitle` param stays (still used by
  `UITestScreen.readerInlineHeader` and `ReaderScreenTests`).
- **`CatchUpPriceTrackerCardBody.makeThresholdReadout` / `AlertThresholdSlider.swift` —
  also one-way, the other direction.** `LunaLibraries/Sources/LunaPriceUI/AlertThresholdSlider.swift:11-14`
  has a doc comment naming `CatchUpPriceTrackerCardBody.makeThresholdReadout` as a
  second consumer of `AlertThresholdPillChrome` (`makePill()`/`makeTitleLabel()`, both
  `public`). This is CatchUp code CONSUMING shared `LunaPriceUI` infra, not the reverse
  — `AlertThresholdPillChrome` has its own primary consumer, the interactive
  `AlertThresholdSlider` used by the real price-tracking editor, and stays. **Action:**
  just delete the "(both … the catch-up card's read-only readout)" clause from that doc
  comment (lines 11-14) — no code change needed there.
- **`PriceTrackerStoreRowsView` / `CatchUpMediaCardBody`** — both confirmed
  self-contained, zero outside callers.
- **`PriceTracker.bestPriceStoreID` (in `LunaLibraries/Sources/LunaModels/PriceTracker.swift:133`)
  — becomes orphaned, recommend deleting too.** It is a `public` model property but its
  ONLY UI consumer is `PriceTrackerStoreRowsView.init` (`Luna/CatchUp/CatchUpSubviews.swift:354`,
  the "highlight the cheapest seller" row). No other price-tracking UI
  (`PriceTrackingViewController`, the reading-list row cell) reads it — confirmed via
  `grep -rln "bestPriceStoreID\|isBest\|lowestPrice\|cheapest"` over `LunaPriceUI` and
  `LunaReadingListUI`: no hits. It's exercised directly by 3 unit tests in
  `LunaTests/PriceTrackerTests.swift:48-70` (`testBestPriceStoreIDPicksTheLowestFetchedPrice`
  and two more under the `// MARK: - Best-price row (catch-up card highlight)` comment).
  Not required to delete (it's not catch-up-*named* so a literal grep for "catchup"
  won't flag it as a loose end), but it is genuinely dead once `CatchUp/` is gone —
  flagging so it isn't left behind as silent dead code. If deleted, remove the 3 tests
  and the `// MARK: - Best-price row (catch-up card highlight)` comment with it.

## 3. Entry points and references to remove

**`Luna/ReadingList/ReadingListViewController.swift`** — the reading-list-side half of
the feature, all confirmed exclusively catch-up-driven:
- `catchUpButton`/`catchUpBadge` properties (:170-171), `configureCatchUpButton()` (:635-660),
  `updateCatchUpButton()`/`updateCatchUpButton(items:)` (:665-675), `@objc func catchUpTapped()`
  (:683-686), private `catchUpQueue()` (:631-633).
- `showsCatchUpRow` (:145-147, `surface == .reader`) — this is the ONLY thing that puts
  a header row on Reader (Reader has no large title: `showsLargeListHeader` is false for
  `.reader`/`.priceTracker`). Deleting catch-up removes Reader's ENTIRE top-row entry
  point, not just a button — `rebuildTableHeader`'s `else if showsCatchUpRow` branch
  (:759-778) and the `showsLargeListHeader || showsCatchUpRow || showsFilter` guard
  (:718) need updating together, or Reader's table header collapses to whatever
  `showsFilter` alone still provides. This is a real layout decision for whoever does
  the deletion, not just a mechanical strip.
- Call sites to `updateCatchUpButton()`/`updateCatchUpButton(items:)`: `viewWillAppear`
  sets `catchUpButton.isHidden` (:259), `reload()` (:337), `setEditing` (:828),
  `deleteItemAnimated`'s batch completion (:940).
- `extension ReadingListViewController: CatchUpRouting {}` (in `CatchUpViewController.swift:24`,
  not in `ReadingListViewController.swift` itself) — just drop this one-line extension;
  the `openItem(_:presentingFrom:)` method it "conforms via" (`ReadingListViewController.swift:1269`)
  is ReadingListViewController's own real method (its own row-tap flow at :1218 calls
  it directly) and stays untouched.
- **Dual-purpose badge caveat:** `updateCatchUpButton(items:)` (:669-675) ORs the
  catch-up-dot condition with `!EmailAccountStore.shared.isConfigured` — the badge also
  nudges "set up email" until an account is connected, and tapping it opens
  `CatchUpViewController`, whose `viewDidLoad` shows an email-setup overlay FIRST when
  unconfigured (`CatchUpViewController.swift:117-174`, `presentEmailSetupCardIfNeeded`).
  Deleting catch-up wholesale removes this nudge path entirely. Email setup is still
  reachable via Settings → `EmailAndKindleSettingsScreen` and the onboarding flow's
  skippable email step (per `CLAUDE.md`), so nothing is functionally broken, but this
  is a UX regression worth a conscious call rather than a silent side effect — flag it
  to whoever approves the deletion, don't just quietly drop it.

**`Luna/UITestScreen.swift`**:
- `case catchUp` (:32) and `case priceCatchUp` (:51) both build `CatchUpViewController`
  directly (:151-161 and :95-103). `priceCatchUp` **is** catch-up-dependent — its own
  comment says "Catch-up showing only a price-tracker card (for verifying that card's
  layout)"; it filters the store to price trackers and hands them to
  `CatchUpViewController(unread: trackers, router: router)`. Both cases die together.
- `PresentingHostViewController` (:174-210ish) — the deep-link-then-present-modal
  harness class — **survives**, it's also used by `.readerNested` (:117-134). Only its
  two catch-up call sites go away.
- The class doc comment at :22-25 lists `CatchUpViewController(unread:router:)` as an
  example construction seam — update/drop that line.

**`Luna/UITestFixtures.swift`**:
- `UITestState.catchUpEligible` case (:27) and `UITestFixtures.catchUpFixture()`
  (:206-…, under `// MARK: - Catch-up eligible (12+ unread renderable)`) — used only by
  `LunaTests/CatchUpAndPriceScreenTests.swift:41,75` (both catch-up tests being deleted,
  see §5). Delete the case, its `fixture(for:)` switch arm, and the builder function.
  `.mixed` and `.priceTracking` fixture states are used far more broadly (price editor
  tests, reader tests, etc.) — untouched.

**`Luna/UITestSeeder.swift`** — only a comment mentions catch-up's "Sim Bump" debug hook
(:43); no functional code. Just reword the comment (it's explaining why UI-test launches
suppress simulator-only debug controls in general — the sentence structure survives
minus the catch-up example).

**`LunaLibraries/Sources/LunaStorage/ReadingListStore.swift`**:
- `restoreCatchUpState(from:)` (:646-661, under `// MARK: - Catch-up`) — its ONLY
  caller is `CatchUpViewController.swift:643` (the "Undo" action). Dies with catch-up.
- `bump(_ itemID: UUID)` (:630-638) **survives** — called both by
  `CatchUpViewController.swift:384` (dying) AND by
  `ReadingListViewController.swift:1432` (`bumpToTop:` closure on the reading-list row's
  own swipe action, independent of catch-up). Keep the method; just rewrite its doc
  comment (currently says "shows the bump date on future catch-up cards") and drop the
  `// MARK: - Catch-up` section header (rename to something like `// MARK: - Bump / undo`,
  keeping only `bump(_:)` under it).
- `ReadingListItem.bumpDate` (model field, `LunaLibraries/Sources/LunaModels/ReadingListItem.swift:72`)
  **survives** — read by `Luna/Reader/ArticleCardsViewController.swift:401` (the
  independent card-carousel's own sort-by-recency) and
  `Luna/Mail/Intents/ArticleEntity.swift:59` (`savedDate` for App Intents), in addition
  to `ReadingListSectioning.catchUpQueue`'s sort (dying). Only the doc comment on the
  property (:70-71, "shown … on its catch-up card") needs a wording pass.

**Settings** — no dedicated catch-up settings screen exists. The only settings-adjacent
touch point is the shared `VoiceInstallLink` (see §4).

**App Intents** — no App Intent in `Luna/Intents/` or `LunaLibraries/Sources/LunaIntents/`
references catch-up (confirmed by grep; the only "unread" App Intents logic is
`ReadArticleIntent`'s own "latest unread article" selection via `ArticleMatcher`, which
is unrelated — it doesn't call `ReadingListSectioning.catchUpQueue` or any CatchUp type).

**Everything else the broad grep surfaced, triaged:**
- `Luna/Downloader/SavedMediaCardsViewController.swift:41,85` — false positives, plain
  English "catch up on activation" in unrelated comments about Darwin-notification
  suspension. No change needed.
- `refactor-plans/*.md`, `CODE_REVIEW_PLAN.md`, `PERF_REVIEW_PLAN.md`, `AGENTS.md` —
  historical audit/planning snapshots, not living docs. `CLAUDE.md`'s
  "keep them current" instruction is scoped to `claudedocs/`, not `refactor-plans/`.
  Recommend leaving these as-is (they're dated project history); at most, whoever does
  the deletion could add one line to the newest relevant plan noting the removal, but
  it's not required for correctness. **`AGENTS.md` is the one borderline case** — it's a
  live agent-instructions file (mirrors `CLAUDE.md` content) with 3 catch-up mentions
  (module-structure line, one skip-list line, one `ReadingListSectioningTests.testDot*`
  line) that should be updated alongside `CLAUDE.md` itself if `CLAUDE.md` documents
  catch-up anywhere (a quick check: it doesn't currently — `CLAUDE.md`'s only match in
  the earlier grep was the file listing itself, not feature prose).
- `claudedocs/card-carousel.md:226-228` — documents that the card-carousel root
  deliberately has NO catch-up entry point (`ArticleCardsViewController` never
  references CatchUp at all, confirmed by grep). Needs its parenthetical
  ("and no catch-up entry — catch-up remains on the list root … `CatchUpRouting`
  protocol") trimmed once the thing it's contrasting against no longer exists.
- `claudedocs/codebase-audit-2026-07.md:85`, `claudedocs/email-login.md:8`,
  `claudedocs/readers.md:253,283`, `claudedocs/reading-list.md:31,35`,
  `claudedocs/simulator-testing.md:40-43`, `claudedocs/ui-testing.md:46,66,75,119,122` —
  all living feature docs with real prose about catch-up; each needs its catch-up
  passages removed/rewritten (not just the string "catchup") since `CLAUDE.md` requires
  `claudedocs/` to stay current. `claudedocs/ui-testing.md:122` in particular documents
  the `CatchUpAndPriceScreenTests` table row that needs to shrink to price-only (§5).

## 4. Adjacent logic — dependency verdicts

| Logic | Verdict | Detail |
|---|---|---|
| `ReadingListSectioning.catchUpQueue(items:)` | **Delete.** | Only consumers: `ReadingListViewController.catchUpQueue()` (:632, dying), `UITestScreen.swift:158` (dying), and its own tests (§5). No other production caller. |
| `ReadingListSectioning.shouldShowCatchUpDot(items:)` | **Delete.** | Only consumer: `ReadingListViewController.updateCatchUpButton(items:)` (:672, dying) + its own tests (§5). |
| `ReadingListSectioning.catchUpDotUnreadThreshold` (= 10) | **Delete.** | Only used inside `shouldShowCatchUpDot` itself. |
| `VoiceModelStore.hasDismissedVoiceCatchUp` (flag + key) | **Delete.** | Consumers: `ReadingListSectioning.shouldShowCatchUpDot` (dying), `CatchUpViewController.swift:416,566,580` (dying), and `LunaTests/ReadingListSectioningTests.swift`'s class-level `setUp`/`tearDown` (dying, see §5). `VoiceModelStore.isAppleEnhancedInstalled` and `hasSeenVoicePrompt` are unrelated and survive untouched (used by `VoiceSettingsScreen`, `VoiceFirstRunPrompt`). Update the type's header doc comment (:9-13, "the catch-up voice-card dismissal flag") when the property goes. |
| `VoiceInstallLink` (`Luna/Settings/VoiceInstallLink.swift`) | **Survives.** | Genuinely shared: `VoiceSettingsScreen.swift:79` AND `CatchUpViewController.swift:579` both call `VoiceInstallLink.open()`. Only drop the doc comment's "(both main-app surfaces)" framing that names the catch-up voice card (:12-13) — the enum itself is untouched. |
| `ArchiveUnlockFlow.present(...)` (`LunaLibraries/Sources/LunaArchiveReader/ArchiveUnlockFlow.swift`) | **Survives.** | Multiple independent call sites: `Luna/SceneDelegate.swift`, `ArticleCardsViewController.swift:498`, `ReadingListViewController.swift:1440`, `ShareSurfaceDriver.swift`, `ShareReaderViewController.swift`, plus `CatchUpViewController.swift:360` (dying). Its doc comment (:14, "rebuild a catch-up card") lists catch-up as one of several callers' own post-unlock behaviors — just trim that one example, the flow itself is unaffected. |
| `AudioQueueRule` / audio auto-advance-next-unread | **Unrelated, no action.** | Lives in `Luna/AudioPlaybackWiring.swift` + `LunaLibraries/Sources/LunaIntents/ArticleReadability.swift`, tested by `LunaTests/AudioQueueRuleTests.swift`. Grepped for any CatchUp/catch-up reference or import — none. It has its own, unconnected notion of "next unread" for read-aloud auto-advance. |
| `ArticleCardsViewController` (the alternate card-carousel reading-list root) | **Unrelated, no action.** | Zero references to any CatchUp type or `catchup`/`catch-up` string (grep-verified). Confirmed by `claudedocs/card-carousel.md:226-228` itself: the cards root deliberately has no catch-up entry; catch-up stays on `ReadingListViewController` only. It independently reads `bumpDate`/`rendersAsReader` (surviving shared helpers), not `catchUpQueue`. |
| `PriceTracker.bestPriceStoreID` | **Becomes dead — recommend deleting** (see §2). | Not literally named "catchup" so a naive grep sweep misses it; flagging here so it isn't silently orphaned. |
| Generic `unread`-reading code elsewhere (`ReadArticleIntent`, `ArticleMatcher`, `RabbitHoleLayerViewController`'s own-mark reversion, `ReadingListStore.unarchive`) | **Unrelated, no action.** | Each is its own independent "unread" concept (App Intents suggestion, RabbitHole's own auto-mark-then-revert, archive-section unarchive). None calls into `ReadingListSectioning.catchUpQueue`/`shouldShowCatchUpDot` or any CatchUp type. |

## 5. Tests and fixtures

**`LunaTests/CatchUpAndPriceScreenTests.swift`** (291 lines) — methods split cleanly by
the file's own `// MARK:` sections:

- **Catch-up (delete):** `testCatchUpCardStackSnapshot`, `testCatchUpWithLockedCardSnapshot`,
  `testCatchUpPriceTrackerCardSnapshot`, `testCatchUpLayoutHasOnScreenContent` (lines
  ~40-87, under `// MARK: - Catch-up`).
- **Price-tracking editor (must survive):** `testPriceTrackingEditorSnapshot` (skipped),
  `testPriceTrackingAlertingEditorSnapshot` (skipped),
  `testPriceTrackingEditorLayoutHasStoreList`, `testExistingModeBackPopsAndNoReadInstead`,
  `testExistingModeEnablesInteractivePopBackToReadingList`,
  `testCreationModeReadInsteadDiscardsTrackerAndPops`,
  `testMergeModeReadInsteadRevertsOnlyAddedSeller`, `testExtensionHostShowsDoneInAppShowsBack`,
  `testOpeningAlertingTrackerMarksAlertViewed` (lines ~89-282).
- **`setUp()`'s dummy email account** (:20-29, "so Catch-Up exercises the card deck
  rather than the set up email overlay") is catch-up-only setup — confirmed
  `PriceTrackingViewController` never reads `EmailAccountStore` (grep-verified against
  `LunaLibraries/Sources/LunaPriceUI/*.swift`, no hits). Drop it (and the matching
  `tearDown()` clear) when the catch-up tests go.
- **Proposed split:** rename the file to `PriceTrackingScreenTests.swift`, delete the
  4 catch-up methods + the email-account setup/teardown, drop the `LunaMailAccount`
  import if nothing else in the file needs `EmailAccount`/`MailProvider` (check after
  trimming), and update the file-header doc comment (:5-6, currently "Snapshot +
  navigation/layout coverage for the catch-up card stack and the price-tracking
  editor.") to describe price-tracking only. This keeps every price test's git blame/
  history in one continuous file rather than a fresh one — either a `git mv` +edit or
  a plain edit-in-place both work; a `git mv` preserves history slightly better.
- **Reference PNGs:** `LunaTests/ReferenceImages/catchup-cards.png`,
  `catchup-mixed.png`, `catchup-price-tracker.png` — each is the named snapshot for one
  of the 4 deleted tests (`assertSnapshot(..., named: "catchup-cards")` etc. at
  :47,57,71) — delete all 3 alongside the tests.
- **`LunaTests/ReferenceImages/reading-list-catchup.png` is ALREADY ORPHANED** —
  grepped for the literal string `"reading-list-catchup"` across every `.swift`/`.md`/
  `.json` file in the tracked tree: zero hits. `git log --all -- ...reading-list-catchup.png`
  shows its only touch is the historical `04f7fc0c` mass rename commit — no test
  currently produces or asserts this snapshot name. Delete it as pre-existing dead
  weight (independent of this task, but since you're already cleaning the directory,
  worth sweeping).

**`LunaTests/ReadingListSectioningTests.swift`** (389 lines) — catch-up-specific
pieces to delete:
- Class-level `priorDismissedVoiceCatchUp` property + its `setUp`/`tearDown` handling
  (:16-30) — exists solely to neutralize `shouldShowCatchUpDot`'s orthogonal voice
  trigger; becomes uncompilable once `VoiceModelStore.hasDismissedVoiceCatchUp` is
  deleted (§4), so it must go together.
- `// MARK: - catchUpQueue` section: `testCatchUpExcludesRead`,
  `testCatchUpIncludesUnopenedAndOpened`, `testCatchUpExcludesPendingArticle`,
  `testCatchUpIncludesLockedArticle`, `testCatchUpExcludesFailedArticle`,
  `testCatchUpIncludesNonReaderRegardlessOfState`, `testCatchUpSortsOldestFirstByDateAdded`,
  `testCatchUpUsesBumpDateOverDateAdded` (~lines 274-320).
- `// MARK: - shouldShowCatchUpDot` section: `testDotHiddenBelowThresholdWithNoLockedSave`,
  `testDotShownAtThreshold`, `testDotShownForLockedSaveBelowThreshold`,
  `testDotIgnoresReadItemsTowardThreshold`, `testDotIgnoresReadLockedSave` (~lines 326-350).
- Everything else in the file — `assignSections`/`Section`/`ListFilter`/
  `shouldShowFilter`/`hasMediaAndLinks`/`hasPriceTrackers`/`topUnviewedAlertingPriceTracker`
  tests, plus the trailing "Section ordering / identity" block (:354-389) — is
  unrelated to catch-up and stays untouched. The private `article(...)`/`platformItem()`
  fixture builders (used by both the dying and surviving tests) stay; the
  `bumpDaysAgo` parameter on `article(...)` becomes unused by the surviving tests but
  is harmless to leave (or trim if you want a clean diff — it's only referenced by the
  two dying `catchUpQueue` sort tests, confirmed by grep).

**`LunaTests/PriceTrackerTests.swift`** — the `// MARK: - Best-price row (catch-up card
highlight)` comment (:46) and its 3 tests are about the MODEL property
`bestPriceStoreID`, not catch-up UI; keep the tests, just reword the stale MARK comment
(or delete all 4 together if you take the §2 recommendation to drop `bestPriceStoreID`
as dead code).

**`LunaTests/OnboardingScreenTests.swift`** — checked directly, zero catch-up
references. No overlap.

**Fixtures recap:** `UITestState.catchUpEligible` + `UITestFixtures.catchUpFixture()`
die (§3); `.mixed` and `.priceTracking` survive (used broadly elsewhere, unaffected).

## 6. Deletion order (every intermediate commit compiles)

1. **Tests first** (removing consumers before producers keeps the tree buildable at
   each step, and a test-only commit is trivially revertable):
   - Delete the 4 catch-up methods + email-account setup/teardown from
     `CatchUpAndPriceScreenTests.swift`; rename remaining file to
     `PriceTrackingScreenTests.swift`.
   - Delete the catch-up `MARK` sections + `priorDismissedVoiceCatchUp`
     setUp/tearDown from `ReadingListSectioningTests.swift`.
   - Delete `catchup-cards.png`, `catchup-mixed.png`, `catchup-price-tracker.png`,
     `reading-list-catchup.png` from `LunaTests/ReferenceImages/`.
2. **UI-test harness:** remove `.catchUp`/`.priceCatchUp` from `UITestScreen.swift`
   (both the enum cases and their `rootViewController(for:)` arms + the doc-comment
   example); remove `.catchUpEligible` + `catchUpFixture()` from `UITestFixtures.swift`;
   reword the `UITestSeeder.swift` comment.
3. **`ReadingListViewController.swift`:** remove `catchUpButton`/`catchUpBadge`,
   `configureCatchUpButton`/`updateCatchUpButton`/`catchUpTapped`/`catchUpQueue`, the
   `showsCatchUpRow` branch in `rebuildTableHeader` (deciding what Reader's top row
   becomes — a design call, not mechanical), and all call sites
   (`viewWillAppear`/`reload`/`setEditing`/`deleteItemAnimated`). This is the step that
   most needs a human design decision (Reader's header row), so do it as its own
   reviewable commit.
4. **Delete `Luna/CatchUp/` wholesale** (all 5 files) — by now nothing outside the
   folder references any type in it, so the whole directory is a leaf; this compiles
   immediately after step 3 (the `extension ReadingListViewController: CatchUpRouting {}`
   line disappears with the file that declares the protocol, and step 3 already
   dropped the conforming call sites).
5. **`ReadingListStore.swift`:** delete `restoreCatchUpState(from:)`; keep `bump(_:)`
   but move it out from under the `// MARK: - Catch-up` header and reword its doc
   comment; reword `ReadingListItem.bumpDate`'s doc comment in `LunaModels`.
6. **`ReadingListSectioning.swift`:** delete `catchUpQueue`, `shouldShowCatchUpDot`,
   `catchUpDotUnreadThreshold`; update the enum's header doc comment (:10-13, "which
   items qualify for catch-up, and when the catch-up … dot lights up").
7. **`VoiceModelStore.swift`:** delete `hasDismissedVoiceCatchUp` (property + key);
   reword the type's header doc comment; reword `VoiceInstallLink.swift`'s comment.
   (Must come after step 6 and the test deletions in step 1, since both currently read
   this flag.)
8. **Optional cleanup** (recommended, not required): delete
   `PriceTracker.bestPriceStoreID` from `LunaModels` and its 3 tests +
   `PriceTrackerStoreRowsView`-highlight `MARK` comment in `PriceTrackerTests.swift`
   (only safe after step 4 removes its one UI caller).
9. **Docs:** delete `claudedocs/catch-up.md`; edit catch-up passages out of
   `claudedocs/card-carousel.md`, `claudedocs/codebase-audit-2026-07.md`,
   `claudedocs/email-login.md`, `claudedocs/readers.md`, `claudedocs/reading-list.md`,
   `claudedocs/simulator-testing.md`, `claudedocs/ui-testing.md`; trim the 3 catch-up
   lines out of `AGENTS.md`. Leave `refactor-plans/*.md`, `CODE_REVIEW_PLAN.md`,
   `PERF_REVIEW_PLAN.md` alone (historical, out of `CLAUDE.md`'s "keep current" scope).
10. **Final full-suite run** per `CLAUDE.md`'s recipe (`xcodebuild test -scheme Luna
    -destination "platform=iOS Simulator,id=$SIM" -configuration Debug
    -derivedDataPath "$DD" DIAGNOSE_MISSING_TARGET_DEPENDENCIES=NO`), expecting the
    test count to drop by 4 (catch-up snapshot/layout tests) + 8
    (`catchUpQueue`) + 5 (`shouldShowCatchUpDot`) = 17 fewer tests than the
    currently-documented 918/8-skipped baseline (918 → 901, skip count unchanged at 8
    unless you also take the optional `bestPriceStoreID` cleanup, which is a net-zero
    rename of 3 tests, not a removal).
