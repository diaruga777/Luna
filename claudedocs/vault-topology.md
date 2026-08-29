# Luna Vault topology (Stage 5 UI)

Luna Vault is a fifth, standalone iOS host in the Luna family. Its bundle
identifier is `com.hsanabria.luna.vault` (derived from `PRODUCT_BUNDLE_PREFIX`)
and its deep-link scheme is `lunavault`.

The host uses the established shared App Group for handoff and configuration,
but has its own Keychain access group and its own `vault.sqlite` database name.
The Share extension is intentionally keyless: it has only the shared App Group
entitlement and cannot open Vault's Keychain group or database directly.
The central Luna host is not integrated with Vault, and the existing
URL/content-kind apps retain their current handling and extensions.

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
CloudKit, or unrelated extension capabilities from the existing hosts. The
dedicated `LunaVaultShare` extension is an installable, keyless handoff
surface: only the App Group entitlement is present, while the host alone owns
iCloud, Keychain, crypto, and sync. The host registers a BGProcessingTask and
replays durable sync jobs after foreground/provider wakes.

`LunaVault.xcscheme` builds the host and its Share extension. The aggregate
`AllLunaApps` scheme includes the host for topology/build checks. Vault remains
outside `onboardingRankedSiblings`, the legacy shared stage catalogs, and
`scripts/stage_screenshots.py` until central integration and real Vault stage
fixtures exist. `LunaVaultUI` owns a search-first surface with honest
device/iCloud readiness status; unavailable iCloud never silently falls back
to local storage. The host loads a typed first-run coordinator: an empty setup
state is the only path that calls `createFirstRun()`, while later launches use
`loadRequired()`. The root presents bounded recent files, canonical-deduplicated
search results, groups, and an import callback; it does not implement extraction
or rendering. Settings expose storage/cache/index/security/Mac controls,
including explicit iCloud local-eviction states. `VaultTestKit` supplies deterministic
clock/UUID/randomness, in-memory stores, fake extraction/transcription/
embeddings, a no-egress URL protocol, temporary directories, and redacting
logging for later stages.

The Stage 5 root forwards import and canonical-object-open callbacks to the
Vault host; it does not construct media previews or renderers. Setup and
recovery panels remain actionable when the provider or index is unavailable,
and every retry reports the failure without silently changing storage policy.
Settings callbacks are host-owned: policy changes and Mac credential changes
rebuild the runtime/sync controller, while unpairing drops the local runtime
and reports remote revocation as local-only when the paired companion cannot
be reached. Runtime caching compares the full identity (policy, backend
identity, credential epoch/fingerprint, and an explicit lifecycle generation),
so pairing or unpairing a Mac is observed immediately even when the selected
storage policy remains `mac`; the root swaps the runtime or renders an honest
unavailable state without requiring relaunch.
