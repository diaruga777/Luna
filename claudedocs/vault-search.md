# Luna Vault local search

Vault search is a separate SQLite database (`vault-index.sqlite`) and never
queries a backing provider. The database contains a local FTS5 projection for
filename, extracted body text, OCR text, and spoken-word transcript, plus
timestamp/source columns and encrypted-export-ready revision boundaries.
Embeddings are stored as little-endian `Float32` blobs keyed by
`(object_id, model_version)`; a query can only compare vectors in the same
model space and dimension.

The database, WAL, SHM, and containing directory receive explicit iOS Data
Protection. Remote backup never receives plaintext SQLite bytes:
`encryptedExport` checkpoints locally and seals an authenticated `.index`
artifact with the Vault root-key hierarchy; restore verifies it into a
protected staging file before installation.

`VaultSearchIndex` currently uses a deterministic brute-force cosine scan. The
`VaultVectorIndex` protocol is the explicit seam for a future HNSW index. The
baseline uses stable object-ID tie-breaks and is correctness-first, not an
assertion that 100,000 objects meet interactive latency on every phone.
Automatic grouping is one pass over objects against a configured maximum number
of persisted centroids. Performance measurements must be recorded on the target
device before replacing exact search with an approximate index.

The hybrid rank combines filename exact match, FTS5 BM25, and cosine score.
Every result carries a snippet, timestamps, source, and matched-field list.
Tombstones use total `(logical time, device ID, revision UUID)` ordering,
including deletes for objects this device has never seen. They remove
FTS/vector/group/query/alias visibility and stale or equal revisions cannot
resurrect a document. Reopening and rebuilding are idempotent.

Automatic groups have stable UUIDs and evolve by nearest centroid. Frozen
groups preserve user names and membership; an injectable keyword namer is the
offline fallback for generated labels. Query groups are snapshots by default;
live query groups re-run the same local search. Manual membership is represented
by a symbolic alias vector (label centroid plus a small offset toward the
original). Alias resolution is canonical and global result presentation
deduplicates the original object.

The vector scan is intentionally a measurable limitation for v1. The dedicated
`LunaVaultPerformance` test plan gives its single 100,000-record simulator
stress test up to 20 minutes of XCTest execution allowance; the benchmark
itself has a 15-minute budget. It records bulk-build time, p50/p95 lexical,
exact-vector and hybrid latency, checkpointed database size, and resident
memory, then reopens the checkpointed database and verifies its count,
integrity, groups, and symbolic alias. The normal test plan keeps its existing
timeouts and does not inherit this exception.

This bulk-build measurement is a recovery/import stress gate, not Luna Vault's
normal write path or a promise that a foreground user waits for 100,000 files.
Production indexing is incremental: each inserted or revised file commits a
small durable batch as it arrives, and background import/reindex jobs resume
from post-commit progress. Release profiling should additionally record p50,
p95, and memory on supported physical devices. Any HNSW replacement must
preserve the model-version, tombstone, and canonical-dedupe tests unchanged.

The Stage 5 UIKit home screen uses `VaultSearchIndex.recent(limit:)`, which
applies the limit in SQLite before decoding rows. `VaultSearchPresentationFacade`
then canonical-deduplicates search (and future alias-inclusive recent) hits
while retaining the winning snippet, matched fields, source, and symbolic-alias
provenance for presentation. Import and file-opening behavior remains a
callback-owned host seam.

The home screen also renders bounded snapshot/live query groups. Manual
membership calls carry the selected index model version explicitly (the UI
uses the injected provider or the index's model-space list); if no active
model is available, the action fails visibly and asks the user to rebuild the
index. Search text is debounced and evaluated off the main thread, with stale
generations discarded before UIKit rendering.
