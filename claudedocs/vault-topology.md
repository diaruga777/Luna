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

Vault v1 is Mac-backed: the user-owned Mac is the canonical folder and the
iPhone keeps its mirrored index, bounded cache, thumbnails, and search data
locally. The generic backend transport is intentionally present as a boundary,
but there are no AWS, S3-compatible, Backblaze, Google, Azure, or Cloudflare
adapters in v1. The iOS UI exposes only on-device working data and the paired
Mac; records written by the retired iCloud policy migrate to on-device storage
on the next launch.

The Mac path EMBEDS Tailscale: the Vault host and the Mac companion each run
an in-process tsnet node from the `LunaVaultTailscale` package (vendored
TailscaleKit over a committed libtailscale xcframework), authorized once per
device through the SDK's interactive web-auth flow. Neither device needs the
Tailscale app. Same-LAN discovery remains a fallback that bypasses the
embedded node. Tailscale is transport/discovery only: Vault still pairs the
device and authenticates an app-level encrypted protocol. Only the Vault host
and the test bundle link the package — the other four apps, every extension,
and LunaLibraries stay free of the binary. There is still no Luna
relay/server. See `claudedocs/vault-mac.md`.

The Vault target intentionally has an isolated source group and a minimal
search-first UIKit root. It does not inherit the article, media, price,
CloudKit, or unrelated extension capabilities from the existing hosts. The
dedicated `LunaVaultShare` extension is an installable, keyless handoff
surface: only the App Group entitlement is present, while the host alone owns
Keychain and sync. The host registers a BGProcessingTask and replays durable
sync jobs after foreground/provider wakes.

`LunaVault.xcscheme` builds the host and its Share extension. The aggregate
`AllLunaApps` scheme includes the host for topology/build checks. Vault remains
outside `onboardingRankedSiblings`, the legacy shared stage catalogs, and
`scripts/stage_screenshots.py` until central integration and real Vault stage
fixtures exist. `LunaVaultUI` owns a search-first surface with on-device and
paired-Mac storage choices. The host loads a typed first-run coordinator: an
empty setup state is the only path that calls `createFirstRun()`, while later
launches use `loadRequired()`. The root presents bounded recent files,
canonical-deduplicated search results, groups, and an import callback; it does
not implement extraction or rendering. Settings expose
storage/cache/index/security/Mac controls. `VaultTestKit` supplies deterministic
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
