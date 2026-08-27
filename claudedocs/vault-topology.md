# Luna Vault topology (Stage 1A)

Luna Vault is a fifth, standalone iOS host in the Luna family. Its bundle
identifier is `com.hsanabria.luna.vault` (derived from `PRODUCT_BUNDLE_PREFIX`)
and its deep-link scheme is `lunavault`.

The host uses the established shared App Group for handoff and configuration,
but has its own Keychain access group and its own `vault.sqlite` database name.
The central Luna host is not integrated with Vault in this stage, and the
existing URL/content-kind apps retain their current handling and extensions.

The Vault target intentionally has an isolated source group and a minimal
search-first UIKit root. It does not inherit the article, media, price,
CloudKit, or unrelated extension capabilities from the existing hosts. A
dedicated `LunaVaultShare` extension is included as a compile-safe handoff
placeholder; provider access, encryption, indexing, and sync are follow-up
layers.

`LunaVault.xcscheme` builds the host and its Share extension. The aggregate
`AllLunaApps` scheme includes the host for topology/build checks. The stage
does not claim Vault stage fixtures or feature UI readiness.
