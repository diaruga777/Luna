# Luna Vault Stage 5 import and media runtime

Stage 5 keeps document-picker URLs and plaintext inside the Vault app process. `VaultImportCoordinator`
briefly opens a security-scoped source, rejects directories and symbolic links, and streams it in
bounded chunks into a Data-Protection staging directory. The protected, fsynced journal is written
before any Vault plaintext. A streaming SHA-256 digest is the dedupe identity (with a custom
identity generator fallback for fixtures), and the journal records the digest so a source swap is
detected before installation. Imports accept up to 100 GB without materialising the file as one
`Data` value. The journal is replayed by `repairInterruptedImports()` after an interruption;
malformed journals, orphan payloads, and stale temporary files are swept. `VaultAtomicObjectInsertRequest`
is idempotent, so a replay repairs content and durable index/upload jobs without creating a second
content identity.

`VaultIndexWorker` claims only local extraction jobs. It reads the protected device copy, writes
extraction artifacts and the local search index, and optionally creates a local embedding. If the
copy has been evicted, it transitions the job to retrying with a `download-needed` result; it never
asks a backend for plaintext or ciphertext.

Remote content uses `VaultAuthenticatedCiphertextFile`: a bounded binary frame file with an
authenticated header and streaming generation digest. iCloud and paired-Mac transports copy
frames/ranges through file descriptors; upload/download workers never build a whole-object
`Data`. Every frame is authenticated before a download is installed. A remote import seals the
protected staged plaintext with the production backend identity and current root key before the
object row or upload job is made visible, and places the sealed file in the durable upload
staging area so replay cannot produce a missing-payload job.

Vault Settings → Uploads has a Wi-Fi-only switch, enabled by default. With the switch on, queued
uploads stay durable until Wi-Fi is available; downloads and deletes continue to follow their
normal network policy. A Wi-Fi-available path change wakes the sync queue immediately.

Object visibility is a durable `object_visibility` row. Atomic imports insert the object, protected
content, and idempotent jobs while the row remains hidden; metadata is committed and only then is
the object published. SQLite claim queries require visibility and accept an explicit job-kind set,
so the local index worker cannot claim network work. Replayed idempotent imports return the IDs
actually stored in SQLite rather than the discarded candidate UUIDs.

Thumbnails are kept in `VaultThumbnailStore`, an independent protected sidecar keyed by object,
revision, and content generation. Thumbnail access, age, and quota eviction do not change full
content cache policy. `VaultCacheCoordinator` exposes cache status and records access timestamps;
full content follows the repository's seven-day idle heuristic and quota policy.

`VaultPreviewRouter` returns a local protected URL only when complete bytes are present. Otherwise
it reports download, unavailable, or failure states without constructing a remote URL. The injected
download requester must complete authenticated download/decryption before a preview is planned;
video uses a local `AVPlayer` and encrypted range streaming is intentionally unsupported. UIKit,
PDFKit, Quick Look, and AVKit controllers are in the Vault UI product and are not linked into
extensions.

`VaultBackgroundTaskScheduler` provides injectable, cancellable operations for import repair,
indexing, download, upload, and thumbnail maintenance. Production registration uses
`BGProcessingTaskRequest`; tests inject a submitter and operation so cancellation does not require
network access or a background-task entitlement.

Scheduler starts are gated until the task is registered, closing the starting/cancellation race;
sync and indexing leases renew while long transfers or extraction run. Index cancellation is
retryable. Protected import and sync staging is checked before writes and encrypted extraction
temporaries are swept at process launch; cleanup failures are surfaced to the repair caller.
Source reads reject symlink ancestors and use `O_NOFOLLOW` descriptors to avoid pathname
replacement races.

Extraction remains intentionally bounded independently of import: objects over the 64 MiB
materialisation budget take the metadata-only route and are never loaded into one `Data` value.
Preview URLs are repository-issued capabilities carrying the current object revision, exact size,
generation digest, regular-file check, and protection result. Cache eviction preserves pinned,
non-evictable, and active-preview entries; thumbnail indexes are atomically replaced and repair
removes stale revisions, malformed entries, and orphan payloads.

Preview view creation revalidates the capability, strict download providers return the exact
repository-issued object/revision/generation/size capability requested, and active previews hold
a durable pin/lease. Thumbnail reads compare both revision and current content generation;
corrupt payloads remove the payload directory and index entry together. MIME parameters are
normalized, UTType identifiers are accepted directly, and filename extensions remain the final
fallback.
