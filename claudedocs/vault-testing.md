# Luna Vault testing contract

Stage 2 exercises the production crypto and isolated SQLite repository in
addition to the Stage 1 scaffold seams.

`VaultTestKit` is the only test-support product. It provides deterministic
clock/UUID/random-byte generators, a temporary-directory helper, in-memory
Keychain/object/backend fakes, fake text/OCR/transcription/embedding seams, a
URL protocol that fails every request before a socket opens, and a logger spy
that redacts supplied secrets. Production Vault targets must never depend on
this product.

The v1 storage matrix is deliberately limited to `device`, `icloud`, and
`mac`. `scripts/run_vault_tests.sh` defaults to deterministic device tests;
iCloud and Mac live tests require an explicit `--live-provider icloud` or
`--live-provider mac`. Mac live tests use the EMBEDDED tsnet node (the
`LunaVaultTailscale` package) for reachability and require a tailnet login on
both devices; they still exercise Vault's app-level pairing/authenticated
encrypted protocol. The deterministic suite never starts a node or contacts
the Tailscale control plane (`VaultTailscaleTransportTests` runs the frame
channel over a socketpair and asserts that an unauthenticated dial fails
closed). No test may contact a cloud provider or a Luna service implicitly.

Until live iCloud/Mac suites land, both live flags fail with `NOT IMPLEMENTED`
and exit 3. They never run the deterministic suite and report that as a live
success. The plain `--provider icloud|mac` form also refuses to proceed until
the caller supplies explicit live consent.

## Where the suites live

The Vault suites are the `LunaVaultTests` bundle in `LunaVaultTests/`. Its test
host is the `LunaVault` app, which links the Vault tier and the
`LunaVaultTailscale` package; the central Luna app links neither, so its own
bundle (`LunaTests`) can no longer carry a Vault test. The bundle holds Vault
suites and nothing else, so a plan that names the bundle runs the whole Vault
suite. `scripts/add_vault_tests_target.rb` owns that topology and keeps the
three plans pointing at the bundle.

The three plans hang off the `LunaVault` scheme's Test action:
`LunaVault.xctestplan` (default, deterministic), `LunaVaultPerformance
.xctestplan` (sets `LUNA_VAULT_PERFORMANCE=1` and raises the execution
allowance), and `LunaVaultStage5.xctestplan` (`VaultStage5Tests` alone).

Run the deterministic suite with:

```sh
scripts/run_vault_tests.sh --emulator
```

`--emulator` picks a booted iOS 26.2 iPhone simulator; name one with
`--simulator <UDID>` when several are booted. Use `--device <UDID>` for a
physical-device destination. `--unit` compiles the Foundation-only
`VaultTestKit` package target (the package also contains UIKit-only legacy
targets, so a plain `swift build` on macOS is not expected to pass).

The deterministic plan covers encryption ranges/tampering, strict key-ring
recovery, migrations/reopen/integrity, tombstones, cache expiry, job leases,
encrypted artifacts, legacy-store isolation, extraction, search, the storage
backends, the Mac protocol and store, and the Stage 5 setup and integration
shells.

`Fixtures/Vault/manifest.json` intentionally lives at the repository root: it
is test input, not an app resource. `VaultScaffoldTests` decodes it from the
source-file-relative repository path.

`scripts/select_changed_tests.py` serves `LunaTests` only. A changed Vault
input makes it print the `scripts/run_vault_tests.sh` instruction instead of
selecting a class, because `-only-testing` on the `Luna` scheme cannot reach
this bundle.

The no-egress URL protocol is opt-in. It can only intercept sessions created
with its configuration; it cannot police `URLSession.shared` or Network.framework
globally. For that reason the production backend boundary requires a
`VaultBackendNetworkSessionProviding` dependency, and future Mac transports
must receive the injected session rather than create their own. Tests inject
`VaultNoEgressNetworkSessionProvider` to make accidental URLSession traffic
fail before a socket opens. Network.framework transports will require an
equivalent injected connection-factory trap before they are added.

Required later gates include offline restart/reindex, ciphertext-only backend
requests, index model
versioning, symbolic-link deduplication, iCloud eviction, Mac reconnect and
conflict handling, and power-aware background work.

Stage 4A adds deterministic backend coverage in `VaultBackendTests`: local
Data-Protection-backed reads and ranges, iCloud unavailable-without-fallback,
opaque UUID paths/ciphertext, confirmed-versus-pending eviction, and exact
durable upload idempotency. `VaultICloudBackend` is tested through an injected
`InMemoryVaultUbiquitousCoordinator`; no iCloud account or ubiquity entitlement
is required for the deterministic suite. A live iCloud run must explicitly
exercise a provisioned entitlement and record both download and eviction
resource values; a successful API call alone is not evidence that local bytes
were evicted.
