# Luna code-quality pass — plan (2026-07-02)

Branch: `email-sharing` (started clean at a29d848). Baseline `build-for-testing` green; suite last known green (892 tests, 2 intentional skips). Eight parallel review agents swept every production module; every finding below was re-verified against the code before fixing. Commits land in small logical chunks as each cluster is verified.

## Done (committed)

- **b2aa504** WKScriptMessageHandler retain cycles: `PlatformEmbedViewController`, `YouTubePlayerViewController`, `ProductSearchOverlayViewController` registered `self` strongly on the user content controller → VC + WKWebView leaked on every dismissal. Shared `WeakScriptMessageHandler` trampoline added in LunaDesignSystem.
- **4406d04** Dead code: `MediaPreviewFetcher.fetchPreview` chain; `WebStrategy.asBypassStrategy`.
- **3597b86** Dedupe: `trackerStores` (3 identical copies → `ProductInfo` extension); Instagram/Facebook parser `firstGroup`/`unescape` (→ file-private helpers).

## Cluster 1 — storage data safety (bug-high)

1. `ReadingListStore.decodeItems` returns `[]` on ANY decode error and `coordinatedMutate` then persists that empty list → one bad/new-enum-value item written by a newer sibling app **wipes the whole shared list**. Fix: per-item failable decode (skip undecodable items but keep their raw JSON out of harm — preserve by not rewriting when decode partially fails is complex; minimum: tolerant decoding + refuse to overwrite a non-empty file with `[]`).
2. Silent write failures: `encodeItems` `try?` write, `saveContent`, `setThumbnail` — UI state diverges from disk; `saveContent` flips `.ready` with no file. Fix: check write success, log via `SharedDiagnosticLog`, don't set file names on failure.
3. `restore(_:)` (catch-up Undo) replaces the entire list with a stale snapshot → deletes items saved concurrently by extensions/intents/mail import. Fix: merge-restore (revert only snapshot ids, keep unknown ids).
4. `PreloadStore` / `ImageReferenceStore` mutate shared App-Group JSON with only an in-process lock (extensions write too) → lost updates / refcount corruption. Fix: NSFileCoordinator around load-mutate-save like ReadingListStore.
5. `IncomingMailImporter.isRunning` unsynchronized check-then-set. Fix: NSLock test-and-set.
6. `IntentIngestHelper.handleSavePressWithTimeout` doesn't actually return at 12s (`withTaskGroup` awaits the slow leg). Fix: race via unstructured task + continuation.

## Cluster 2 — UIKit feature-lib bugs

7. `NavHeaderBar.textButton` never calls `addTarget` → every text header button (Done/Select All/Clear/…) inert. VERIFY first-hand, then fix.
8. `PriceTrackingViewController` cell-reuse: merge-highlight `backgroundColor` never reset → stray yellow rows. Fix: unconditional reset.
9. `PriceFetcher` WebViewPriceRenderer: navigation callback racing `awaitNavigation` leaks the continuation → price fetch hangs forever. Fix: check `didResume` inside the continuation body.
10. `DotMatrixTransitionSession`/`DotMatrixInteractivePopController`: interactive pop never calls `update/finish/cancelInteractiveTransition` on the context. Fix: forward them.
11. `reload()` doesn't refresh the price graph on `.readingListChanged`. Fix: call `refreshGraph()`.
12. `AlertThresholdSlider` commit missing `.touchCancel`. Fix: add.

## Cluster 3 — app shell bugs

13. `deleteAllArchiveTapped` action sheet without popover anchor → iPad crash. Fix: anchor (or `.alert`).
14. `StoneSettingsScreen` `SliderSpec` closures capture `self` strongly in stored lazy arrays → screen never deinits; CADisplayLink runs forever after GIF/video pick. Fix: capture the settings store, not self; teardown video in viewDidDisappear. Check DotMatrix/FrostedGlass screens for the same pattern.
15. CatchUp: (a) conflicting bottom-button constraints (inline copy at :277 vs lazy pair); (b) `performAction` double-commit (no reentrancy guard); (c) Undo = whole-list restore (fixed via Cluster 1.3 merge-restore).
16. Pasteboard suggestion: stale row not cleared on two early-return paths; not surface-gated (Price Tracker app suggests articles that then vanish on save). Fix both.
17. `AppDelegate.handleMailFetch`: expired BG task reports success and expiration handler installed late. Fix: mirror price handler.
18. `EmailLoginFlow.continueTapped`: no reentrancy guard during network autodiscovery (double-push), vestigial `throws`. Fix: disable button while resolving; drop throws.
19. Onboarding key literal duplicated in AppDelegate vs SceneDelegate. Fix: shared constant. Same for UITestSeeder's `"readingListFilter"`/`"readingListCollapsedSections"` keys.
20. Kindle SMTP password persisted to Keychain per keystroke. Fix: persist on `.editingDidEnd` only.
21. Misleading intent comments about removed share-suggestion token (LunaSafariPageIntent, FindYouTubeVideoIntent, SaveFromAppIntent). Fix comments; align return with save outcome where cheap. Also fix pre-existing `async but not awaited` warnings there.

