# Wave 2C — ingest / classification / storage dedups

Read `PLAN.md` hard rules and `audits/ingest-pipeline.md` §2.2 (groups A-M), §3 first.
This area survived two prior review passes — the bar for touching it is higher, and the
tests encode exact behavior. One commit per item.

**Prime directive here: consolidate only where implementations are byte-identical or
provably equivalent. The audit CONFIRMED behavioral drift between `PlatformRecognizer`
and `LunaPlatforms`' `XLink`/`RedditLink`/`InstagramLink` matching — do NOT unify
drifted predicates; that changes which URLs match.**

1. **Amazon currency table** (§2.2 G): the byte-for-byte duplicate
   `AmazonPriceRule`/`amazonCurrency(forHost:)` table in `ProductPageDetector.swift` and
   `ProductMetadataExtractor.swift` (same module) → one internal shared definition.

2. **Host matching, identical subset only** (§2.2 A/B): introduce one helper (sibling of
   `URLCanonicalizer` in `LunaURLClassification`, e.g. `HostMatching.hostSuffixMatches`/
   `normalizedHost` covering the `www.`-strip + trailing-slash + case rules) and migrate
   ONLY the call sites whose current logic is exactly equivalent (the audit's §2.2 B
   ≥6-file list). For the drifted platform-link predicates, leave the code as is and add
   a one-line comment at each drifted site stating that its matching deliberately differs
   from `PlatformRecognizer` (cite the counterpart) so the drift is at least visible.
   Every migrated call site: reason through (and note in the commit message) why
   equivalence holds. `LunaURLClassificationTests` + platform tests must stay green.

3. **Extraction-heuristic dedups, identical subset only** (§2.2 D/E/F): embedded-blob
   scanners, resolve-URL-against-base, and meta-tag lookup — consolidate the copies that
   are identical; skip the JSON-tree-walker sorted/unsorted unification (§2.2 C) entirely
   (determinism difference = behavior). `ProductPageDetectorTests`' 3 determinism
   assertions and `ArticleExtractorTests` must stay green.

4. **`ReadingListIngestor` interop-branch dedupe** (§2.2 K): merge the near-duplicate
   blocked/needsInstall branch logic between `ingest` and `saveNewWithContent` into one
   private helper. `ReadingListIngestorInteropTests` asserts exact ordering — preserve
   the sequence of store writes vs. presenter calls precisely.

5. **`TrailingDotBypass`/`PaywallBypassRules` collapse** (§2.2 I): merge the two (one is
   a thin duplicate of the other per the audit); merge or retire the duplicate test file
   so coverage is not lost.

6. **`LunaStorage` coordinated-mutate unification** (§2.2 H): one generic
   `NSLock`+`NSFileCoordinator` mutate wrapper shared by `ImageReferenceStore.mutate` and
   `PreloadStore.mutate`. Leave `ReadingListStore`'s richer variant alone.

7. **`testDefaultsOverride` copy-paste** (§2.2 M): fold the duplicated test-seam into one
   shared spot within `LunaStorage`.

Deferred (report only): `LunaPlatforms` fetch-JSON boilerplate (§2.2 J);
`OutcomePresenter`/`ShareSurfaceDriver.present` cross-module shape (blocked by layering);
`ReadingListStore` 5-dictionary send-state machine.

Verification: build-for-testing per commit; at wave end run the module suites:
`-only-testing:LunaTests/ArticleExtractorTests -only-testing:LunaTests/ProductPageDetectorTests -only-testing:LunaTests/ReadingListIngestorInteropTests -only-testing:LunaTests/ReadingListStoreTests -only-testing:LunaTests/PreloadStoreTests -only-testing:LunaTests/PaywallBypassTests`
plus whichever named test files cover files you touched (grep the type name in
`LunaTests/` and `LunaLibraries/Tests/`; note the SwiftPM testTargets
`LunaURLClassificationTests`/`LunaHTMLClassificationTests`/`LunaPaywallBypassTests` also
exist inside `LunaLibraries` and run as part of the Luna scheme).
