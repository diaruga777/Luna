# Wave 6A — one Swift platform matcher + one lockstep JS mirror

User directive: exactly two platform/URL-matching implementations — one Swift, one
JavaScript (Safari extension content script) — behaving IDENTICALLY. The investigation
(refactor-plans/audits/platform-matching.md — read it in full first) established that
native messaging cannot replace the JS (synchronous per-pageload DOM work + 1000ms
Reddit soft-nav poll), so the end state is: `PlatformRecognizer` as the single Swift
source of truth, and `content.js` matching driven by a table GENERATED from the Swift
source, enforced by a parity test — the exact pattern `news_hosts.generated.js` +
`NewsSitesJSParityTests` already uses.

Behavior changes ARE authorized where the two implementations currently disagree — the
mandate is identical behavior. List every user-visible change in your report.

Work items, one commit each:

1. **Swift consolidation onto `PlatformRecognizer`** (audit migration list items):
   - `XLink`'s fixed 5-host set → delegate host recognition to `PlatformRecognizer`
     (keep XLink's post-ID/parsing duties). Same for any other `Luna Platforms` link
     type with live callers whose host predicate drifts.
   - `InstagramLink`/`FacebookLink`: zero production callers per the audit — re-verify
     with your own grep, then delete the types and their tests (dead code).
   - `SocialPostFinder.Platform`'s independent table → derive from `PlatformRecognizer`.
   - The loose `.contains("tiktok")` Referer heuristic in `mediaAssetRequest`: leave it
     ONLY if routing through the recognizer would change behavior for CDN asset hosts
     (check what hosts actually flow through); otherwise unify. Explain your call.
2. **Add generation**: extend `scripts/` (find the existing news-hosts generator —
   likely a script or a test that regenerates; follow its exact mechanism) to emit
   `platform_hosts.generated.js` (or extend the existing generated file) from
   `PlatformRecognizer`'s tables: per-platform host lists, short-link domains, and the
   path-shape predicates content.js needs (post vs feed etc.). Keep the generated file
   minimal — data, not logic.
3. **Rewrite `content.js`'s `recognizedPlatformPage`/`hostMatches`** to consume the
   generated table, mirroring `PlatformRecognizer`'s semantics exactly (subdomain
   suffix rules, short-links, path requirements). Remove Spotify / Apple Music /
   Apple Podcasts recognition — Swift has no such platforms, so the extension currently
   offers a download the app cannot perform; identical behavior means they go.
   (content.js's PaywallDetector/ProductPageDetector mirrors are OUT of scope — platform
   matching only.)
4. **Parity test**: extend/clone `NewsSitesJSParityTests` into a platform-hosts parity
   test that fails whenever the generated JS and `PlatformRecognizer` diverge (parse the
   generated file, compare against the Swift tables, and run a fixture-URL matrix —
   including the drift URLs from the audit's matrix — through both semantics).
5. **Docs**: if claudedocs mention the Safari extension's matching, update; note the
   generation step wherever the news-hosts generation is documented.

Verification: build-for-testing; then run the parity test, `LunaURLClassificationTests`,
`SocialMediaResolverTests`, `LiveMediaDownloadJobTests`, `SavedMediaStoreTests`, the
restored `ReadingListSectioningTests` + `SurfaceParityTests`, and any LunaPlatforms
tests. The Safari extension has no test target — the parity test IS its safety net;
also `plutil`-style sanity: run `node --check` on the edited JS if node exists, else
careful review.
