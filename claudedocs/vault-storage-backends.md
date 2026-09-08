# Luna Vault v1 storage backends

Vault v1 exposes `device`, `icloud`, and `mac`. Stage 4A implements the device
and iCloud locations. AWS, S3-compatible providers, Backblaze, provider SDKs,
and hosted Luna infrastructure are out of scope. The Mac transport is defined
separately and is not silently substituted when it is unavailable.

## Device

`VaultDeviceBackend` is a local-content surface over the isolated
`vault.sqlite` repository and its object files. Writes are staged, fsynced,
protected, and atomically installed; range reads are local. The repository
applies iOS Data Protection (`completeUntilFirstUserAuthentication`) to its
database, directories, generation markers, and object bytes. The device
backend intentionally stores plaintext under Data Protection and never opens a
network session. It is not a `VaultBackendTransport`, because that protocol
accepts only client-encrypted remote payloads.

## iCloud Documents

The Vault host has `CloudDocuments`, iCloud-container, ubiquity-container, and
ubiquity key-value-store entitlements. Its Info.plist exposes the build-derived
`LunaVaultICloudContainerID`; `AppConfig.vaultICloudContainerID` is the runtime
source. `KindWiring+Vault` constructs `VaultRuntimeServices`, which selects the
device or iCloud implementation from the saved `VaultStoragePolicy`. The Vault
Share extension remains a keyless handoff surface: it has neither iCloud nor
Keychain entitlements and does not link Vault crypto or sync services.

`VaultICloudBackend` resolves the entitled ubiquity container's `Documents`
directory and coordinates reads, writes, and deletes with `NSFileCoordinator`.
There is no fallback to the App Group when the account, entitlement, or
container is unavailable. Remote paths contain only a bounded Vault namespace,
object kind, opaque UUID, revision UUID, and ciphertext-generation digest.
Names, user metadata, manifests, indexes, and content are carried only in
client-side authenticated ciphertext.

Every remote operation uses `VaultAuthenticatedCiphertext`. Construction
checks the wrapped-DEK header, object/revision/role/root-version binding, chunk
layout, and immutable SHA-256 generation. A downloaded object is decoded
against its expected identity and then every AES-GCM tag, including the wrapped
DEK, is authenticated with the synchronizable Keychain root key before durable
installation. Structural validation alone is not treated as authentication.

Remote generations are immutable. Replaying identical bytes is idempotent;
different bytes at the same kind/object/revision/generation path are a
conflict. Revision-specific paths can coexist, so concurrent revisions are not
silently overwritten or selected. The encrypted manifest is the higher-level
revision authority; unresolved iCloud file conflicts are surfaced as
`conflicted` and require reconciliation rather than last-writer-wins. Exact
downloads additionally require the provider's `.current` status—unknown,
stale, merely present, or merely downloaded is not current.

iCloud upload is asynchronous. A coordinated local write returns `pending`
until `ubiquitousItemIsUploaded == true` and uploading is false. Upload errors
are `failed`; the durable upload job is not marked succeeded while pending.
Provider-state and explicit-user wakeups make a delayed job immediately
eligible for another bounded attempt. Only fixed error codes are persisted;
localized provider errors, credentials, names, paths, and payload data are not.

`keepLocalCopy == false` is a policy request, not a promise. Eviction is only
reported as complete after resource values confirm the item is no longer
downloaded. Accepted-but-unconfirmed eviction remains `pending`; ineligible
items and fixed redacted failures remain visible. iCloud has no portable remote
range API, so `supportsRangeReads` is false and the generic fallback performs a
validated full read followed by a local slice. True streaming is deferred.

## Durable sync

`VaultSyncCoordinator` durably stages ciphertext before enqueueing upload,
download, index/manifest-artifact upload, or delete work. Its idempotency key
includes operation, backend location/container/Vault identity, object kind and
UUID, revision, and immutable payload generation. Jobs use a fresh lease token
on every claim; an owner string alone cannot heartbeat or complete a reclaimed
lease.

Transient failures use bounded exponential backoff and a maximum attempt
count. Permanent failures and exhaustion enter terminal `failed`; provider
state or user wake can resume eligible nonterminal jobs. Success is recorded
only after the exact remote state is current (or, for delete, missing).
Manifest and index artifacts use the same typed encrypted boundary, and remote
deletes are durable, revision-scoped operations.

## Validation and external gates

Deterministic tests inject file/ubiquity coordinators and cover pending upload,
provider wake, stale/current downloads, conflicts, revision/location/
generation idempotency, authenticated-download rejection, artifact upload,
delete, redacted error persistence, bounded retry, eviction state, and unique
lease tokens. Source-boundary tests keep extraction, embeddings, and search
free of backend/network dependencies. `VaultBackendTests` runs with the rest of
the `LunaVaultTests` bundle under `scripts/run_vault_tests.sh`.

Simulator tests cannot prove a real Apple ID's provider transitions. Before
shipping iCloud, run a separately approved, signed physical-device smoke test
that verifies container provisioning, upload confirmation, cross-device
download, conflict surfacing, and confirmed local eviction. Do not replace that
external gate with a simulator fake.
