# Luna Vault storage

Vault owns `vault.sqlite` in the shared App Group and never opens the legacy
`saves.sqlite`. `VaultRepository` uses one serialized SQLite connection per
process, enables WAL, `synchronous=FULL`, and foreign keys, and creates the
objects, durable tombstones, cache, jobs, and encrypted-artifacts tables at
schema version 6. Cache rows also carry independent `supports_eviction` and
active-preview state. Migrations acquire an exclusive transaction, re-read the
version under that lock, and retry bounded SQLite busy races so concurrent first
opens cannot partially initialize the store. Object IDs and revisions are opaque UUIDs. Upserts are
latest-only using logical time, device id, then revision UUID as a total order.
Tombstones participate in the same order and must beat both the current object
and prior tombstone; stale or equal candidates are complete no-ops. Winning
tombstones make the object logically invisible in the same transaction, remove
cache, cancel queued/retrying transfer jobs, and prevent equal or older data
from being resurrected. A running lease may finish its current operation, but
its conditional transition cannot revive the tombstoned object.

Local bytes use an opaque UUID directory with an atomically replaced `content`
file. Files are marked `completeUntilFirstUserAuthentication`, relying on iOS
Data Protection for local-at-rest protection. Remote copies must be produced by
the crypto layer before transport. The database stores no extracted plaintext;
the indexing stage owns its local schema and encrypted artifact projection.
Replacement keeps recoverable staging/previous states. Content and its generation
token are fully written, fsynced, and protected while still staged; the protection
attribute survives their atomic renames, and the token is installed only after the
protected content. Startup verifies the token's revision and SHA-256 digest against
the installed bytes, along with required file
protection attributes before accepting a final. It restores a verified previous
generation or deletes the candidate rather than applying protection after the fact.
Deletions enqueue durable
cleanup markers scoped to object revision and content-generation token in the
logical transaction. Startup retries residual cleanup, but discards an obsolete
marker without touching bytes if either scope has advanced. Data Protection application is
throwing and failures surface to the caller for directories, database sidecars,
staging, and final files.

Cache rows retain access/creation dates, full-content state, and an in-flight pin.
Full content expires after seven days unless pinned. Eviction is oldest-first
for unpinned, evictable, non-preview entries and is bounded by the configured quota (the public
configuration computes 10% of important available capacity, bounded to 2–20 GB,
unless the user supplies a bounded override). Names, indexes, and thumbnails
are independent of full-content eviction; downgrading a row from full content
to metadata also durably removes its content file and byte accounting. Import, index, upload, download and
delete jobs have durable state, attempts, retry time and last-error fields,
opaque object identity (kind, revision, and payload generation), backend key,
and the expected remote revision for upload CAS; a
worker claims queued/retrying work atomically with a cross-process lease.
Attempts increment only on successful claims; heartbeats extend a lease and an
expired lease is reclaimable after a crash. Completion/failure transitions use
a conditional update matching the current nonexpired lease owner, so a reclaimed
stale worker cannot mutate the new owner's job. A unique idempotency key prevents
the same durable operation from being queued twice.
Heartbeats use the same nonexpired-lease condition; an owner cannot revive its
lease after the expiry instant and must instead compete for a new atomic claim.

The production initializer fails closed if the App Group container cannot be
resolved. The explicit scratch-directory initializer is test-only. SQLite tables
carry CHECK constraints, cache/job foreign keys and cascades. Repository tests
assert WAL, foreign keys, integrity, reopen behavior, two-connection claiming,
seven-day eviction, tombstone anti-resurrection, and that a `saves.sqlite`
canary is byte-for-byte unchanged.

Encrypted artifact inserts accept only typed envelope records. The repository
validates the wrapped DEK framing and every chunk's vault, object, revision,
role, root version, index, count, and length before persistence; mixed or
oversized envelopes are rejected without storing partial data.
