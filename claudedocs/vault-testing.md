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
`--live-provider mac`. Mac live tests assume the separately installed
Tailscale client and use it only for reachability; they still exercise Vault's
app-level pairing/authenticated encrypted protocol. No test may contact a
cloud provider or a Luna service implicitly.

Until live iCloud/Mac suites land, both live flags fail with `NOT IMPLEMENTED`
and exit 3. They never run the deterministic suite and report that as a live
success. The plain `--provider icloud|mac` form also refuses to proceed until
the caller supplies explicit live consent.

Run the focused emulator suite with:

```sh
scripts/run_vault_tests.sh --emulator
```

Use `--device <UDID>` for a physical-device destination. `--unit` compiles the
Foundation-only `VaultTestKit` package target (the package also contains
UIKit-only legacy targets, so a plain `swift build` on macOS is not expected to
pass). `LunaVault.xctestplan` is registered by the shared `LunaVaultTests`
scheme. The runner selects both `VaultScaffoldTests` and
`VaultCryptoStorageTests` to cover deterministic encryption ranges/tampering,
strict key-ring recovery, migrations/reopen/integrity, tombstones, cache expiry,
job leases, encrypted artifacts, and legacy-store isolation.

`Fixtures/Vault/manifest.json` intentionally lives at the repository root: it
is test input, not an app resource. `VaultScaffoldTests` decodes it from the
source-file-relative repository path, and `select_changed_tests.py` maps that
exact path to the focused suite.

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
