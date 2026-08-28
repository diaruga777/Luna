# Luna Vault storage

Vault owns `vault.sqlite` in the shared App Group and never opens the legacy
`saves.sqlite`. `VaultRepository` uses one serialized SQLite connection per
process, enables WAL, `synchronous=NORMAL`, and foreign keys, and creates the
objects, durable tombstones, cache, jobs, and encrypted-artifacts tables at
schema version 1. Object IDs and revisions are opaque UUIDs. Upserts are
latest-only and reject older logical times; tombstones are retained so a delete
cannot be resurrected by a delayed copy.

Local bytes use an opaque UUID directory with an atomically replaced `content`
file. Files are marked `completeUntilFirstUserAuthentication`, relying on iOS
Data Protection for local-at-rest protection. Remote copies must be produced by
the crypto layer before transport. The database stores no extracted plaintext;
the indexing stage owns its local schema and encrypted artifact projection.

Cache rows retain access/creation dates, full-content state, and an in-flight pin.
Full content expires after seven days unless pinned. Eviction is oldest-first
for unpinned entries and is bounded by the configured quota (the public
configuration clamps the v1 default to 2–20 GB). Names, indexes, and thumbnails
are independent of full-content eviction. Import, index, upload, download and
delete jobs have durable state, attempts, retry time and last-error fields; a
worker claims queued/retrying work and transitions it idempotently.
