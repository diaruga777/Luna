# Semantic Sharing Suggestions (experimental)

On-device content-similarity sharing suggestions. **Off by default** (Settings →
Experimental → "Suggest Shares Based on Content" — a "Never → Often" slider, no
numbers exposed). When a newly saved article/video is conceptually similar to
things you've already shared with a friend, it arms a share suggestion for that
friend.

## When suggestions fire

ONLY two places (never on past saves at launch — that's bad UX):
1. **The save app-intent** (`handleSavePress`, after ingest) — the live
   share/don't suggestion. `SemanticIndexer.immediateSuggestion(forItemID:)`
   embeds JUST the one new item (a single inference, model released right after)
   and matches it against the already-cached per-friend vectors. Armed only if
   no same-site/-channel streak suggestion already armed one. Surfaced by the
   **token returned from the save intent** (`"2:<username>"`, since a semantic
   match is `isSemantic` and offers Yes/No only — no "always"; see
   save-link-intent.md).
2. **End of an article** — `AppReaderShareProvider.suggestedFriendName` falls
   back to `SemanticIndexer.cachedSuggestion` (a cheap `bestMatch` over the
   already-cached vector — NO embedding).

## Memory discipline

- The expensive batch work — embedding the items you've shared to friends so
  matches have history to compare to — runs ONLY in the main app
  (`SemanticIndexer.scheduleRun()` → `buildMissingVectors`, utility queue,
  `embedLimit` 20/run, model released after). It arms NO suggestions.
  Triggered from `AppDelegate`/`SceneDelegate` lifecycle.
- The intent runner does at most ONE embed (the just-saved item) plus cheap
  cosine math. `recordShare`/`bestMatch`/vector reads load no model.
- Vectors persist to disk (App Group), computed once.
- Sliding the slider to "Never" (sensitivity 0) is the safety valve / off switch
  if the single in-runner embed is ever a problem on a given device.

## Sensitivity → threshold

`SemanticSharingSettings.sensitivity` is a single `Double` (0...1, App Group,
default 0). `0` = off (`isEnabled == false`). Higher = more eager. It maps to a
cosine threshold via the pure `threshold(forSensitivity:)`: `strictestThreshold`
0.82 (sensitivity→0) … `loosestThreshold` 0.62 (sensitivity 1). Raised from the
old flat 0.55 so suggestions are less aggressive even at "Often". `bestMatch`
takes the threshold explicitly (the store stays pure/threshold-agnostic).

## Key files (`Luna/Social/`)

- **`SemanticSharingSettings`** — `sensitivity` (0...1; default 0 = off),
  `isEnabled` (`sensitivity > 0`), `similarityThreshold` + pure
  `threshold(forSensitivity:)`. Migrates the legacy `semanticSharingEnabled` bool
  to sensitivity 0.5.
- **`SemanticEmbedder`** (main app) — `NLEmbedding.sentenceEmbedding(for: .english)`;
  `embed(text) -> [Float]?` (text capped at 1200 chars); `release()` frees the model.
- **`SemanticIndexStore`** (App Group JSON `semanticIndex.json`) — all cheap, runner-safe:
  - `itemVectors: [itemID: [[Float]]]` (one vector per paragraph chunk),
    `persons: [personUUID: {username, itemIDs}]`.
  - `recordShare` (append id; no vector needed), `setVectors`/`hasVectors`,
    `itemIDsNeedingVectors(limit:)`,
    `bestMatch(forItemID:threshold:bestScore:bestUsername:bestItemID:) -> Match?`,
    `removePerson`.
  - `cosine(_:_:)` + `maxChunkSimilarity(_:_:)` (max cosine over chunk pairs), pure/tested.
  - Empty `[]` vectors = tombstone for deleted/unembeddable items (stops retry).
- **`SemanticIndexer`** — `scheduleRun()` (main app, vectors only, no arming),
  `immediateSuggestion(forItemID:)` (save intent — one embed + match),
  `cachedSuggestion(forItemID:)` (end-of-article — cached match, no embed).

## Wiring

- `ReadingListIngestor.handleSavePress` (.saveNew), after ingest → arm a semantic
  `pendingSuggestion` from `immediateSuggestion` when no streak already armed one.
- `SocialMessageCenter.sendArticle` success → `recordShare(itemID, personUUID, username)`.
- `AppReaderShareProvider.suggestedFriendName` → streak, else `cachedSuggestion`.
- `ShareSuggestionStore.PendingSuggestion.isSemantic`: semantic suggestions never
  become "always share" — `applyChoice(.alwaysShare)` is treated as a one-off send
  (so the user effectively only gets share / don't-share).
- Embedded text = title + channel + first 8 content blocks.

## Tests

`LunaTests/SemanticIndexStoreTests.swift` — cosine, maxChunkSimilarity, bestMatch
(close/none/already-shared), needs-vectors; `SemanticSensitivityTests` — the
sensitivity→threshold mapping (monotonic + clamped).

See `social-sharing.md` for the streak/auto-share suggestion engine this layers on.
