# Luna Writer review — `LunaWriterModels` and `LunaWriterText` (2026-09-03)

Reviewer: Opus subagent, read-only. All 8 files in Models and 13 in Text read in full, plus their tests and immediate callers. Severity: P0 crash/data loss, P1 wrong behaviour, P2 perf/leak, P3 simplification.

## `LunaWriterModels/`

### 1. The Codable machinery has no production caller — P3
`Identifiers.swift:10-36`, `AuthorshipSpan.swift:35-48`. Hand-written coders; storage uses `storageValue`/`storageKind`. Untested and unexercised; whether the protocol-extension `init(from:)` or synthesis wins for `DocumentID` is not obvious. Add one round-trip assertion or drop the `Codable` refinement.

### 2. `characterCount` (graphemes) mixes units with anchor offsets (UTF-16) — P3
`WriterDocument.swift:20` from `TextStatistics.Stats.characters` at `DocumentTextSummary.swift:17`; `TextAnchor.swift:8-9`. Document the unit.

## `LunaWriterText/LineTable.swift`

### 3. A CRLF straddling an 8192-unit chunk boundary yields a duplicate line start — P1
`LineTable.swift:109-118` (with `:96-101, 124`). When `CR` is the last unit of a chunk the code peeks the LF, appends `base + k + 2`, does `k += 2`, exits the loop, then `base += count` leaves `base` at the LF; the next chunk appends the same start again. `lineCount` one too high, a zero-length phantom line scanned as `.blank`. Windows-authored `.md` adopted by the watcher hits this; the randomised test tops out ~5 KB. Fix: after the loop, if `k > count`, `base += k` instead of `base += count`.

### 4. The region-extension loop looks unreachable — P3 (verify before deleting) (`:57-61`). Delete with the differential test defending, or comment the case.

### 5. `LineTable` and `NSString.lineRange(for:)` disagree on U+0085/U+000C — P3 (`:86, 105` vs `MarkdownEditingCommands.swift:272, 281`).

## `LunaWriterText/MarkdownDocumentModel.swift`

### 6. `apply(edit:replacementLength:)` trusts an unvalidated delta and can crash — P1 (crash-shaped)
`:105-119` → `LineTable.swift:43-57`. `newLength` is computed from the caller's numbers; `isLineBoundary` → `character(at:)` past the real length raises `NSRangeException`. `MarkdownTextStorage.swift:85-94` can produce a wrong pair (see editor review). Fix: compare the predicted length with `sharedText.length`; on mismatch rebuild the table (`table = LineTable(text: sharedText)`, `pendingLines = 0..<lineCount`) with a DEBUG `assertionFailure`.

### 7. Every line read allocates a shifted copy of the line's tokens — P2
`:178-182` (`offsetting(by:)` at `MarkdownTokens.swift:117-147`). `paragraphRange(containing:)` (`:241-254`), `headings()` (`:213-226`), `TitleDeriver.derive`, `allLineScans()` all pay for inline arrays. Add `blockKind(at:)` and `blockLineRange(at:)`.

### 8. Public read accessors trap on an out-of-range index — P3 (`:175, 178-181`; `LineTable.swift:34-38`). Clamp.

### 9. `blocks(in:)` and `blocksAndInlines(in:)` are the same function twice — P3 (`:188-205`). One calls the other; hoist `lastLineIndex(touching:)`.

### 10. Reads mutate (`flushPending`), and nothing says the model is single-threaded — P3 (`:27-35, 179, 189, 201, 209, 214`). Mark `@MainActor` or document.

## `LunaWriterText/MarkdownScanner.swift`

### 11. A fenced-code line loses its leading indentation — P1
`MarkdownScanner.swift:106`. Inside a fence `start` is still the first non-space unit (`:71-75`), so `contentRange` drops the indent; `MarkdownHTMLRenderer.swift:86` emits `contentRange`, so exported HTML/PDF renders indented code flush left. Fix: in the `inFence` branch emit `contentRange: NSRange(location: 0, length: content)`.

### 12. The open fence's marker is re-parsed from a `String` on every line of a code block — P2 (`:91, 93`). Store `(marker: unichar, width: Int)` in `ScanState`.

### 13. Image alt text is not scanned for inline spans, unlike link text — P3 (`:388-395` vs `:405-414`).

### 14. Two public `scanLine` entry points exist only for tests — P3 (`:17-31`). Delete the `Substring` overload and its test.

## `LunaWriterText/MarkdownHTMLRenderer.swift`

### 15. A hard break emits `<br>` twice, one on the wrong line — P1
`:106` and `:121`. The `hardBreak` inline token already renders `<br>` in place; line 106 emits a second one before the next line's text. `"one\ntwo  \nthree\n"` → `<p>one<br>\ntwo<br>\nthree</p>`. Fix: delete the condition on both lines; test for exactly one `<br>`.

### 16. Any paragraph containing a pipe is exported as a one-row table — P2 (`:136-145, 216-235`; from `MarkdownScanner.swift:258`). In `closeTable`, if no delimiter row was seen (`sawDelimiter` flag), emit the row as a paragraph.

### 17. Link and image destinations are not scheme-filtered — P2 (`:272-278, 373, 376, 380`). `[x](javascript:alert(1))` reaches the exported `.html`. Allow `http`, `https`, `mailto`, `tel`, relative; images the same minus mailto/tel plus `file` under `imageBaseURL`; else `#`.

