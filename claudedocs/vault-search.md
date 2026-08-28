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

The vector scan is intentionally a measurable limitation for v1. The iOS test
plan records a deterministic 100,000-vector exact-search measurement without a
flaky wall-clock threshold. Release profiling should additionally record p50,
p95, and memory on supported devices. Any HNSW replacement must preserve the
model-version, tombstone, and canonical-dedupe tests unchanged.