## Cluster 4 — reader bugs

22. `ScrollReaderViewController.viewWillDisappear` persists ~100% progress during Phase-1 prefix render (missing `didLoadFullContent` guard). Fix: guard.
23. `RabbitHoleLayerViewController.setMode`/`audioToggled` re-embed from stale `descriptor.scrollOffset` (no `syncScrollOffset()` first) → position jump + overwrite. Fix: sync first.
24. `SpeechController.skipBackward` jumps to previous paragraph instead of start of current (offset==0 path). Fix: decide "at start" from current word index.
25. `RabbitHoleReaderViewController` overscroll-pop commits on **cancelled** gestures (missing `.ended` check that the edge-pop twin has). Fix: add check.
26. `VoiceFirstRunPrompt` fires even with enhanced voice installed. Fix: gate.
27. RabbitHole failed web load leaves blank card (`showLoadError` unreachable). Fix: show error from didFail delegates.
28. `RSVPViewController.chunkIndex(forWord:)` linear scan per spoken word. Fix: binary search.
29. WordMap vs RSVP `maxCharactersPerWord` index drift — REVIEW: fix only if low-risk mapping exists; otherwise document as deferred (cross-mode resume drift by a few words, no crash).

## Cluster 5 — mail/send bugs

30. `GraphMailTransport.fetchShares` filters `isRead eq false` while the auto-installed Outlook rule marks shares read → Outlook share import permanently broken. Fix: drop the isRead clause (cursor already dedupes).
31. `fetchShares` ignores `extraSenders`/`extraSubjects` → newsletter import no-op on Outlook. Fix: extend the $filter.
32. `StreamIMAPClient.open` leaks the stream task if greeting/TLS fails. Fix: close on throw.
33. `verifyCredentials` GETs `/v1.0/me` without `User.Read` scope (403 on valid token). Fix: use a mail endpoint.
34. Unbounded RFC 2047 encoded word + unfolded long headers (`X-Luna-Share`) can exceed 998-octet limit; `encodedHeaderText` duplicated in EmailMIMEBuilder + MIMEMessage. Fix: shared header-encoding helper that splits/folds; use from both.
35. `EmailAccount.fromHeader` doesn't escape quotes / strip CRLF (latent injection). Fix: sanitize.
36. SMTP watchdog caps whole exchange at 30s → large EPUB uploads killed mid-DATA. Fix: scale deadline with payload size (both SMTPClient and MailStream write timeout).
37. `StreamSMTPClient`: silent success when from/recipients missing → throw; AUTH errors discard server reply → attach last line.
38. Keychain `SecItemAdd/Delete` statuses ignored in EmailAccountStore + SendCredentialsStore. Fix: check + log.
39. `LunaShareMarker` doc comment wrong about wire format (says URL-safe padding-free; is standard base64). Fix comment.
40. `decodeEncodedWords`: no whitespace collapse between adjacent encoded words, ignores charset. Fix both (UTF-8 + ISO-8859-1 at minimum).

## Cluster 6 — content/epub bugs

41. `EpubBuilder`: duplicate image URLs → duplicate ZIP entries + manifest items → invalid EPUB. Fix: dedupe by fileName.
42. `PaywallUnlockRules.expandAlternations`: fan-out cap applied after full materialization; `contentRuleListJSON` recomputes per-source results for the dropped count. Fix: short-circuit inside expansion; single pass.
43. `SemanticIndexStore` eviction order is hash-random and can evict the just-inserted item. Fix: deterministic eviction excluding the new key.

## Cluster 7 — dead code sweep (all verified by repo-wide grep before deleting)