### 18. `HTML.escape` copies the string into `[Character]` on every call — P2 (`:251`). Index-based walk with an early-out when no escapable character.

### 19. Tautological condition in `HTML.cells` — P3 (`:293`); leading empty cell lost at `:302`.

### 20. `stylesheet` interpolated raw into `<style>` — P3 (`:41`). Document as trusted or strip `</style`.

## `LunaWriterText/TextAnchorResolver.swift`

### 21. For a selection over 512 units, the context search can never match — P2
`:24-37` and `:59-79`. `exact` is capped at 512 but `suffix` is taken from the end of the full selection, so `prefix + exact + suffix` is never a substring. Fix: derive the suffix from the end of the capped quote. Test: 600-character mid-document selection, insert above, resolves.

### 22. Context edges can be cut through a surrogate pair — P3 (`:27-30`). Snap with `rangeOfComposedCharacterSequence(at:)`.

### 23. Occurrence search uses canonical-equivalent comparison then offset arithmetic — P3 (`:106`, `:62, 76, 131`). Pass `.literal`.

### 24. The fuzzy tier is unbounded per document — P2 (`:141-147, 156-187`). Up to 16 candidates × ~72k DP cells per anchor; reconciler resolves every anchor on reload. Stop at the first distance ≤ 1; lower the matching pattern limit to ~96.

## `LunaWriterText/TitleDeriver.swift`

### 25. Titling a sheet builds two whole document models and scans every line twice — P2
`:40-42, 61-63`, called at `DocumentTextSummary.swift:12, 16`; plus `TextStatistics.measure`. `derive` (`:27-36`) never breaks early; `snippet` (`:48-57`) walks from line 0. Build one model in `DocumentTextSummary`; bound the heading search (~200 lines).

### 26. `snippet` includes text above the title line, contradicting its comment — P3 (`:44-50`).

### 27. `trim` cuts mid-word when a line has no space — P3 (`:65-73`).

## `LunaWriterText/SentenceSegmenter.swift`, `WordSegmenter.swift`, `LRUCache.swift`

### 28. `LRUCache.insert` has two identical branches — P3 (`:26-27`).

### 29. The LRU's recency list is a linear scan on every hit — P2 (`:16-23, 25-34`). 256 string comparisons + array shift per hit on main. Use a stamp per entry; evict lowest stamp on insert.

### 30. Both segmenters bridge a fresh `String` before consulting the cache — P2 (`SentenceSegmenter.swift:17`, `WordSegmenter.swift:13`, `POSTaggingService.swift:40, 51`). `WordSegmenter` has no cache; `wordRange(containing:)` (`:28-30`) re-tokenises the whole range. Key caches on `(location, length, storageRevision)`.

### 31. The abbreviation merge re-substrings a growing range — P3 (`SentenceSegmenter.swift:63-72`). Pass the tail only.

## `LunaWriterText/PartOfSpeechTagger.swift`, `POSTaggingService.swift`

### 32. Language recognition runs on every paragraph, every time — P2 (`PartOfSpeechTagger.swift:49, 64-69`). Cache scheme availability per `NLLanguage`; latch "unsupported" per document.

### 33. In-flight jobs are keyed by paragraph location, which moves — P3 (`POSTaggingService.swift:21, 64, 74, 82-86`). Key on body hash or return a token.

### 34. `ParagraphTagging` witnesses must be off-main-safe, and nothing says so — P3 (`PartOfSpeechTagger.swift:21-24, 30`, `POSTaggingService.swift:70`). Document; drop the test-only `tags(in:of:)` overloads.

## `LunaWriterText/MarkdownEditingCommands.swift`

### 35. `continueList`, `indent`, `outdent` and `apply` have no production caller — P3 (`:35-46, 150-172, 174-197`). Return inside a list does not continue the list in the shipping editor. Wire them (Return / Tab in `EditorViewController`) or delete them with their tests.

### 36. `apply`'s returned range is short whenever more than one edit changes length — P2 (`:35-46`). Accumulate a running shift.

### 37. Two implementations of "what is a list marker" that disagree — P3 (`:211-235` vs `MarkdownScanner.swift:295-312`). Delete `marker(ofLine:)`; read the model's `BlockToken`.

## What is solid
The incremental rescan protocol and its 500-edit randomised differential test; the inline scanner cannot loop; `approximateMatch`'s banded DP; `TextStatistics.count`'s one-pass rules; `InlineMarkup.plainText` overlap handling; `HTML.escape`'s backslash ordering; both tiers import only Foundation, NaturalLanguage and LunaWriterModels (Mac-clean). Adjacent note: `AuthorshipSpanList` (pure Foundation) lives in the UIKit-importing `LunaWriterEditor`; it belongs beside `AuthorshipSpan` in the models tier.

## Test gaps
1. `LineTable` beyond 8 KB (`String(repeating: "line\r\n", count: 3000)` → `lineCount == 3000`). 2. `apply` with an inconsistent descriptor. 3. Indented fenced code. 4. Hard break mid-paragraph (count `<br>`). 5. A pipe paragraph through the renderer. 6. Destination sanitisation. 7. A `TextAnchor` over 512 units with real context. 8. Anchors around astral characters. 9. `apply`'s returned range. 10. `toggleWrap` at document edges. 11. Model Codable round-trips. 12. `LRUCache` eviction. 13. `SentenceSegmenter` cache hit avoids re-tokenising.
