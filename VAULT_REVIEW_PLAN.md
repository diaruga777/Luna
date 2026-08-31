# Luna Vault review — findings and fix plan (2026-08-31)

> **STATUS: COMPLETE.** All packages landed on `vault-review-pass` and merged to
> main. Commit map: A `00382b3c4` (crypto), B `14eaba4b1` (storage),
> E `52652f3eb` (tailnet), H `11af8e451` (UI/shell), G `87691805a` (search),
> D `58f3371f8` (backend), F `199e078a8` (sync/setup), C `4d33e0658` (Mac
> server), plus `fcfcafebe` and `d5e202f8c` (integration fallout: the
> drainPendingCleanup fileManager seam restored, `remoteRevision` returns the
> tombstone revision on `.notFound`, three test fixes).
> Final full suite (fresh simulator): **3447 tests, 10 skipped, 6 failing
> tests — every one pre-existing on main**, none in a Vault suite:
> `ProductHistoryPillRenderTests` (12px vs 20px), `ScrollDirectionImmersionTrackerTests`,
> `UtilCardTests.testAnExpiredEntryIsNoEntry`, `WeeklySaveTests.testAnExpiredRecordClearsTheRow`
> (all four fail deterministically on main's checkout), and two intermittent
> flakes (`ShareSurfaceDriverTests` product editor, `LinkImportPreviewLoaderTests`
> in-flight fetch) that also fail/pass on main. The two expiry-named failures
> look date-rot-shaped and predate this pass — worth a separate look.

Reviewed at commit `3fcc26521` (main, clean tree). Eight parallel review agents swept
every Vault production module — crypto, storage, Mac server + companion, backend
clients, the embedded Tailscale layer, sync + setup, search/indexing, and UI/app
shell (~18,300 lines) — for correctness, bugs, edge cases, performance, and
simplicity. Every finding below was verified against the code and its callers
before it was listed. Fixes are applied by per-package agents on branch
`vault-review-pass` and merged to main after a green full suite.

## Headline issues (fix first)

| # | Sev | Where | Problem |
|---|-----|-------|---------|
| 1 | crit | KindWiring+Vault / VaultSyncRuntimeController | `BGTaskScheduler.register` re-runs on every runtime rebuild → deterministic `NSInternalInconsistencyException` crash on first-run setup and on any Mac/storage Settings change |
| 2 | crit | VaultTailnetNodeRunner / TailscaleNode | 45s timeout can never deliver `tailscale_close` (up/close serialize on one actor) → leaked Go nodes, duplicate node on one state dir, cooperative-pool starvation |
| 3 | high | VaultMacClient | Terminal `.partial` on the final chunk treated as success → scheduler deletes the only staged payload; object never assembled on the Mac |
| 4 | high | VaultICloudBackend | Superseded revision payloads never pruned → every update permanently duplicates ciphertext in the user's iCloud quota |
| 5 | high | VaultMacChannelServer | Every clean session close counts as an auth failure; peer key includes the ephemeral port → normal sync traffic locks the companion out (self-DoS) |
| 6 | high | LunaVaultMac idempotency | putChunk records embed the cumulative receivedChunks array → manifest grows quadratically, wedging uploads permanently near 9.4 GiB (contract says 100 GiB) |
| 7 | high | VaultImportCoordinator | Two crash windows `repairInterruptedImports` can never finish (strands plaintext, loops forever); a third mints a permanently unfulfillable upload job |
| 8 | high | VaultSearchIndex | Non-transactional schema migration bricks the index after a crash; restore leaves stale WAL that silently corrupts the restored snapshot |
| 9 | high | VaultTailscaleFrameChannel | No SO_NOSIGPIPE → routine peer disconnect mid-send terminates the app with SIGPIPE |
| 10 | high | VaultShareViewController | Share extension never calls completeRequest → sheet hangs forever |
| 11 | high | VaultAuthenticatedCiphertextFile | `frame(at:)` O(n²) walk → hours of syscalls to authenticate/decrypt large objects; missing nonce-dedupe on the file seal path |

## Work packages

One Sonnet fix agent per package; file sets are disjoint. Each agent applies its
package's fixes, adds a focused regression test only where a fix changes behavior
that is cheap to pin (per the repo test-value bar), and leaves build/commit to the
orchestrator.

| Pkg | Files | Scope |
|-----|-------|-------|
| A | `LunaLibraries/Sources/LunaVaultCrypto/*`, `LunaVaultModels/*` | crypto cluster findings |
| B | `LunaLibraries/Sources/LunaVaultStorage/*` | storage cluster findings |
| C | `LunaLibraries/Sources/LunaVaultMac/*`, `LunaVaultTailscale/Sources/LunaVaultMacCompanion/main.swift` | Mac server cluster findings |
| D | `LunaLibraries/Sources/LunaVaultBackend/*` | backend client cluster findings |
| E | `LunaVaultTailscale/Sources/LunaVaultTailscale/*`, `LunaVaultTailscale/Sources/TailscaleKit/*` | Tailscale cluster findings |
| F | `LunaLibraries/Sources/LunaVaultSync/*`, `LunaVaultSetup/*` | sync + setup cluster findings |
| G | `LunaLibraries/Sources/LunaVaultSearch/*`, `LunaVaultIndexExtraction/*`, `LunaLibraries/Package.swift`, `LunaLibraries/Tests/LunaVaultSearchTests/` (delete) | search cluster findings except the VaultHomeViewController item (→ H) |
| H | `LunaLibraries/Sources/LunaVaultUI/*`, `LunaVault/*`, `LunaVaultShare/*` | UI/shell cluster findings + search cluster's renderGroups item |

## Cross-package decisions (agents must follow, not re-decide)

- **Idempotency conflict poisoning (C + D):** the server (C) stops memoizing
  responses whose status is not `.accepted`/`.partial`; the client (D) refreshes
  its revision cache from every `.conflict` response and uses monotonic
  `nextLogicalTime(after:)` in the Stage-4 puts. Both halves are required.
- **putChunk record shape (C):** store put responses without the receivedChunks
  array; rebuild it from the partial record on replay, the way readRange rebuilds
  from disk. The client (D) independently persists an acked-chunk high-water mark.
- **Wire format and pairing crypto are untouched.** No package changes frame
  layout, AAD contents, or the handshake.
- **Vendored TailscaleKit (E):** minimal diffs only, marked with the existing
  "Luna vendoring change" comment convention.

## Deferred (listed, deliberately not fixed in this pass)

- **Companion pairing mode (`--pair`)** — the CLI cannot yet run the pairing
  ceremony end-to-end (offer/enroll). Feature work, not a fix; needed before the
  two-device validation matrix. Flagged for a product decision.
- **UI stored-closure wiring → protocol witnesses** — `VaultSettingsActions`,
  the home VC's closure inits, and `VaultWiring`'s statics violate the
  protocol-witness standard. A real refactor; schedule as its own task.
- **Vault L10n + appearance adoption** — the cluster bypasses `L10n.string` and
  the LunaSky appearance system entirely. Either an intentional exemption to note
  in `claudedocs/vault-mac.md` or a migration; product decision.
- **Payload store blocking work off the cooperative pool** — structural change,
  do when the store gets a foreground caller.

## Verification protocol

1. Each package lands as one commit on `vault-review-pass` after
   `xcodebuild build-for-testing -scheme Luna -destination 'generic/platform=iOS Simulator' DIAGNOSE_MISSING_TARGET_DEPENDENCIES=NO` is green.
2. Full suite once at the end: `scripts/run_tests.sh --fresh`.
3. Merge to main, delete worktree + branch.

---

# Full findings by cluster

# Cluster: LunaVaultCrypto + LunaVaultModels

## Findings

### Correctness

- **Severity**: medium
  **Category**: correctness
  **Location**: `LunaLibraries/Sources/LunaVaultCrypto/LunaVaultCrypto.swift:272-279, 309, 326-337` (via `VaultAuthenticatedCiphertext.swift:185-201`)
  **Defect**: For an empty-plaintext object, `VaultChunkedCryptor.open`/`openRange` — and therefore `VaultAuthenticatedCiphertext.authenticate()` and `verified()` — never verify the single empty chunk's GCM tag; only the wrapped-DEK frame is authenticated.
  **Failure scenario**: `open` calls `decrypt(frames, parsed, 0..<0, ...)`; `planRange(0..<0, plaintextLength: 0)` returns `0..<0`, so the chunk loop body never runs and frame 1's tag is never opened. A frame 1 with a garbage nonce/tag (structurally valid: `chunkIndex 0`, `plaintextLength 0`, `ciphertext.count == 16`) passes `verified(rootKey:)`, contradicting both doc comments and the file-based twin, whose `authenticate()` explicitly calls `openFrame` for the `plaintextByteCount == 0` case (`VaultAuthenticatedCiphertextFile.swift:219-223`). Existing tamper test (`VaultCryptoStorageTests.swift:227`) only covers an empty *range* over non-empty plaintext.
  **Fix**: In `decrypt`, when `parsed.length == 0`, open chunk 0 explicitly (as the file version does), or make `planRange` return `0..<1` for the empty-plaintext full-open case.

- **Severity**: medium
  **Category**: correctness
  **Location**: `VaultAuthenticatedCiphertextFile.swift:759-763` (used at 674, 736) vs `LunaVaultCrypto.swift:339`
  **Defect**: In-memory `seal` defends against broken RNG with `uniqueNonce(&seen)` (nonce-reuse throws — pinned by `VaultCryptoStorageTests.swift:228`), but both `sealFile` overloads use plain `randomNonce()` with no dedupe — silent nonce reuse under one DEK.
  **Failure scenario**: A stuck `VaultRandomBytesGenerating` witness passed to `sealFile` for a multi-chunk file → every chunk sealed under same DEK+nonce → catastrophic GCM auth-key recovery, no error raised.
  **Fix**: Track a `Set<Data>` of issued nonces across the DEK wrap and chunk loop in both `sealFile` overloads (or the shared helper per the duplication finding), throw on repeat, mirroring `uniqueNonce`.

### Edge cases

- **Severity**: low
  **Category**: edge-case
  **Location**: `VaultAuthenticatedCiphertext.swift:89-129` vs `VaultAuthenticatedCiphertextFile.swift:107`
  **Defect**: In-memory structural validator accepts `chunkSize == 0` with `plaintextLength > 0` (N frames of empty ciphertext), which the file validator rejects (`guard actualChunkSize > 0 || metadata.plaintextByteCount == 0`). Validator-parity gap between the two parsers of the same format.
  **Fix**: Add `guard chunkSize > 0 || first.plaintextLength == 0` after line 90, matching the file parser.

- **Severity**: low
  **Category**: edge-case
  **Location**: `VaultAuthenticatedCiphertextFile.swift:301-311`
  **Defect**: `frame(at:)` re-parses length prefixes from the (mutable-in-place) inode on every call but enforces only `length <= Int.max`, dropping the 8 MiB + header ceiling init enforced (line 66). An in-place `pwrite` after init can plant a huge length → single `Data` allocation up to full cached `fileSize` (100 GB).
  **Fix**: Apply the same `length <= UInt64(8_388_608 + VaultChunkEnvelope.headerSize + 16)` guard in `frame(at:)` (and the walk loop) that init uses.

- **Severity**: low
  **Category**: edge-case
  **Location**: `VaultAuthenticatedCiphertextFile.swift:174-184` vs `:568-587`
  **Defect**: `decrypt(to:)` creates/opens its destination with path-based `FileManager.createFile` + `FileHandle(forWritingTo:)` (symlink-following, non-exclusive) while `writeCopy` uses the atomic `createAnchoredWriter` (`openat` + `O_NOFOLLOW|O_EXCL`). Symlink swap between check and open → plaintext written to attacker-chosen path. Also on decrypt error the cleanup deletes a caller-precreated destination file.
  **Fix**: Route `decrypt(to:)` through `createAnchoredWriter`, drop the FileManager pre-checks; remove only files this method created.

### Performance

- **Severity**: high
  **Category**: performance
  **Location**: `VaultAuthenticatedCiphertextFile.swift:301-311` (callers: `:194-202`, `:225-231`; `LunaVaultSync/VaultFileSyncPayloadStore.swift:242`)
  **Defect**: `frame(at: index)` walks all preceding frame-length prefixes from file start, so `decrypt`, `authenticate`, and `collectFrames` — each calling it in a 0..<frameCount loop — perform O(n²) 8-byte `pread` syscalls. 100 GB object at 4 MiB chunks ≈ 25,600 frames → ~328M length preads per `authenticate()`; at the 65,537-frame cap ~2.1B syscalls. `verified(rootKey:)` is on the real sync path (`VaultFileSyncPayloadStore.swift:132`).
  **Fix**: Init already visits every frame; record frame offsets (`[UInt64]`) or memoize a `(lastIndex, lastOffset)` cursor in `StableReadFile` so sequential access is O(1) amortized. No behavior change.

- **Severity**: medium
  **Category**: performance
  **Location**: `VaultAuthenticatedCiphertext.swift:231-239` (and `:185-187`)
  **Defect**: `generation(for:)` concatenates every frame into one `digestInput` Data before hashing (duplicates whole object in memory at init); `authenticate()` materializes complete plaintext via `open()` just to discard it.
  **Fix**: Stream into an incremental SHA256 hasher (as file-based init does); make `authenticate()` open chunk-by-chunk via `openFrame` and discard each chunk.

### Simplicity

- **Severity**: low
  **Category**: simplicity
  **Location**: `VaultAuthenticatedCiphertextFile.swift:639-697` vs `:702-757`
  **Defect**: Two `sealFile` overloads are ~55 nearly identical lines; only difference is byte source (`FileHandle` vs `StableReadFile`) and size acquisition. Cause of nonce-dedupe drift.
  **Fix**: Extract one private implementation taking `size` plus a reader witness (tiny `read(upToCount:)` protocol both satisfy); both overloads delegate.

- **Severity**: low
  **Category**: simplicity
  **Location**: `VaultAuthenticatedCiphertextFile.swift:553-563` (used at `:280`)
  **Defect**: `hasSymlinkComponent` is the racy lstat-per-component check the comment at 459-462 rejects, fully subsumed by `createAnchoredWriter`'s atomic `O_NOFOLLOW` walk two lines later.
  **Fix**: Delete `hasSymlinkComponent` and the call at line 280.

- **Severity**: low
  **Category**: simplicity
  **Location**: multiple — dead code cluster
  - `VaultAuthenticatedCiphertextFile.swift:17` — `maximumHeaderBytes` unreferenced.
  - `:43` — `frameCount <= UInt32.max` tautology; `:119` re-checks `frameCount >= 2` already guarded at `:42`.
  - `:59, :116, :141` — `previousLength` written, only consumed by `_ =`.
  - `:519-527` — `StableReadFile.seekToEnd`/`seek(toOffset:)` no callers.
  - `LunaVaultCrypto.swift:75-86` — `VaultKeychainQuery` and `VaultKeychainStore.query(for:operation:)` no callers anywhere.
  - `LunaVaultModels.swift:60-70` — `VaultHLC` referenced by nothing; its `encoded` uses wrapping `&* 1_000_000 &+ counter` which would corrupt ordering for `counter >= 1_000_000` if ever adopted.
  **Fix**: Delete unused declarations; if `VaultHLC` kept, use checked math / validated counter bound.

## Clean dimensions
Crypto otherwise sound: fresh random nonces on honest paths, complete AAD binding (vaultID length-prefixed, role, root version, objectID, revision, chunk index, total length), DEK wrap bound to vault/object/revision + role `.dek`, constant-time tag compares via CryptoKit, checked size/offset arithmetic. Models clean apart from dead `VaultHLC`. Concurrency: `StableReadFile` pread-based with locked cursor; `VaultRootKeyManager` serializes via static lock + cross-process flock; `rotate` read-back-verifies.

## Overall
Careful cryptographic plumbing; defects live in the seams between the two parallel implementations (in-memory vs file). Priority: the quadratic walk, the two parity gaps, fold the seal loops into one implementation.
# Cluster: LunaVaultStorage

## Findings

### Correctness

- **Severity**: high | **Category**: correctness (crash-mid-commit recovery)
  **Location**: `LunaLibraries/Sources/LunaVaultStorage/VaultAtomicImportStore.swift:61-100` (and 107-133), with `LunaVaultStorage.swift:469`
  **Defect**: A retried `insertAtomically` with `deferVisibility: false` never republishes the ready bit — the replay path skips `writeContent` (the only place that sets it) when a valid content capability already exists.
  **Failure scenario**: `writeContent` installs content, process dies before `markObjectReadyLocked` commits. Caller retries per the type's own contract: object row exists, `localContentCapability != nil` → write skipped, jobs enqueued — but `object_visibility.ready` stays 0 forever, so `claimJob`/`claimNextJob` (`jobObjectIsReadyLocked`, 1077-1090) never release the upload/index jobs. Permanent wedge. The one production caller (`VaultImportCoordinator.swift:705,718`) avoids it via `deferVisibility: true` + explicit `setObjectReady`, but `deferVisibility` defaults to `false`.
  **Fix**: In both `insertAtomically` overloads, when `!request.deferVisibility`, call `setObjectReady(request.record.id)` after the content/jobs step even when the write was skipped.

- **Severity**: medium | **Category**: correctness
  **Location**: `LunaVaultStorage.swift:741-745, 405-424, 1112-1138`
  **Defect**: `objectIsReady` doc claims the visibility bit "is repaired from the content generation marker on the next repository launch," but nothing writes `object_visibility` at launch; neither `upsert` (revision advance) nor `tombstone` clears it.
  **Failure scenario**: Object ready at revision A; remote sync `upsert`s revision B (or tombstone leaves `ready=1`) → workers claim revision-B jobs against stale/absent payload and spin on capability failures; nothing repairs it.
  **Fix**: Reset `ready=0` inside `upsert` when the winning record's revision differs, and inside `tombstone`'s update branch; implement the launch-time repair from the generation marker or delete the false comment.

- **Severity**: medium | **Category**: correctness (durability)
  **Location**: `LunaVaultStorage.swift:74-95` (`VaultSecureFileAccess.install`), used by all three `writeContent` overloads
  **Defect**: Files are fsynced but `install` never fsyncs the destination directory it already holds open (sibling companion module does: `VaultSecureFileSystem.syncDirectory`, `LunaVaultMac.swift:621`). Doc contract says parent directories are fsynced.
  **Failure scenario**: Power loss after `writeContent` returns: SQLite (synchronous=FULL) durably has `ready=1` + jobs, but un-fsynced directory entries for `content`/`.content-generation` are lost → "ready" object with no/old payload, staged source already deleted.
  **Fix**: After the `renameat` in `install`, `fsync(destinationDirectory)`; same for `unlinkat` in the backup-removal path if strict ordering matters.

- **Severity**: low | **Category**: correctness (TOCTOU/symlink)
  **Location**: `LunaVaultStorage.swift:1100, 1106`
  **Defect**: `enqueueCleanupLocked`/`drainPendingCleanup` read the generation marker with path-based `String(contentsOf:)` (symlink-following, unbounded), bypassing the anchored no-follow 256-byte `readBoundedFile` every other marker read uses; they also delete via path-based `fileManager.removeItem`.
  **Fix**: Read through `readBoundedFile(_:maximumBytes: 256)`; delete through `VaultSecureFileAccess.removeRegularFile`/`removeTree`.

- **Severity**: low | **Category**: correctness (idempotency digest coverage)
  **Location**: `VaultAtomicImportStore.swift:77-89, 121-127`
  **Defect**: Replay acceptance keys only on `(objectID, revision)`; body not compared against installed capability's `contentDigest` — a retry with changed bytes for the same revision silently "succeeds" keeping old bytes. Weaker than the doc's idempotency rule.
  **Fix**: When the write is skipped, compare `capability.byteCount`/`contentDigest` against the request and throw `invalidArtifact` on mismatch.

### Edge cases

- **Severity**: medium | **Category**: edge-case (crash window wipes thumbnail cache)
  **Location**: `VaultThumbnailStore.swift:293-296` (also 137-140)
  **Defect**: `persistIndex` removes `index.json` then renames staging into place — needless non-atomic window (`install` already replaces atomically via `renameat`).
  **Failure scenario**: Crash between remove and install: `index.json` gone → next `init` starts empty and `repair()`'s orphan sweep deletes every payload file — full cache wipe. Same pattern in `put` loses one thumbnail.
  **Fix**: Delete both pre-remove calls; let `install`'s rename replace atomically.

- **Severity**: low | **Category**: edge-case
  **Location**: `VaultThumbnailStore.swift:270-279`
  **Defect**: `removeLocked(key)` removes the whole shared `objectID/revision` directory but evicts only one key from the index — deletes sibling-generation payloads whose entries remain (self-healing miss later, index/disk divergence).
  **Fix**: Remove only `payloadURL(for: key)`; delete the directory only when no other index entry shares it.

Zero-length objects handled correctly in all `writeContent` paths; path traversal via IDs closed (UUID-only components + `validatedComponents`).

### Performance

- **Severity**: high | **Category**: performance
  **Location**: `VaultThumbnailStore.swift:391-397` (via 161-199 and 304-321), calling `LunaVaultStorage.swift:689-721`
  **Defect**: Every thumbnail read (`data(for:)` → `isCurrent` → `localContentCapability`) and every index entry during init `repair()` streams SHA-256 over the object's ENTIRE content file (up to 100 GB).
  **Failure scenario**: A grid of 50 thumbnails over multi-GB videos hashes gigabytes per cell on the repository's serial queue, serializing all vault ops. (Store currently constructed only in `VaultStage5Tests` — designed-in cost, not shipped regression.)
  **Fix**: Cheap currency check in `isCurrent` — compare revision/generation against the object row + the 166-byte generation marker (`readBoundedFile`) without re-hashing; keep full digest for `beginPreviewLease`.

- **Severity**: medium | **Category**: performance
  **Location**: `VaultThumbnailStore.swift:193-196`
  **Defect**: Every successful read bumps `lastAccessedAt` and rewrites the whole JSON index (encode all, protected file, fsync, rename) — full durable index write per cache hit.
  **Fix**: Mark dirty on access; persist on debounce/eviction/invalidation only.

- **Severity**: medium | **Category**: performance
  **Location**: `LunaVaultStorage.swift:1164-1165`
  **Defect**: `sync` runs `protectDatabaseFiles` after EVERY repository call (~6 attribute syscalls) including pure reads; a transient attribute-read hiccup turns a successful read into thrown `protectionRequired`.
  **Fix**: Protect once at open plus after operations that can create `-wal`/`-shm`; or memoize by inode.

- **Severity**: low | **Category**: performance
  **Location**: `LunaVaultStorage.swift:913`; `VaultThumbnailStore.swift:355-385`; `LunaVaultStorage.swift:858-877`
  **Defect**: (a) `putEncryptedArtifact` re-runs the validating init on an already-validated `VaultEncryptedArtifact` and stores frames as JSON (base64 +33% on up-to-16MiB payloads); (b) `repair()` does three duplicate linear scans per payload file, recomputing SHA-256(generation) inside comparisons; (c) `jobs(kinds:)` is N+1 (SELECT ids then `jobLocked` per id).
  **Fix**: (a) validate only on read path, consider length-prefixed blob; (b) build one `[URL: VaultThumbnailEntry]` map per revision dir; (c) select all job columns in one query.

### Simplicity

- **Severity**: low | **Category**: simplicity (dead code)
  **Location**: `LunaVaultStorage.swift:210, 885, 1097, 1198, 1014/1044/1050; VaultThumbnailStore.swift:481-487; VaultAtomicImportStore.swift:94-99, 130-132`
  **Defect**: Verified-unreferenced/no-op: `VaultStorageConfiguration.cacheQuotaBytes` (zero refs), duplicate guard at 885, `removeContentLocked` (1097, never called), `FileHandle.closeAfterSynchronize` (1198, never called), `cache_activity` table still created for new DBs yet never read/written (preview_leases replaced it), always-throwing `setPreviewActive`/`VaultCacheCoordinator.beginPreview`/`endPreview` stubs with stale doc comments, `catch { throw error }` blocks.
  **Fix**: Delete dead members and duplicate guard; stop creating `cache_activity`; fix comments.

- **Severity**: low | **Category**: simplicity (duplication)
  **Location**: `LunaVaultStorage.swift:426-615`
  **Defect**: Three `writeContent` overloads repeat the same ~40-line stage → validate → backup → install → rollback → mark-ready dance; already drifted (streaming overloads don't restore `.previous` on failed install; Data overload does).
  **Fix**: Extract one private `installContent(source:object:authenticatedGeneration:visibility:)` taking a source enum; overloads become thin adapters.

## Verified non-findings
Revision-ordering parity holds vs companion (`compare` at 1094 vs `LunaVaultMac.swift:624-629`); tombstone precedence correct; lock ordering one-way (thumbnail NSLock → repo queue); anchored `VaultSecureFileAccess` genuinely TOCTOU/symlink-solid apart from the two path-based reads noted.

## Overall
Careful systems code; weaknesses at the seams the doc names: durability ordering (no parent-dir fsync), crash-replay of the publication bit (promised repair never written), thumbnail sidecar whose integrity checks cost a full-content hash + durable index rewrite per hit. Priority: ready-bit replay, parent fsync, the two remove-before-rename windows; do the thumbnail perf items before wiring the store into real UI.
# Cluster: LunaVaultMac + companion CLI

## Findings

- **Severity: high** | **Category: correctness**
  **Location:** `LunaLibraries/Sources/LunaVaultMac/VaultMacChannelServer.swift:88-94` (with `begin` at 37-52)
  **Defect:** Every session end is recorded as an authentication failure — `serve()` can only exit by throwing (no goodbye frame), so a clean client close, an idle timeout, and a real auth failure all reach `gate.failed(peer:)`.
  **Failure scenario:** Client opens a fresh session per backend operation. Each close makes the server's pending `receive()` throw `unavailable` → one failure in the peer bucket AND the `"*"` bucket. Global budget = 5×8 = 40/minute, so a sync sweep touching ~20-25 objects/minute locks the companion out for every peer until entries age past 60s. Legitimate use self-DoSes the server; no test pins this.
  **Fix:** Only call `gate.failed` for pre-session errors (handshake decode, `authenticationFailed`, `replayedFrame`, timeout before `accept`). Post-acceptance channel errors (`unavailable`, idle `expired`, `revoked`) are normal teardown.

- **Severity: high** | **Category: correctness**
  **Location:** `VaultMacNetwork.swift:79` and `VaultTailnetListener.swift:60-64`, consumed by gate at `VaultMacChannelServer.swift:37-52`
  **Defect:** Peer key handed to the gate is `String(describing: connection.endpoint)` / `tailscale_getremoteaddr` including the remote ephemeral port — every connection is a brand-new "peer"; per-peer failure budget never accumulates.
  **Failure scenario:** Unauthenticated LAN peer lets the 10s handshake timeout fire repeatedly; each failure lands in a fresh per-peer bucket but fills the shared `"*"` bucket — 40 cheap failures lock out the paired iPhone. The per-peer half of the documented bound is inert.
  **Fix:** Strip the port (and resolve the host part for NW) before using as the gate key.

- **Severity: high** | **Category: correctness** (perf root cause)
  **Location:** `LunaVaultMac.swift:284-287` (idempotency insert), `375-377`/`400-402` (responses embed full `receivedChunks` array), `522-528` (trim only above 10,000 records), `534-550` (16 MiB manifest cap, rewritten per request)
  **Defect:** Each `putChunk` idempotency record stores the response including the cumulative `receivedChunks` array — the encrypted manifest grows quadratically in chunk count and hits the 16 MiB cap long before documented limits.
  **Failure scenario:** Sum ≈3·n² bytes of JSON crosses 16 MiB near n≈2,300 chunks — about 9.4 GiB at 4 MiB chunks, vs the documented 100 GiB / 65,536-chunk contract. `persistManifest` throws mid-upload, service returns `.invalid`, client throws `conflictingRevision` without dropping its pending record, every resume wedges at the same chunk. Permanently stuck upload. Also each 4 MiB chunk pays a full manifest re-encrypt + atomic write + two fsyncs.
  **Fix:** Store put responses without the `receivedChunks` array (rebuild from the partial record on replay, like `readRange` does), or store a digest. Cap what a putChunk idempotency record retains.

- **Severity: high** | **Category: correctness** (possibly staged gap — nothing marks it)
  **Location:** `LunaVaultMacCompanion/main.swift:75-111`
  **Defect:** The companion CLI cannot complete the documented pairing handshake: `--initialize` mints a credential from local random bytes; no CLI command creates a pairing offer/one-time code or accepts an enrollment. The iPhone Stage 5 flow consumes an offer+code capsule and produces an enrollment only `VaultMacPairingCoordinator.enroll` (called by nothing outside tests) can convert. No iPhone path imports raw credential JSON → every session handshake against a real companion fails `authenticationFailed`; end-to-end pairing unreachable with the shipped binary. Also no runtime revoke/rotate trigger in the CLI.
  **Fix:** Add a companion pairing mode (e.g. `--pair`): create offer via `VaultMacPairingCoordinator`, print capsule for QR/paste, read back enrollment, save derived credential. Or document `--initialize` as test-only.

- **Severity: medium** | **Category: edge-case**
  **Location:** `LunaVaultMac.swift:353-360` (partial revision guard), `421-433` (delete)
  **Defect:** A stale partial upload cannot be superseded: `putChunk` conflicts whenever incoming revision differs from the stored partial's; `delete` clears partials only when a committed object exists; nothing abandons a partial.
  **Failure scenario:** First-ever upload interrupted, iPhone loses its pending-upload record; retry generates a new revision → `.conflict` → client clears pending, retries with yet another revision → conflict again, for up to `partialUploadLifetime` (7 days, pruned only at restart). Same wedge after a failed LVF validation leaves a complete-but-invalid partial.
  **Fix:** In `putChunk`, when incoming revision compares strictly greater than the stored partial's, discard the stale partial and start new instead of conflicting.

- **Severity: medium** | **Category: edge-case**
  **Location:** `VaultMacChannelServer.swift:98, 103-104, 119` (unbounded sends); `VaultTailscaleFrameChannel.swift:115-129`
  **Defect:** Idle timeout wraps only `receive`; `channel.send` has no timeout and both channel impls block indefinitely when the peer stops reading.
  **Failure scenario:** A paired-but-buggy client requests a 4 MiB `readRange` (~7.5 MB framed) and stops reading. Server's `send` never returns, the gate slot is held until restart; 8 such connections exhaust `maximumConnections` permanently. Pre-auth peers can't trigger it (challenge fits in socket buffer).
  **Fix:** Wrap `channel.send` in `serve` (handshake sends and line 119) in the same `withTimeout` used for receives, using `idleTimeout`.

- **Severity: medium** | **Category: performance**
  **Location:** `VaultMacChannelServer.swift:37-59` (`VaultMacConnectionGate`)
  **Defect:** `failures` dictionary grows without bound: `begin` writes an entry for every peer string seen, nothing removes entries — and every connection is a unique peer string. Monotonic memory growth; attacker can grow it arbitrarily.
  **Fix:** Drop entries whose arrays are empty after the 60s filter; sweep buckets whose newest timestamp is older than 60s.

- **Severity: medium** | **Category: performance**
  **Location:** `LunaVaultMac.swift:246-292, 373, 492-513`
  **Defect:** Every request — including read-only `stat` and each 4 MiB `readRange` — inserts an idempotency record, re-encrypts/atomically rewrites the entire manifest with two fsyncs, and runs `cleanupCommittedState`'s directory scan + fsync; all synchronous file I/O inside the actor on a cooperative-pool thread; per-chunk `receivedChunks.contains` + `sort` is O(n²) over an upload.
  **Failure scenario:** A 100 GiB download issues 25,600 readRange requests, each rewriting a manifest that can be megabytes — hundreds of GB of bookkeeping writes; all other connections serialize behind the actor.
  **Fix:** Skip idempotency persistence for read operations; skip `cleanupCommittedState` when nothing changed; use a `Set<UInt32>`/bitset for received chunks; consider moving disk I/O off the actor executor.

- **Severity: low** | **Category: edge-case**
  **Location:** `VaultMacNetwork.swift:42-46`; `main.swift:137-138`
  **Defect:** `VaultMacTCPListener` installs no `stateUpdateHandler` — bind failure (port in use) invisible while the companion unconditionally prints "Listening on host:port".
  **Fix:** Observe listener state and surface `.failed` (log + exit or report), mirroring the tailnet Task's `fail(...)`.

- **Severity: low** | **Category: edge-case**
  **Location:** `VaultMacChannelServer.swift:97` with `VaultMacProtocol.swift:615`
  **Defect:** Challenge lifetime = `authenticationTimeout` (10s) and client checks expiry against its own clock — wire-latency budget doubles as cross-device clock-skew tolerance. iPhone ≥10s ahead fails every handshake with `expired`. Replay safety doesn't depend on this expiry (session IDs single-use).
  **Fix:** Independent challenge lifetime (60-120s); keep `authenticationTimeout` for the socket wait.

- **Severity: low** | **Category: simplicity**
  **Location:** `LunaVaultMac.swift:143-149, 13/639, 716-720`; `VaultMacProtocol.swift:379`
  **Defect:** Dead code: no-op `do/catch{throw}` in `VaultMacSessionAuthority.accept`; `VaultMacCompanionError.objectNotFound` never thrown (service catch unreachable); `rejectSymlinkComponents` no caller; `VaultMacHandshakeKind.rejected` never constructed.
  **Fix:** Unwrap the do/catch (keep comment), delete `rejectSymlinkComponents` and `objectNotFound` case+catch, send `.rejected` on auth failure or drop the case.

## Clean dimensions
Handshake/replay/session-ID logic sound (single-use pending consumed under lock; `consumed.removeAll()` at 4,096 cannot reopen replay; sequence numbers gap/replay/direction/session-bound; revocation/rotation checked per frame). Frame-length validation correct on both channels. Gate slot accounting leak-free (`defer { channel.close(); gate.end() }`).

## Overall
Crypto core carefully built and matched to the doc; openat/O_NOFOLLOW discipline thorough. Defects cluster in the operational shell: gate failure accounting punishes normal traffic and keys on ephemeral ports; idempotency record shape breaks the 100 GiB contract at ~9.4 GiB with per-chunk manifest rewrites; companion CLI can't perform the pairing ceremony. Fix gate semantics + idempotency shape before any two-device validation.
# Cluster: LunaVaultBackend (client transports)

## VaultMacClient.swift

- **Severity: high | correctness** — `VaultMacClient.swift:373, 385-387` (file variant `430, 436-443`): upload loop accepts `.partial` for the FINAL chunk and declares the upload complete — the server's commit signal (`.accepted` on last chunk) is never required.
  **Failure scenario:** Interrupted upload resumed after companion restart dropped partial state but within the 30-day idempotency window: early chunks replay stored `.partial` responses (chunk files gone); later chunks create a fresh partial missing early chunks; final chunk returns `.partial`. Client logs "Upload complete", caches revision, removes pending record, `put` returns `.current`, and the scheduler DELETES the staged local payload (`LunaVaultSync.swift:122, 152`). Object never assembled on the Mac; sync state claims it is.
  **Fix:** After the loop, require the last response's status to be `.accepted`; treat terminal `.partial` as retryable failure keeping the pending record and staged payload.

- **Severity: high | correctness** — `VaultMacClient.swift:348-353` (Data) and `404-410` (file): a pending-upload record with a mismatched digest throws `conflictingRevision` without removing the stale record and without any server round trip — permanently blocks the object. File variant maps the error to `.io` (transient) → scheduler retries the dead path forever.
  **Fix:** On byteCount/digest mismatch, remove the stale pending record and start a fresh upload.

- **Severity: high | correctness** — `VaultMacClient.swift:365-371, 423-428` with `VaultMacProtocol.swift:598-605` and server `LunaVaultMac.swift:251-252, 284, 344-348`: idempotency key is deterministic (objectID+revision+chunkIndex) but the signed request embeds a fresh `logicalTime` per attempt, and the server memoizes even `.conflict` responses under the key, rejecting same-key/different-signature as conflict. One `.conflict` → pending record deleted → retry mints new logicalTime → same key, different signature → conflict on chunk 0 for up to 30 days; that revision UUID can never be uploaded.
  **Fix:** Keep the frozen revision (incl. logicalTime) across attempts, or have the server not store non-`accepted`/`partial` responses in the idempotency map.

- **Severity: high | correctness** — `VaultMacClient.swift:680-686` (`remove`) and `475-488` (`removeCiphertext`): `remove(identity, expectedRevision:)` only checks `expectedRevision == identity.revision` (a tautology), then `removeCiphertext` stats the remote CURRENT revision and tombstones IT without comparing to `identity.revision`. Device A queues delete of R1; Mac holds newer R2 → delete sent with expectedRevision=R2 → newer data destroyed. (iCloud backend correctly throws `staleVersion` here.)
  **Fix:** After fetching remote current, throw `VaultBackendError.staleVersion` unless `current.revision == identity.revision`.

- **Severity: medium | correctness** — `VaultMacClient.swift:314, 379-382, 432, 490-498`: `revisions` cache never invalidated/refreshed on `.conflict` although the server includes its current revision in every conflict response. Stale cache → repeat conflicts → feeds idempotency poisoning.
  **Fix:** On any `.conflict`, set `revisions[id] = response.revision` (or drop entry).

- **Severity: medium | correctness** — `VaultMacClient.swift:571, 589-591` vs `537-545`: Stage-4 `put` overloads build `logicalTime` from raw wall clock, bypassing monotonic `nextLogicalTime(after:)` used by legacy path and `removeCiphertext`. Two commits within 1 ms (or wall clock behind remote logicalTime) → server compare ≤ 0 → `.conflict` → also poisons idempotency key.
  **Fix:** Use `nextLogicalTime(after:)` with the full fetched `VaultRevision` in both `put` overloads.

- **Severity: medium | correctness** — `VaultMacClient.swift:565-584` vs `586-607`: inconsistent lossy error mapping — Data `put` throws raw `VaultMacProtocolError` (callers expect `VaultBackendError`); file `put` maps EVERYTHING incl. `conflictingRevision` and `CancellationError` to transient `.io` → scheduler retries doomed uploads forever; cancellation swallowed.
  **Fix:** Map `conflictingRevision → .conflict`/`.staleVersion`, `expired/unavailable → .unavailable` in both; rethrow `CancellationError`.

- **Severity: medium | performance** — `VaultMacClient.swift:363-384, 420-435` + `VaultMacPendingUpload` (232-249): resume re-transfers every chunk's full body — pending record stores no progress and the client ignores the `receivedChunks` list in `.partial` responses. 100 GiB upload interrupted at 99% re-sends ~25,600 × 4 MiB.
  **Fix:** Persist an acked-chunk high-water mark (or receivedChunks set) in `VaultMacPendingUpload` after each response; skip acked chunks on resume.

- **Severity: medium | performance/edge-case** — `VaultMacClient.swift:445-473` (`ciphertext(for:)`): non-streaming download materializes the whole object in memory, bounded only by the 100 GiB protocol max → jetsam.
  **Fix:** Cap this path at artifact scale (e.g. 16 MiB); require `payloadFile` above it.

- **Severity: medium | simplicity** — `VaultMacClient.swift:328-334` (public `putCiphertext(_:for:)`), `707-737`: dead AND broken — forwards `kind: nil, generation: nil` which `validated()` rejects for every `.putChunk`, after saving a pending record (arming the stale-pending deadlock). No callers. Three private file/hash helpers (`readFile` ×2, `SHA256.hashFile`) also dead.
  **Fix:** Delete the raw entry point and the dead helpers.

- **Severity: low | correctness** — `VaultMacClient.swift:490-498` with `476`: stat answering `.invalid`/`.failed` makes `remoteRevision` return nil → `removeCiphertext` silent success / `putCiphertext` proceeds with nil expectedRevision.
  **Fix:** Throw for statuses other than `.accepted`/`.notFound`.

- **Severity: low | edge-case** — `VaultMacClient.swift:205-211`: actor reentrancy lets concurrent `request` calls interleave `channel.receive()` reads, corrupting framing. No current caller does this; public API permits it.
  **Fix:** Serialize with an in-flight queue, or document single-outstanding-request and assert.

- **Severity: low | edge-case** — `VaultMacClient.swift:216-230`: flat per-request timeout (60s default) for a 4 MiB chunk = hard ~70 KB/s minimum link speed; a slower DERP path fails every attempt at chunk 0.
  **Fix:** Scale timeout to chunk size or reduce chunk size on repeated timeout.

## VaultMacProtocol.swift

- **Severity: low | edge-case** — `VaultMacProtocol.swift:540-545` (`validHostname`): `isLetter`/`isNumber` are Unicode-aware — non-ASCII/confusable hostnames pass the "strict" shape. Fix: restrict labels to ASCII.

Otherwise clean: framing bounds, nonce/AAD binding, replay guard ordering, constant-time compares, epoch/expiry validation, chunk-plan overflow arithmetic, IPv6/CGNAT/port parsing all correct and match the server.

## VaultICloudBackend.swift

- **Severity: high | correctness (storage cost)** — `VaultICloudBackend.swift:335-341` vs `410-516` and `549-568`: superseded revision payloads never pruned — each replacement writes a new `<objectID>/<revision>/<generation>.vault` and repoints `current.json`; nothing deletes the previous revision's file; `compareAndRemove` removes only the current identity's file. Every content update permanently duplicates full ciphertext in the user's iCloud quota; deleting the object leaves all prior revisions behind.
  **Fix:** Inside the same coordinated write that commits `current.json`, delete sibling revision directories under the objectID; `compareAndRemove` removes the whole objectID directory.

- **Severity: medium | correctness** — `VaultICloudBackend.swift:211-213, 240-242`: `payload(for:)`/`payloadFile(for:)` throw `.staleVersion` (transient → retried) when `currentIdentity` is nil, instead of returning nil → `.notFound` (permanent). Diverges from the Mac backend and this backend's own `state(for:)`.
  **Fix:** Return nil when `currentIdentity(at:)` is nil; keep `.staleVersion` for present-but-different identity.

- **Severity: medium | correctness (conflict handling)** — `VaultICloudBackend.swift:176-179, 217, 246, 322`: conflict state only read for the payload file; `current.json` — the CAS arbiter — is never checked for unresolved NSFileVersion conflicts and nothing resolves them. Two devices CAS-write in one window → both report `.current`, losing payload silently orphaned, `.conflicted` never raised.
  **Fix:** Include `state(for: versionPath)` in the conflict guards of `put`/`payload*`/`state`; surface `.conflicted` on version-file conflicts.

- **Severity: low | simplicity/performance** — `VaultICloudBackend.swift:271-273` and `LunaVaultBackend.swift:136-142`: `payloadFile`'s retrying closure doesn't map coordinator errors through `Self.map` (raw Cocoa errors escape); `.conflict`/`.staleVersion` marked `isTransient` so deterministic CAS failures retry 3× with sleeps.
  **Fix:** Wrap readToFile in `do/catch { throw Self.map(error) }`; reconsider staleVersion/conflict transience.

- **Severity: low | edge-case** — `VaultICloudBackend.swift:464-471` (`compareAndWriteFile(from sourceURL:)`): if `moveItem` or version write throws, the `.staging-<UUID>` file leaks into the ubiquitous container (sibling variant at 499-514 cleans up).
  **Fix:** Same do/catch removeItem(staging) cleanup.

## Small files

- **Severity: low | performance** — `VaultDeviceBackend.swift:33-40`: `content(for:range:)` reads the entire object and slices while advertising `supportsRangeReads: true`. Fix: ranged read on `VaultObjectStoring` or stop advertising.

Clean: temp sweep, retry helper defaults, `VaultTailnetStatusSummary`, transport protocols; no encode/decode mismatch vs server; chunk arithmetic verified; no session-lifecycle leak.

## Overall
Crypto/wire layers strong and byte-for-byte matched to the server. Weaknesses concentrate in the retry/revision state machines: false-success resumed uploads (scheduler then deletes the only staged copy), stale pending records and memoized conflicts permanently wedging objects, `remove` tombstoning newer revisions, and an iCloud backend that leaks every superseded revision into the user's quota. All fixes local. The false-success upload and the iCloud revision leak should land before real data rides these transports.
# Cluster: LunaVaultTailscale + vendored TailscaleKit

## Findings

- **Severity: critical** | **Category: correctness**
  **Location**: `LunaVaultTailscale/Sources/LunaVaultTailscale/VaultTailnetNodeRunner.swift:224-257` with `LunaVaultTailscale/Sources/TailscaleKit/TailscaleNode.swift:116-147`
  **Defect**: The 45s timeout's "close and discard" can never actually issue `tailscale_close` while `tailscale_up` is blocked — `up()` and `close()` are both isolated to the same `TailscaleNode` actor, and `up()` holds the actor (no suspension point) for the whole blocking C call, so `discardNode`'s `await staleNode.close()` queues behind the very call it should interrupt.
  **Failure scenario**: iPhone offline / control plane unreachable → `bringUp()` times out, resumes caller with `.timedOut`, sets `node = nil` — but the Go node keeps running and the detached `up()` task stays blocked on a cooperative-pool thread indefinitely. Retry creates a SECOND `TailscaleNode` on the SAME state directory while the first Go node is alive (state contention, duplicate node against control). Each retry pins one more cooperative-pool thread (~6 on iPhone) — a retrying sync engine starves the Swift Concurrency pool and hangs the app. `shutDown()` during pending `up()` deadlocks the same way.
  **Fix**: Interrupt off-actor: `tailscale_close` is the documented cross-thread interrupt — call it on the raw handle from the timeout path via `runBlocking` (a `nonisolated` `interrupt()` on `TailscaleNode` calling `tailscale_close(tailscale)` directly; vendored — keep Luna vendoring change markers; handle is immutable `let`). Also run `tailscale_up` through `runBlocking` on the runner's concurrent queue instead of actor isolation.

- **Severity: high** | **Category: correctness**
  **Location**: `LunaVaultTailscale/Sources/LunaVaultTailscale/VaultTailscaleFrameChannel.swift:115-129` (and init at 22-25)
  **Defect**: `Darwin.write` on a socket whose peer closed raises SIGPIPE; nothing sets `SO_NOSIGPIPE` or ignores SIGPIPE (repo-wide grep: zero hits; Go c-archive runtime doesn't change disposition; NWConnection handles internally, raw fds don't).
  **Failure scenario**: Companion quits or tsnet stream resets mid-sync → `waitUntilReady` sees `POLLOUT|POLLHUP` (treated ready — only POLLNVAL checked) → `write()` → SIGPIPE → Vault app terminated instead of `send()` throwing `.unavailable`. Same crash in the companion when the iPhone drops mid-response.
  **Fix**: In `VaultTailscaleFrameChannel.init`, `setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, ...)`. EPIPE then surfaces via the existing errno path.

- **Severity: medium** | **Category: correctness**
  **Location**: `VaultTailnetNodeRunner.swift:29-32, 58-78, 89-100, 188-190`
  **Defect**: Blocking C calls run under actor isolation on the cooperative pool, contradicting the runner's own doc comment — only `dial` uses `runBlocking`; `tailscale_start` (in `TailscaleNode.init`), `tailscale_up`, `tailscale_close`, `tailscale_status_json` execute on default actor executors.
  **Failure scenario**: During normal multi-second bring-up, `statusSummary()` (Settings → Mac UI) and any `dialTailnet` await behind the blocked `up()` — status screen shows nothing for up to 45s, one cooperative thread blocked throughout.
  **Fix**: Route `up`/`close`/`statusJSON`/node construction through `runBlocking` on the runner's queue; `TailscaleNode` stays a thin handle owner.

- **Severity: medium** | **Category: edge-case**
  **Location**: `VaultTailnetNodeRunner.swift:52-56, 175-186`
  **Defect**: `hasPersistedState` means "state dir non-empty", not "has a stored login" — tsnet writes machine-key state once the node ever started, including an abandoned login; `statusSummary()` itself starts the node.
  **Failure scenario**: User opens Settings → Mac once, cancels web auth → state dir non-empty forever → every later `.tailscale` dial boots the full Go node in-process (tens of MB, network chatter) just to read `needsLogin` and throw. Fail-closed behavior holds, but the "without starting a node" test guarantee only holds for a virgin install.
  **Fix**: Latch a Luna-owned "login completed" marker (set on first `.running`, cleared on `logout`); gate dialing on that; keep the directory check as cheap first filter.

- **Severity: low** | **Category: correctness**
  **Location**: `VaultTailnetNodeRunner.swift:119` vs `:160`
  **Defect**: `continuation.onTermination` assigned twice; second assignment (cancel IPN-bus processor) replaces the first (cancel login task) — after `watchIPNBus` returns, abandoning the stream no longer cancels the login task.
  **Failure scenario**: UI dismisses login sheet mid-flow → processor cancelled but `startLoginInteractive()` and the `.finished`→`bringUp()` task keep running unobserved. Mild.
  **Fix**: One termination handler doing both cancels, installed once.

- **Severity: low** | **Category: simplicity**
  **Location**: `VaultTailnetNodeRunner.swift:41-48`
  **Defect**: `goLogPump.start()` runs unconditionally; with an injected custom `logger` the pump's pipe is never handed to the node — started reader handler + two dead fds; no call site passes non-nil `logger`.
  **Fix**: Start the pump only when constructing the default `VaultTailnetLogSink`, or drop the `logger` parameter.

- **Severity: low** | **Category: edge-case**
  **Location**: `VaultTailnetListener.swift:59-69` with `LunaVaultMacCompanion/main.swift:162-169`
  **Defect**: Any single `tailscale_accept` failure finishes the connections stream; companion reacts with `fail(...)` → `exit(2)`, tearing down the healthy `--bind-host` LAN listener too.
  **Fix**: Catch the stream error and recreate `tailnetListener` with backoff instead of exiting, keeping the LAN transport alive (unless crash-and-restart under launchd is the intended model).

## Clean dimensions
Frame parity/length validation correct and pinned by tests; fd ownership clean (close exactly once in deinit, shutdown as wake, EINTR/EAGAIN handled, bounded buffers); performance fine (poll ticks cheap, header-prepend copy matches NW channel); vendored Luna changes minimal and correct; `down()`-calls-`tailscale_up` quirk documented in VENDORED.md and unused.

## Overall
Adapters small and well-wired; the two serious problems are concurrency-vs-blocking-C seams: the timeout that cannot deliver its documented close (leaked Go node, thread starvation, duplicate node on one state dir), and unhandled SIGPIPE turning routine disconnects into app termination. Both fixes are localized; neither touches wire format or upstream logic.
# Cluster: LunaVaultSync + LunaVaultSetup

## Findings

### Correctness

- **Severity: high** | **Category: correctness**
  **Location:** `LunaLibraries/Sources/LunaVaultSetup/VaultImportCoordinator.swift:540-551` (and 632-643 with 583-587)
  **Defect:** `repairInterruptedImports` has no terminal path for a journal whose staged payload cannot be finalized — retries the same journal forever and retains staged plaintext unboundedly.
  **Failure scenario:** (a) Remote configured, death between `stage` (457) and durable ciphertext (463): repair finds journal+payload, remote != nil but no `ciphertext-<token>.lvf`, hits guard at 543-546 and `continue`s — no reseal-from-payload path, token already in `livePayloadTokens` so the sweep keeps it. Skipped identically every pass. (b) Death mid-`stage`: partial payload fails finalize's size/digest checks with `.interrupted` every pass; `catch { continue }` at 583 retains it. Plaintext sits in staging forever, import never completes or reports.
  **Fix:** When remote configured and ciphertext absent, re-seal from the retained payload + journal. For a payload failing finalize's integrity checks, delete the journal/payload pair — it can never succeed.

- **Severity: high** | **Category: correctness**
  **Location:** `VaultImportCoordinator.swift:552-578 and 687-698`
  **Defect:** Repair of a crash between `sealRemotePayload` (463) and `stageRemoteUpload` (468) enqueues an upload job whose payload was never copied into the sync uploads directory, then deletes the only ciphertext copy.
  **Failure scenario:** Jetsam in that window (realistic for large files). Repair resolves generation from `ciphertext-<token>.lvf`, finalize verifies and enqueues the upload job — nothing re-runs `stageRemoteUpload`, repair removes `remoteURL` (577). Sync worker's `uploadPayloadFile` returns nil → `VaultSyncError.sync(.missingPayload)` — non-transient (`LunaVaultSync.swift:53-57`) → job permanently `.failed`. Object exists locally, silently never reaches the Mac/iCloud. No test covers `repairInterruptedImports` at all.
  **Fix:** Have finalize (or repair before calling it) stage the verified ciphertext via `stageRemoteUpload` when the expected `remotePayloadURL` is absent — idempotent (atomic install overwrites).

- **Severity: medium** | **Category: correctness**
  **Location:** `VaultImportCoordinator.swift:719-722`
  **Defect:** On journal replay, `storedUploadID` returns the id of a job that doesn't exist in the store (`jobs.idempotency_key` UNIQUE + `INSERT OR IGNORE` discards the fresh `VaultJob` id; `repository.job(id)` for it returns nil, `?? uploadID` hands back the nonexistent id).
  **Fix:** Look up by idempotency key, mirroring the index-job line: `try repository.job(idempotencyKey: upload.idempotencyKey)?.id ?? uploadID`.

- **Severity: medium** | **Category: correctness**
  **Location:** `VaultImportCoordinator.swift:733-742 with 700-708`
  **Defect:** Re-importing content whose object exists but whose local content was evicted throws `missingObject` and leaves a journal repair retries forever.
  **Failure scenario:** Eviction is a designed state. Re-import: content-addressed `objectID` collides, `existingDuplicateResult` bails (capability nil, 739), `insertAtomically` returns false for revision mismatch (return discarded), check at 707 throws `.missingObject`. Journal+payload retained; repair fails identically forever.
  **Fix:** In `existingDuplicateResult`, when object exists with matching digest but capability absent, treat as duplicate — reinstall local content from the staged handle via the same-revision `insertAtomically` repair path.

- **Severity: low** | **Category: correctness**
  **Location:** `LunaLibraries/Sources/LunaVaultSync/LunaVaultSync.swift:111-124` (also 138-142)
  **Defect:** Data-path `upload` stages the payload then leaks it when backend already `.current` (117 returns without `removeUploadPayload`) or job already terminal (115); file-path version and `runReadyJobs` both remove it.
  **Fix:** Call `removeUploadPayload` in the `.current` short-circuit; stage only after `prepareAndClaim` shows the job isn't terminal.

- **Severity: low** | **Category: correctness**
  **Location:** `VaultImportCoordinator.swift:785-806`
  **Defect:** Duplicate path's "completed upload is the durable reconciliation record" short-circuit inspects only the FIRST (oldest) upload job for the revision, not a succeeded one — a failed gen-A job masks a succeeded gen-B, so every subsequent duplicate import reseals a full new ciphertext + enqueues another upload job.
  **Fix:** Search for a succeeded upload job at the current revision first, then fall back to a usable staged job.

### Edge cases

- **Severity: medium** | **Category: edge-case**
  **Location:** `VaultFileSyncPayloadStore.swift` init (17-39), `installDownloadedPayloadFile` (111-119); `VaultImportCoordinator.swift:607-613 and 961`
  **Defect:** Crash-orphaned temp files never swept: payload store init cleans nothing, so `.staging-*` and `.plaintext-*` (decrypted plaintext temp!) persist forever; import repair sweep looks for `.import-upload-*` in `stagingDirectory` (610) while those files are created in the payload uploads directory (961) — that branch never matches; `.journal-staging-*` (1090) matches no sweep prefix.
  **Failure scenario:** Death during `installDownloadedPayloadFile` leaves a decrypted plaintext copy of the object in downloads permanently — violates "no plaintext retained". Death during `stageRemoteUpload` leaves partial ciphertext in `uploads/` forever.
  **Fix:** Startup sweep of `.staging-*`/`.plaintext-*` in both areas in `VaultFileSyncPayloadStore.init`; match `.import-upload-*` against the payload directory; add `.journal-staging-` to staging-dir prefixes.

- **Severity: low** | **Category: edge-case**
  **Location:** `VaultImportCoordinator.swift:483-491`
  **Defect:** After finalize fully succeeds, a failure removing staging files throws `.cleanupFailed`, discarding the `VaultImportResult` — UI reports failure though import is durably complete (recovery does converge via journal replay).
  **Fix:** Return the result; surface cleanup failure via log/diagnostics or defer to next repair pass.

Clean: zero-byte imports; `createFirstRun` idempotent; `makeJobReady`/`claimJob` lease discipline; repair bounded by `maximumRepairEntries`.

### Performance

- **Severity: medium** | **Category: performance**
  **Location:** `VaultFileSyncPayloadStore.swift:82, 108-109, 155-170`
  **Defect:** The `downloads/` area is write-only — every downloaded object's full ciphertext is copied there and nothing reads it back (only `removeAllPayloads` for a delete job removes it). Every synced-down object doubles its disk footprint for the vault's life.
  **Fix:** Stop persisting the downloads copy, or delete it after `writeContent`/`putEncryptedArtifact` succeeds.

- **Severity: medium** | **Category: performance**
  **Location:** `VaultFileSyncPayloadStore.swift:105, 125, 132`; `VaultImportCoordinator.swift:904/940 and 660`
  **Defect:** `verified()` is a full AES-GCM open of every frame, run redundantly: `installDownloadedPayloadFile` authenticates the whole file 3× (verified 105, decrypt 125, verified 132) plus whole-file ciphertext copy at 109; `importFile` verifies at seal (904) then again in finalize (660), plus two SHA-256 passes. Minutes of extra CPU/IO on multi-GB objects inside a BGProcessingTask budget.
  **Fix:** Reuse the first `VaultVerifiedCiphertextFile`; let `decrypt` serve as the auth pass for download-install; skip finalize's re-verification when finalize runs in the same invocation that just sealed.

- **Severity: low** | **Category: performance**
  **Location:** `VaultImportCoordinator.swift:404 (whole importFile), 770`; `VaultFileSyncPayloadStore.swift` (all methods)
  **Defect:** `importFile` holds one `NSLock` across the entire multi-pass import (up to 100 GB); payload store's async methods do blocking file/crypto work under `NSLock` on cooperative-pool threads; `existingDuplicateResult` loads every job in the table (one query per row) to find two.
  **Fix:** Targeted repository query for jobs by object/revision; longer term move payload store's blocking work onto a dedicated dispatch queue.

### Simplicity

- **Severity: low** — `VaultImportCoordinator.swift:1172, 1196-1208`: `VaultIndexWorker.lock` never used; the `for _ in 0..<64` claim loop executes at most one iteration (both branches break); `job.kind == .index` guard at 1208 dead. Delete lock, single `claimNextJob` call, fix comment.
- **Severity: low** — `LunaVaultSetup.swift:126`: `current = configuration.storagePolicy.map { _ in .firstRun } ?? .firstRun` — both arms identical. Replace with `current = .firstRun`.
- **Severity: low** — `VaultFileSyncPayloadStore.swift:142-147`: artifact branch reads entire decrypted plaintext into memory and discards it; the decrypt-to-temporary at 125 is unnecessary for artifact kinds (install uses `collectFrames` from the encrypted envelope). Skip the temp decrypt for `.metadata/.manifest/.index`.
- **Severity: low** — `VaultImportCoordinator.swift:465-467, 830-832 vs 991-994`: payload-directory fallback derived inline twice though `remotePayloadDirectory(_:)` exists; no-op `do/catch{throw}` at 492-496.

No confirmed async/actor races or retain cycles.

## Overall
Steady-state design strong (journal-anchored import, atomic repository boundary, idempotency-keyed jobs, leases). Weakness concentrated in recovery seams no test exercises: two crash windows repair can never finish (stranding plaintext, looping forever) and one it "finishes" by minting a permanently unfulfillable upload job — quietly breaking durable sync. Prioritize the two highs plus a `repairInterruptedImports` test suite.
# Cluster: LunaVaultSearch + LunaVaultIndexExtraction + LunaVaultEmbeddings

## Correctness

- **Severity: high** — `VaultSearchIndex.swift:596-633` (`migrate()`): schema migration runs as auto-committed statements with no wrapping transaction; `user_version` set only by the last statement. Crash mid-migration leaves tables created with stale `user_version`; every later open re-runs the batch, `CREATE TABLE` fails "table already exists", init throws — index permanently unopenable until hand-deleted. Fix: wrap each migration step in the existing `transaction {}` helper (SQLite DDL is transactional) or use `CREATE TABLE IF NOT EXISTS`.

- **Severity: high** — `VaultSearchIndex.swift:567-589` (`restoreEncryptedExport`): restore replaces only the main DB file, leaving pre-existing `-wal`/`-shm` siblings. Next open runs WAL recovery and replays the OLD database's frames into the restored snapshot — silent corruption; bites precisely in the crash-recovery case. Fix: remove `-wal`/`-shm` (without following symlinks) after the replace.

- **Severity: medium** — `VaultSearchIndex.swift:234, 808-818` (`upsertLocked` → `removeProjectionsLocked`): every upsert deletes the object's embeddings for ALL model versions, reinserting at most one. Latent multi-model bug (schema/API is multi-model: `modelVersions()`, `rebuild(modelVersion:)`): re-indexing under model B destroys the model-A vector. Fix: scope the delete to the incoming `model_version`, or enforce a single-model invariant and drop the multi-model surface.

- **Severity: low** — `VaultSearchIndex.swift:433-455` (`evolveAutomaticGroups`): when every centroid is frozen, `ranked` is empty and the else branch creates a new group without consulting `maximumAutomaticGroups` — unbounded group growth despite the 512 cap. Fix: check the cap before the else-branch insert.

- **Severity: low** — `VaultSearchIndex.swift:509, 938, 961-967`: `groups.member_count` maintained only by `createGroup`/`persistCentroid`; `addManualMembership` → `addGroupMember` never updates it, so evolve's incremental-average weight over/under-weights permanently after a manual add to an automatic group (UI allows it, `VaultHomeViewController.swift:689`). Fix: bump member_count (and fold vector into centroid) or forbid manual adds to automatic groups.

- **Severity: low** — `VaultSearchIndex.swift:202` vs `1061-1064` with `VaultSearchModels.swift:66-70`: single-document path compares revision stamps with Swift `String <` (Unicode-canonical) while bulk path compares in SQLite (BINARY memcmp) — divergent conflict resolution for non-ASCII deviceIDs. Fix: normalize/restrict deviceID to ASCII at the `VaultIndexRevision` boundary, or compare on UTF-8 byte order.

- **Severity: low** — `LunaVaultIndexExtraction.swift:94-104`: `try jobCoordinator?.transitionExtractionJob(...)` inside the catch can throw, replacing the original extraction error; job left `.running` until lease expiry. Fix: `try?` the transition so the original error propagates.

- **Severity: low** — `VaultSearchIndex.swift:38-41, 578-587`: (a) failed `sqlite3_open_v2` still returns a handle never closed; (b) in `restoreEncryptedExport`, if `moveItem` in the `fileNoSuchFile` catch throws, plaintext staging file `.vault-index-restore-<UUID>` is left in the vault directory. Fix: close on failed open; `try? removeItem(staging)` around the fallback.

## Edge cases

- **Severity: medium** — `VaultArchivePreflight.swift:27-36` with `LunaModels/ZipArchiveReader.swift:150-162`: entries declaring `uncompressed = 0` pass every preflight limit; `inflate` then runs the doubling search up to 64 MiB PER entry — a hostile epub/docx materializes far more than the 128 MB archive cap. Fix: reject (or force metadata-only) any entry with `compressed > 0 && uncompressed == 0`; optionally bound accumulated block text in `textChunks`.

- **Severity: low** — `LunaVaultIndexExtraction.swift:314-324` (`makeSpeechChunks`): `guard !text.isEmpty else { break }` treats an empty source segment as byte-budget exhaustion — later segments silently dropped. Fix: `continue` on empty segment text; `break` only on `bytes >= policy.maximumTextBytes`.

- **Severity: low** — `VaultArchivePreflight.swift:57-66` (`Data.leUInt16/leUInt32`): zero-based subscripting on `Data` breaks for slices (non-zero startIndex); latent. Fix: index relative to `startIndex` or copy to `[UInt8]`.

- **Severity: low** — `LunaVaultIndexExtraction.swift:230-235` (`textChunks`, `.richText`): RTF larger than 16 MB is truncated BEFORE parsing → invalid RTF → whole extraction fails instead of degrading. Fix: parse full data (already ≤64 MB) and bound the output string, or fall back to metadata-only on parse failure.

Ranking math clean (cosine guards, bm25 clamps, no div-zero).

## Performance

- **Severity: high** — `VaultSearchIndex.swift:601, 815, 1068`: `vault_fts` declares `id UNINDEXED` and FTS5 executes non-MATCH constraints as a full table scan — every upsert/delete/bulk-import row runs `DELETE FROM vault_fts WHERE id=?` → 100k-doc vault scans all rows per single-file re-index; bulk import O(n²). Fix: external-content FTS5 table over `documents`, or store the FTS rowid and delete by `rowid=?`.

- **Severity: medium** — `VaultSearchIndex.swift:635-730, 1179` (`searchLocked`/`HitSeed`): every candidate seed retains the complete decoded document (bodyText/ocrText/transcriptText, up to 16 MB each) × up to 500 candidates → hundreds of MB to GB per query. Fix: select only id/filename/dates/score for ranking; fetch winning `limit` docs' text (or FTS5 `snippet()`) after `sorted.prefix(limit)`.

- **Severity: medium** — `VaultSearchIndex.swift:741-758` (`vectorCandidates.consider`): per streamed row an O(limit) `firstIndex` dedupe + full `sort` once the buffer is full → tens of millions of comparisons per query at 100k embeddings. Fix: `[VaultObjectID: Int]` dedupe index + min-heap or sort-when-2×-overfull.

- **Severity: medium** — `VaultHomeViewController.swift:519-545` (`renderGroups`): synchronous main-thread index work — `groups()` N+1 member subquery per group, `queryGroups(limit:100)` runs a full hybrid search per live query group through the serial queue; blocks main for a bulk import's whole 4096-doc transaction. Fix: move index reads off main, render on completion; persist live-group member counts.

- **Severity: low** — missing indexes: `documents(accessed_at)` (used by `recent` + filename-LIKE ORDER BY) and `group_members(object_id)` (per-candidate `isAutomaticMember`, per-tombstone delete). Add both in a v3 migration.

- **Severity: low** — `VaultSearchIndex.swift:1026-1027`: `protectDatabaseFiles()` after every operation incl. reads; its throw can fail a successful query. Apply at init, after checkpoint/restore, after write transactions.

## Simplicity

- **Severity: medium** — `LunaLibraries/Package.swift:278-280`, `LunaLibraries/Tests/LunaVaultSearchTests/`: a package `.testTarget` exists despite the repo rule (package declares NO test targets; the one suite is LunaTests). Its 7 tests never execute, partially duplicate `LunaTests/VaultSearchTests.swift`. Fix: fold non-duplicated assertions into LunaTests and delete the target + directory.

- **Severity: low** — dead public surface, zero references: `VaultVectorIndex` + `BruteForceVaultVectorIndex` (also stores an init closure, violating the wiring standard), `VaultSearching`, the entire `VaultSearchPerformanceProbe`, `PreparedStatement.fetchRevision`, `VaultExtractionError.cancelled`. `VaultTextExtracting` implemented only by a test fake. Fix: delete.

- **Severity: low** — `VaultSearchIndex.swift:17-21` (`walCheckpointOverride`): public stored `var` closure test seam (live — used by one test) where the standard requires a protocol witness. Fix: injected `VaultWALCheckpointing` witness at init.

## Overall
Well above average for a v1 foundation; the two highs are durability edges (non-transactional migration, WAL-blind restore) that bite exactly after a crash. Dominant scaling problem: FTS5 delete keyed on an UNINDEXED column in the hottest write path + full-text retention per search candidate. Also a forbidden package test target to retire.
# Cluster: LunaVaultUI + LunaVault app target + LunaVaultShare

## Correctness

- **Severity: critical** | **Category: correctness**
  **Location:** `LunaVault/KindWiring+Vault.swift:172` and `:263-264`, with `LunaVaultUI/VaultSyncRuntimeController.swift:27-35` and `LunaVaultUI/VaultBackgroundTaskScheduler.swift:115`
  **Defect:** `BGTaskScheduler.register(forTaskWithIdentifier:)` is called from `VaultSyncRuntimeController.init` and `installBackgroundRuntime`, both re-run on every runtime rebuild; BGTaskScheduler raises `NSInternalInconsistencyException` for duplicate registration AND for registration after launch ends; the `try?` at KindWiring:264 cannot catch an ObjC exception.
  **Failure scenario:** (a) Launch with iCloud/Mac policy, then any Settings change firing `reconfigureRuntime` → second registration → crash. (b) First run: `install()` returns nil services, user taps "Create Vault" → `completeSetup` → registration after launch finished → crash on the setup button.
  **Fix:** Register all four identifiers exactly once in `VaultAppDelegate.didFinishLaunching`, with launch handlers routing to the CURRENT runtime through a stable seam (a `VaultWiring` lookup); runtime controller and scheduler only submit/cancel, never register.

- **Severity: high** | **Category: correctness**
  **Location:** `LunaVaultShare/VaultShareViewController.swift:6-23` (+ Info.plist activation rule)
  **Defect:** Share extension's principal VC never calls `extensionContext.completeRequest(...)`/`cancelRequest(...)` and offers no button — the sheet hangs forever, host app's share flow stuck until force-dismissed.
  **Fix:** Add a Done/Cancel action and call `extensionContext?.completeRequest(returningItems: nil)` (or auto-complete after rendering the confirmation).

- **Severity: high** | **Category: correctness / performance**
  **Location:** `KindWiring+Vault.swift:399-412` (`VaultDocumentImportPresenter.documentPicker(_:didPickDocumentsAt:)`), work in `VaultImportCoordinator.swift:403-484`
  **Defect:** `coordinator.importFile` (full-file SHA digest + copy to staging + AES-seal, under NSLock, bounded only by 100 GB `maximumBytes`) is called synchronously on the main thread in the picker delegate.
  **Failure scenario:** Multi-GB video from Files → main thread blocks for the entire hash+copy+encrypt → watchdog kills the app mid-import.
  **Fix:** Run `importFile` on a background task (coordinator is `@unchecked Sendable`), show progress/disable UI, hop back to main for `refresh()`/errors.

- **Severity: medium** | **Category: correctness**
  **Location:** `KindWiring+Vault.swift:338-370` (`requestICloudEviction`/`remoteIdentity(for:)`) vs UI text at `VaultSettingsViewControllers.swift:252-260`
  **Defect:** "Request local eviction" resolves a SINGLE identity — the object of the most recently updated sync job — and evicts it once, while the UI reports the whole local working copy evicted.
  **Fix:** Enumerate evictable objects (e.g. `repository.objects()`), evict per object, report aggregate; `.unavailable` only when the backend truly can't evict.

- **Severity: medium** | **Category: correctness (leak / hung task)**
  **Location:** `VaultSettingsViewControllers.swift:800-820` (`VaultMacUIIdentityConfirmer`) and `KindWiring+Vault.swift:552-581` (`VaultMacIdentityConfirmationPresenter`)
  **Defect:** Both confirmers resume `withCheckedContinuation` only from an alert action; if the alert never fires (VC popped while alert up; `present` silently fails because root VC already presenting), continuation leaks and the awaiting task hangs forever (pairing Task holds self strongly; Mac backend dial hangs).
  **Fix:** Present through the topmost presented VC and resume nil when presentation impossible; also resume nil on presenting VC disappearance (weak alert reference + token object).

- **Severity: medium** | **Category: correctness**
  **Location:** `KindWiring+Vault.swift:57-62` (`applicationDidEnterBackground`) with `VaultBackgroundTaskScheduler.swift:130-161`
  **Defect:** `schedule(kind:)` both submits a BGProcessingTask request AND immediately starts the operation in-process at backgrounding, no `beginBackgroundTask` protection; the frozen in-process task blocks the real system run (`run(kind:)` sees `active[kind] != nil` → returns `Task { false }` → handler `setTaskCompleted(success: false)` without work).
  **Failure scenario:** App backgrounds with pending index work → task starts, process suspends mid-work → hours later iOS launches the BGTask → handler completes immediately false → background maintenance never runs in background.
  **Fix:** At backgrounding only submit (as `VaultSyncRuntimeController.scheduleIfNeeded` already does); if opportunistic work is wanted, wrap in begin/endBackgroundTask and make the BGTask handler adopt or restart work.

- **Severity: low** | **Category: correctness (leak)**
  **Location:** `VaultHomeViewController.swift:696-709` (`promptForGroup`)
  **Defect:** "Create" `UIAlertAction` handler captures `alert` strongly (alert retains actions → permanent cycle); sibling `promptForQueryGroup` at 648 correctly uses `[weak alert]`. Every Manual-group prompt leaks one UIAlertController.
  **Fix:** `[weak alert]` in the Create handler.

## Edge cases

- **Severity: medium** — `VaultSettingsViewControllers.swift:577-613`: after `.browseToURL` presents `SFSafariViewController`, nothing observes user dismissal (no delegate) → Connect button stuck disabled, status stuck; only recovery is leaving the screen. Fix: set delegate; on `safariViewControllerDidFinish` cancel `tailnetLoginTask`, `refreshTailnetStatus()`, re-enable Connect.
- **Severity: low** — `VaultSettingsViewControllers.swift:694-702` (`exportEnrollment`): one-use enrollment secret written unencrypted to tmp and never deleted after the picker completes/cancels. Fix: UIDocumentPickerDelegate removes temp file in both paths; consider `.completeFileProtection`.
- **Severity: low** — `VaultHomeViewController.swift:446-463, 483-494`: groups-load error status silently clobbered when a pending search completes (`hideContentStatus()` unconditional). Fix: scope status per section or clear only own status.

## Performance

- **Severity: medium** — `KindWiring+Vault.swift:99-110` (`clearCache`, `rebuildIndex` closures) with buttons at `VaultSettingsViewControllers.swift:303-315, 345-357`: closure literals formed inside `@MainActor` `VaultWiring` inherit main-actor isolation — `repository.evictExpired()` and full `index.rebuild()` execute ON the main actor despite the spinner text. Fix: `Task.detached` inside the closure or route through a non-isolated worker.
- **Severity: medium** — `VaultHomeViewController.swift:372-464, 498-553` with `KindWiring+Vault.swift:143-155`: every `viewWillAppear`/`refresh()` does synchronous Keychain load + `facade.recent(limit:12)` + `index.groups()` + `index.queryGroups(limit:100)` (all sync SQLite on main), then tears down and rebuilds every subview even when unchanged. Fix: load off-main (pattern already used for search), diff/cache before rebuilding; cache the credential-derived identity.
- **Severity: low** — `VaultPreviewRouter.swift:351, 365, 379` and `KindWiring+Vault.swift:458`: `UIImage(contentsOfFile:)`, `PDFDocument(url:)`, `String(contentsOf:)` load whole files on main in `viewDidLoad` (unbounded text previews); `VaultObjectPreviewPresenter.open` runs `repository.jobs()` scan on main. Fix: async load with placeholder, cap text previews, move job scan into the background Task.

## Simplicity / standards

- **Severity: medium** — `VaultSettingsViewControllers.swift:19-56` (`VaultSettingsActions`), `VaultHomeViewController.swift:36-45, 70-96`, `KindWiring+Vault.swift:42-50`: cross-tier wiring is stored closure properties throughout (struct of ten optional closures, seven closure init params, six static closure vars) — violates the owner standard ("wiring is protocol contracts, never stored closures"); only `tailnet` follows the witness pattern. Fix: replace with `*Providing`/`*Handling` protocol witnesses installed by `VaultWiring`.
- **Severity: low** — dead code: (1) `VaultWiring`'s six static handler vars never assigned anywhere; (2) `VaultRuntimeServices.productionFromDefaults` (134-139) has no callers and reads a UserDefaults key nothing writes (future caller would silently get `.device` policy); (3) `VaultPreviewRouter.swift:133-140` `.available/.evicting` branch returns the identical plan as the line after it. Fix: delete all three.
- **Severity: low** — `KindWiring+Vault.swift:459-474, 506-542` vs `VaultPreviewRouter.swift:196-205, 251-311`: every preview holds TWO leases (presenter's `VaultPreviewSessionViewController` + router's `VaultPreviewLeaseHostingViewController`); only the inner renews. Fix: drop `VaultPreviewSessionViewController` and the presenter's explicit `beginPreview`; the hosting VC owns the lease.
- **Severity: low** — cluster uses zero `L10n.string` (hardcoded literals) and never touches the appearance system; `capsuleField.layer.borderColor = UIColor.separator.cgColor` resolved once with no trait-change re-resolution → stale border on appearance switch. Fix: re-resolve in `registerForTraitChanges`; note Vault's exemption from strings/appearance contract in vault-mac.md or migrate later.

## Clean
Cell reuse fine (5 static rows), search debounce/generation machinery correct, double-tap protection on all buttons, `VaultBackgroundTaskScheduler` start-gate/token state machine sound.

## Overall
UI layer itself careful; serious problems all in the composition seam: KindWiring+Vault rebuilds BGTask-registering objects on every reconfigure (two most ordinary user actions are deterministic crashes), heavy work lands on the main actor via main-actor-inherited closures, and the share extension is a sheet that can never close. Fix the BGTask lifecycle first — it gates on-device testability.
