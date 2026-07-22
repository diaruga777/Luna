# Wave 6B — delete the Catch Up feature entirely

User directive: delete all catch-up card code and all references to it, leaving NO
comments about it (no tombstones, no "catch-up was removed" notes — the code should read
as if the feature never existed).

Read first: refactor-plans/audits/catchup-removal-map.md IN FULL — it has the verified
kill-list, the survivors, and a 10-step deletion order that keeps every commit
compiling. Follow that order. PLAN.md hard rules 2-6 apply (rule 1 is superseded: this
IS a behavior change, fully authorized).

Key specifics beyond the map's steps:

1. `rm -rf Luna/CatchUp/` (synchronized group — no pbxproj edit needed; verify by build).
2. `ReadingListViewController`: remove catchUpButton/catchUpBadge/catchUpTapped/
   updateCatchUpButton, the `CatchUpRouting` conformance, and the catch-up row from the
   table header. The header simply loses that row — let the layout collapse naturally;
   keep the large-title and filter rows exactly as they are. The badge's secondary
   "email not configured" nudge disappears with it — that is accepted; do NOT invent a
   replacement, and do NOT leave a comment about it.
3. `ReadingListSectioning`: delete `catchUpQueue`/`shouldShowCatchUpDot`/
   `catchUpDotUnreadThreshold` (map-verified: catch-up is the sole consumer). Trim the
   restored `ReadingListSectioningTests` accordingly (13 tests + the voice-dismissal
   setUp/tearDown).
4. `VoiceModelStore.hasDismissedVoiceCatchUp`: delete (sole consumer was catch-up).
   `VoiceInstallLink`, `ReadingListStore.bump(_:)`, `ReadingListItem.bumpDate`,
   `ArchiveUnlockFlow` all SURVIVE (independent callers) — only trim their doc comments
   where those mention catch-up, rewording to their surviving callers.
5. `PriceTracker.bestPriceStoreID`: delete IF it is computed or non-persisted; if it is
   a stored Codable field that round-trips through readingList.json, leave the stored
   field intact and delete only dead UI plumbing (persisted-data rule).
6. UITest surface: remove `.catchUp`/`.priceCatchUp` screens, the `.catchUpEligible`
   fixture, and related seeder paths.
7. Tests: split `CatchUpAndPriceScreenTests.swift` → `PriceTrackingScreenTests.swift`
   keeping the 9 price methods (and only the setUp/tearDown they need); delete the 4
   catch-up methods. Delete the orphaned `LunaTests/ReferenceImages/reading-list-catchup.png`
   and any other catchup-named reference PNGs.
8. Docs: remove catch-up mentions from CLAUDE.md (there is at least one: the
   snapshot-recording paragraph names `CatchUpAndPriceScreenTests` — update to the new
   test-file name; and the module-structure line "(ReadingListViewController/CatchUp)")
   and from claudedocs/*.md wherever the feature is described. Also purge
   refactor-plans mentions? NO — refactor-plans/ is a historical record; leave it.
9. Final sweep: `grep -rin "catchup\|catch-up\|catch up" --include="*.swift"` must
   return zero hits outside refactor-plans/ and git history; run the same over *.md
   (excluding refactor-plans/) and asset catalogs.

Verification: build-for-testing for all three app schemes (Luna, LunaDownloader,
LunaPriceTracker); then run the renamed PriceTrackingScreenTests, the trimmed
ReadingListSectioningTests, ReaderScreenTests, and InteropSettingsTests on the sim.
Snapshot rule: catch-up-related snapshots are deleted with their tests; every OTHER
snapshot must pass unchanged — EXCEPT the reading-list snapshots, which legitimately
change because the header row is gone. If a reading-list reference PNG fails for
exactly that reason, re-record ONLY those PNGs (TEST_RUNNER_RECORD_SNAPSHOTS=1, see
CLAUDE.md) and say precisely which you re-recorded and why. No other re-recording.
