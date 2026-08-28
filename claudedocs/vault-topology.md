# Luna Vault topology (Stage 1B)

Luna Vault is a fifth, standalone iOS host in the Luna family. Its bundle
identifier is `com.hsanabria.luna.vault` (derived from `PRODUCT_BUNDLE_PREFIX`)
and its deep-link scheme is `lunavault`.

The host uses the established shared App Group for handoff and configuration,
but has its own Keychain access group and its own `vault.sqlite` database name.
The Share extension is intentionally keyless: it has only the shared App Group
entitlement and cannot open Vault's Keychain group or database directly.
The central Luna host is not integrated with Vault in this stage, and the
existing URL/content-kind apps retain their current handling and extensions.

Vault v1 has exactly three storage locations: on-device, iCloud, and a
user-owned Mac. The generic backend transport is intentionally present as a
boundary, but there are no AWS, S3-compatible, Backblaze, Google, Azure, or
Cloudflare adapters in v1. iCloud may keep a local working copy or evict it to
free device space; this is one iCloud policy, not another backend.

The Mac path uses the user's separately installed Tailscale client for
MagicDNS/Tailscale-IP reachability from anywhere, with same-LAN discovery as a
fallback. Tailscale is transport/discovery only: Vault still pairs the device
and authenticates an app-level encrypted protocol. No Tailscale SDK or Luna
relay/server is embedded in the app.

The Vault target intentionally has an isolated source group and a minimal
search-first UIKit root. It does not inherit the article, media, price,
CloudKit, or unrelated extension capabilities from the existing hosts. A
dedicated `LunaVaultShare` extension is included as a compile-safe handoff
placeholder; provider access, encryption, indexing, and sync are follow-up
layers.

`LunaVault.xcscheme` builds the host and its Share extension. The aggregate
`AllLunaApps` scheme includes the host for topology/build checks. Vault remains
outside `onboardingRankedSiblings`, the legacy shared stage catalogs, and
`scripts/stage_screenshots.py` until central integration and real Vault stage
fixtures exist; Stage 1B does not claim feature UI readiness. `LunaVaultUI`
owns only a search-first placeholder, and `VaultTestKit` supplies deterministic
clock/UUID/randomness, in-memory stores, fake extraction/transcription/
embeddings, a no-egress URL protocol, temporary directories, and redacting
logging for later stages.
