# Luna Vault local search

Vault search is a separate SQLite database (`vault-index.sqlite`) and never
queries a backing provider. The database contains a local FTS5 projection for
filename, extracted body text, OCR text, and spoken-word transcript, plus
timestamp/source columns and encrypted-export-ready revision boundaries.
Embeddings are stored as little-endian `Float32` blobs keyed by
`(object_id, model_version)`; a query can only compare vectors in the same
model space and dimension.

`VaultSearchIndex` currently uses a deterministic brute-force cosine scan. The
`VaultVectorIndex` protocol is the explicit seam for a future HNSW index. The
baseline is deliberately bounded by the requested result limit and stable
object-ID tie-breaks; it is correctness-first, not an assertion that 100,000
objects meet interactive latency on every phone. Performance measurements must
be recorded on the target device before replacing it with an approximate index.

The hybrid rank combines filename exact match, FTS5 BM25, and cosine score.
Every result carries a snippet, timestamps, source, and matched-field list.
Tombstones remove FTS/vector visibility and stale revisions cannot resurrect a
document. Reopening the database and rebuilding the FTS projection are
idempotent.

Automatic groups have stable UUIDs and evolve by nearest centroid. Frozen
groups preserve user names and membership; an injectable keyword namer is the
offline fallback for generated labels. Query groups are snapshots by default;
live query groups re-run the same local search. Manual membership is represented
by a symbolic alias vector (label centroid plus a small offset toward the
original). Alias resolution is canonical and global result presentation
deduplicates the original object.

The vector scan is intentionally a measurable limitation for v1. A future
benchmark should insert 100,000 synthetic documents with the production model
dimension, report p50/p95 search time and memory on supported devices, and
preserve the exact same model-version and canonical-dedupe tests when an HNSW
implementation is introduced.
