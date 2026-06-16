# Semantic Sharing Suggestions (experimental)

On-device content-similarity sharing suggestions. **Off by default** (Settings →
Experimental → "Suggest by Content Similarity"). When a newly saved article/video
is conceptually similar to things you've already shared with a friend, it arms a
share suggestion for that friend.

## Memory discipline (the whole point of the flag)

App-Intent runners have tight memory limits, so the embedding model is **only
ever loaded in the main app**, never in the intent runner:

- The runner (save intents) does only cheap work: `enqueueSemanticCheck(itemID)`
  (append an id) and `recordShare` (append an id) — no model.
- `SemanticIndexer` (main app) loads `NLEmbedding`, embeds, and **releases** it
  per batch; capped at `embedLimit` (20) items/run; serialized on a utility
  queue. Triggered from `AppDelegate.didFinishLaunching` + `SceneDelegate`
  foreground only.
- Vectors persist to disk (App Group), so they're computed once.

## Key files (`Clip/Social/`)

- **`SemanticSharingSettings`** — `isEnabled` flag (App Group UserDefaults, default false).
- **`SemanticEmbedder`** (main app) — `NLEmbedding.sentenceEmbedding(for: .english)`;
  `embed(text) -> [Float]?` (text capped at 1200 chars); `release()` frees the model.
- **`SemanticIndexStore`** (App Group JSON `semanticIndex.json`) — all cheap, runner-safe:
  - `itemVectors: [itemID: [Float]]`, `persons: [personUUID: {username, itemIDs}]`,
    `checkQueue: [itemID]`.
  - `enqueueSemanticCheck`, `recordShare` (append id; no vector needed),
    `setVector`/`hasVector`, `itemIDsNeedingVectors(limit:)`, `dequeueChecks()` (≤10),
    `bestMatch(forItemID:) -> Match?`, `removePerson`.
  - `cosine(_:_:)` (pure, tested); `similarityThreshold = 0.60`.
  - Empty `[]` vector = tombstone for deleted/unembeddable items (stops retry).
- **`SemanticIndexer`** (main app) — `scheduleRun()`: embed referenced items
  lacking vectors, then for each dequeued check with a vector arm a semantic
  suggestion (`ShareSuggestionStore.armSemanticSuggestion`) if `bestMatch` clears
  the threshold, the friend still exists, and nothing's already pending.

## Wiring

- `ReadingListIngestor.handleSavePress` (.saveNew) → `enqueueSemanticCheck`.
- `SocialMessageCenter.sendArticle` success → `recordShare(itemID, personUUID, username)`.
- `ShareSuggestionStore.PendingSuggestion.isSemantic`: semantic suggestions never
  become "always share" — `applyChoice(.alwaysShare)` is treated as a one-off send
  (so the user effectively only gets share / don't-share).
- Embedded text = title + channel + first 8 content blocks.

## Tests

`ClipTests/SemanticIndexStoreTests.swift` — cosine, bestMatch (close/none/already-shared),
queue, needs-vectors.

See `social-sharing.md` for the streak/auto-share suggestion engine this layers on.
