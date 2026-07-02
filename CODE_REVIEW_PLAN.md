# Luna code-quality pass — final report (2026-07-02)

Branch: `email-sharing`, commits `b2aa504..632882b` (11 commits on top of a29d848).
Process: eight parallel review agents swept every production module; every finding was re-verified against the code before fixing; work landed in severity order as small logical commits, each gated on a green build and the affected test suites. Full-suite result at the bottom.

## Commits

1. **b2aa504** — WKScriptMessageHandler retain cycles (embed player, YouTube player, product-search overlay) → shared `WeakScriptMessageHandler`.
2. **4406d04** — dead `MediaPreviewFetcher.fetchPreview` chain; `WebStrategy.asBypassStrategy`.
3. **3597b86** — dedupe `trackerStores` ×3 → `ProductInfo` extension; Instagram/Facebook parser helpers.
4. **4654f75** — **shared-store data safety**: decode-failure no longer wipes `readingList.json` (per-row failable decode, version-skew-tolerant enums, refuse-to-rewrite-unreadable-file); write failures logged and state kept honest; catch-up Undo merge-restores instead of clobbering concurrent saves; `PreloadStore`/`ImageReferenceStore` mutations now file-coordinated across processes; mail-importer coalescing made atomic; intent 12 s timeout actually returns at 12 s.
5. **4a22815** — UIKit lib bugs: `NavHeaderBar.textButton` never wired its action (every text header button was inert); cell-reuse yellow tint; `PriceFetcher` continuation hang; interactive-pop transition contract; `.touchCancel` commit; cached formatters; rule-compile-failure logging.
6. **779424f** — app-shell bugs: iPad action-sheet crash; StoneSettingsScreen 36-closure retain cycle (leaked CADisplayLink/AVPlayer); catch-up constraint conflict + double-commit; pasteboard stale-row + surface gating; BG-task expiration honesty; EmailLoginFlow re-entry; per-keystroke Keychain writes; shared defaults-key constants.
7. **365d7ef** — reader bugs: false 100% progress on prefix-render close (+ batched exit writes); RabbitHole stale-offset jumps on mode/audio switch; cancelled-gesture pop commit; `skipBackward` overshoot; RSVP↔scroll word-index drift (token↔frame maps); reused-shell share view; voice nudge gating; blank-card error state; binary-search chunk lookup.
8. **6197673** — mail/send: Outlook share import was permanently broken (`isRead eq false` vs the rule that marks read); `extraSenders`/`extraSubjects` honored; IMAP socket leak; `verifyCredentials` scope mismatch; RFC 2047/5322 header encoding consolidated + made correct (folding, encoded-word splitting, From-name escaping, whitespace-tolerant marker); size-scaled SMTP timeouts + chunked writes; AUTH errors carry server replies; silent no-recipient "success" now throws; Keychain failures logged; dead IMAP client machinery removed.
9. **eb82df3** — content: duplicate EPUB image entries; expansion cap enforced inside `expandAlternations`; deterministic semantic-index eviction.
10. **a605d9b** — dead-code sweep (~25 items, each verified by repo-wide search — see commit message).
11. **632882b** — dedupe/smells: one UA constant, one regex-capture helper, shared intent save bodies, shared recipient prompts, shared price alert, unified settings deep-link walker, one diagnostics file lock, cached formatters, corrected effect docs.

## Deliberately deferred (unchanged from plan)

- Settings effect-screen ~450-line duplication (DotMatrix/FrostedGlass/Stone) and effect-view ~600-line triplication in LunaContentRendering — needs a parameterized base, too large/risky for this pass.
- SMTP client consolidation (`SMTPClient` vs `StreamSMTPClient`) — drift bugs fixed in place; unifying transports risks the working Kindle path.
- Unknown-JSON-field passthrough for cross-version field preservation — schema-evolution design work.
- 0xdead10cc background assertions around coordinated App-Group writes — needs a policy across all writers.
- `LeadImageExtractor` vs `ArticleExtractor.leadImageURL` conceptual overlap — different mechanisms (regex vs SwiftSoup), consolidation not mechanical.
- Swift 6 strict concurrency; per-app dependency slimming (already documented in CLAUDE.md/Package.swift).

## Verification

- `xcodebuild build-for-testing` green after every cluster.
- Affected test suites run green per cluster; full `LunaTests` suite run at the end (result recorded in the session).
