# Semantic Sharing Suggestions (experimental)

On-device content-similarity sharing suggestions. **Off by default** (Settings →
Experimental → "Suggest by Content Similarity"). When a newly saved article/video
is conceptually similar to things you've already shared with a friend, it arms a
share suggestion for that friend.

## When suggestions fire

ONLY two places (never on past saves at launch — that's bad UX):
1. **The save app-intent** (`handleSavePress`, after ingest) — the live
   share/don't suggestion. `SemanticIndexer.immediateSuggestion(forItemID:)`
   embeds JUST the one new item (a single inference, model released right after)
   and matches it against the already-cached per-friend vectors. Armed only if
   no same-site/-channel streak suggestion already armed one. Surfaced by
   `GetShareSuggestionIntent` (next shortcut step).
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
- The Settings flag is the safety valve if the single in-runner embed is ever
  a problem on a given device.

## Key files (`Clip/Social/`)

- **`SemanticSharingSettings`** — `isEnabled` flag (App Group UserDefaults, default false).
- **`SemanticEmbedder`** (main app) — `NLEmbedding.sentenceEmbedding(for: .english)`;
  `embed(text) -> [Float]?` (text capped at 1200 chars); `release()` frees the model.
- **`SemanticIndexStore`** (App Group JSON `semanticIndex.json`) — all cheap, runner-safe:
  - `itemVectors: [itemID: [Float]]`, `persons: [personUUID: {username, itemIDs}]`,
    `checkQueue: [itemID]`.
  - `recordShare` (append id; no vector needed), `setVector`/`hasVector`/`vector`,
    `itemIDsNeedingVectors(limit:)`, `bestMatch(forItemID:) -> Match?`, `removePerson`.
  - `cosine(_:_:)` (pure, tested); `similarityThreshold = 0.60`.
  - Empty `[]` vector = tombstone for deleted/unembeddable items (stops retry).
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

`ClipTests/SemanticIndexStoreTests.swift` — cosine, bestMatch (close/none/already-shared),
needs-vectors.

See `social-sharing.md` for the streak/auto-share suggestion engine this layers on.