44. Mail: `GmailIMAPClient` instance machinery (protocol, outcome, connection code — keep static parsers + `IncomingMessage`); `MailProvider.selectable`.
45. Transitions/DesignSystem: `DotMatrixModalTransitioningDelegate` + `DotMatrixModalAnimator` (keep `DotMatrixModal`); `DotMatrixInteractivePopController.isActive`; `Toast` + AppDelegate animator wiring; `KeyboardAvoidance` (+ its tests); `NavHeaderBar.totalHeight`; `NavHeaderTableController.reloadHeaderControls`.
46. PriceUI: `AlertThresholdSlider.onChanged`; `bottomBarBottomCap`.
47. SocialUI: `SendToFriendSheet.present` unused `sourceView` param.
48. App shell: `tintAlphaRange`; unreachable `.kindleAddress` case; `DiagnosticsViewController.done()` dup; `SearchViewController.viewDidAppear` (never fires — view added without containment).
49. Storage/models: `ReadingListStore.deleteAllRead`; `setSharedBy` (+ decide `sharedByUsername` story — remove setter only); `PriceTrackerShare`; `PreloadStore.allEntries`, `.webArchive`/`archiveData`, `PreloadState.pending`, `PreloadEntry.updated`/`depthRemaining`; `PriceTracker.thresholdAbsoluteDrop`; `DiagnosticLog.exportCloudKitContainer`.
50. URL/content: `YouTubeURL.validated`; `URLClassification.platform(for:)`/`pathID` (drifted duplicate of PlatformRecognizer with a broken Instagram branch — retarget its test); `DotMatrixExampleViewController`.
51. ReaderUI: visible-link-URL publishing chain; `SpeechVoice.best`; `SpeechEngineFactory.make`; `VoiceEngineKind.displayName/summary` + unread `kind` requirement; `RabbitHoleLayout.Placement.interactive`; `InlineReaderPageViewController.shareProvider` (drop param).

## Cluster 8 — duplication & smells (small/medium only)

52. DotMatrix transitions: shared `transparentImage` + overlay setup helper (Appear/Disappear/Crossfade/Batch).
53. FriendsVC/RecipientPicker: shared add-email-recipient helper (alert + contact picker).
54. `presentMessage` dup in two PriceUI controllers.
55. Intents: `saveYouTube`/`saveMedia` re-inline the Find/Save intent bodies → shared helpers in LunaIntents.
56. `VoiceInstallLink`/`SystemSettingsLink` identical try-each-URL helpers → one.
57. `sendToFriend`/`sendMediaToFriend` identical actions → collapse.
58. `DiagnosticLog` vs `SharedDiagnosticLog` both append the same file with different locks → route one through the other.
59. HTMLClassification regex first-capture helper ×4 → one shared helper.
60. DateFormatter allocation per frame/row: PriceGraphView (draw + scrub), PriceTracking `refreshDescription`, ReplaysViewController → cached static formatters.
61. `WebJunkBlocker.applyRuleList` swallows compile errors → log.
62. Reader-close does 4 back-to-back whole-list RMW cycles → single batched store update.
63. Effect-screen doc-comment copy-paste errors in Stone/FrostedGlass ("Dot Matrix", nonexistent `gapColor`).
64. `LeadImageExtractor` vs `ArticleExtractor.leadImageURL` overlap — consolidate only if trivial; else note.

## Deliberately deferred (documented, not fixed now)

- **Settings effect screens ~450-line duplication** (DotMatrix vs FrostedGlass vs Stone) and **effect-view ~600-line triplication** (LunaContentRendering): correct fix is a parameterized base; too large/risky for this pass and heavily snapshot-covered. Deferred with this note.
- **SMTP client consolidation** (SMTPClient vs StreamSMTPClient): unifying transports risks the working Kindle path; the drift bugs (#36–37) are fixed in place instead.
- **Unknown-JSON-field passthrough for version skew** (storage agent #2): needs a schema-evolution design, not a patch.
- **0xdead10cc background assertions around coordinated writes**: needs a considered policy across all writers.
- Swift 6 concurrency migration; per-app dependency slimming (already documented in CLAUDE.md).

## Verification

- `xcodebuild build-for-testing` after each cluster; full `xcodebuild test -scheme Luna` on the booted iOS 26.2 iPhone 17 sim (45772338-…) at the end; snapshots re-recorded only for intentional UI changes.
