# Luna Vault v1 storage backends

Vault v1 exposes three locations: `device`, `icloud`, and `mac`. This document
describes the two file-backed locations implemented in Stage 4A. AWS, S3,
Backblaze, and other provider adapters are intentionally out of scope.

## Device

`VaultDeviceBackend` is a thin transport over the isolated `vault.sqlite`
repository and its object files. Writes are crash-safe (staged, fsynced,
protected, then installed atomically) and reads are local. The repository
applies iOS Data Protection (`completeUntilFirstUserAuthentication`) to its
database, directories, generation markers, and object bytes. Nothing in this
backend opens a URL session or sends data to a service. The backend therefore
does not require the Vault root key for local-at-rest protection. The transport
method retains the historical `putCiphertext` name so the same sync boundary
can be used by encrypted remote backends; on device its argument is local
content.

## iCloud

`VaultICloudBackend` uses an app-entitled ubiquity container's `Documents`
directory and coordinates every read, write, and delete with
`NSFileCoordinator`. Object paths contain only the Vault namespace and opaque
UUID object ID; user filenames, metadata, manifests, and indexes are not
written as iCloud filenames. Callers must pass client-side encrypted bytes for
every iCloud object. There is no fallback to the App Group or another local
directory when the iCloud account, entitlement, or container is unavailable.

iCloud is a file provider, not a provider-independent range API. The backend
advertises `supportsRangeReads == false` and safely implements a range request
as a coordinated full read followed by a local slice. Large-object streaming
and true remote range reads remain a later optimization.

The `keepLocalCopy` setting is a policy. When false, a successful write requests
`FileManager.evictUbiquitousItem`; the backend only reports `.evicted` after
resource values say the item is no longer downloaded. If the file provider has
accepted the request but still reports local bytes, the result is `.pending`.
Reads of an existing ubiquitous file that is not downloaded first request a
download and return a retryable unavailable error; sync should retry after a
file-provider state change. These APIs are not available in a useful way on a
simulator without an iCloud entitlement/account, so deterministic tests inject
`VaultUbiquitousFileCoordinating`.

## Durable sync

`VaultSyncCoordinator` inserts an upload/download job before invoking a
backend, claims the exact idempotency row, and transitions it only after the
backend and encrypted payload source succeed. Replays after a crash replace
the same opaque object ID. Payload sources must durably retain ciphertext; the
job row never contains bytes, names, credentials, or the root key. The same
coordinator is suitable for the future Mac/Tailscale transport.
