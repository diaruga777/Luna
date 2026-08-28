# Luna Vault Mac companion (v1)

The Mac storage option is a companion process owned and installed by the user.
Luna does not provide a hosted relay, a cloud bucket, or a Tailscale SDK. The
user may install Tailscale separately on both devices and enter a Tailscale IP
or MagicDNS name in Vault. If Tailscale can form a direct peer connection it
will carry the TCP stream directly; if it uses DERP, the same encrypted stream
works through that transport. Vault does not promise that a path is direct or
that Tailscale is always running. When the devices are on the same network,
Bonjour discovery is an opportunistic fallback; the user can also enter a LAN
endpoint manually.

## Protocol boundary

`LunaVaultBackend` owns the platform-neutral wire contract:

* `VaultMacPairingChallenge` and `VaultMacPairingResponse` bind a one-time
  nonce, a session UUID, and a server certificate/public binding to a paired
  32-byte application secret. An endpoint address is never part of identity.
* `VaultMacAuthenticatedFrame` authenticates every request and response with
  HMAC-SHA256 over a protocol label, session UUID, sequence number, and payload.
  `VaultMacReplayGuard` accepts each sequence once and in order. A malformed,
  unauthenticated, or replayed frame terminates the connection before storage
  dispatch.
* Requests contain only opaque UUID object IDs, revision clocks, byte ranges,
  idempotency keys, and `ciphertext`. They contain no filename, content type,
  plaintext metadata, root key, or search text. The ciphertext is produced by
  `LunaVaultCrypto` on the iPhone; the Mac does not decrypt it.
* `VaultMacChunkPlan` and the `putChunk` operation support bounded resumable
  uploads. Repeating an idempotency key is safe; a different body for an
  already-written chunk is a conflict. `readRange` supports bounded ciphertext
  range reads for the iPhone's authenticated decrypt/range pipeline.
* Revisions use Vault's logical time, device ID, and revision UUID total order.
  An update to an existing object must name the current revision, preventing a
  stale phone or duplicate request from overwriting newer data. Deletes are
  tombstoned in the encrypted Mac manifest.

`LunaVaultMac` provides `VaultMacCompanionStore`, an actor-backed store that
keeps object bytes in opaque UUID/revision directories. The manifest is
AES-GCM encrypted with the paired application secret, and files are created
with owner-only permissions on Darwin. The Mac stores the paired application
credential, not the iPhone's synchronizable Vault root key. Losing/revoking a
pair therefore requires a new explicit pairing; root-key recovery remains an
iPhone Keychain/iCloud concern.

`LunaVaultMacCompanion` is a small headless executable foundation for local
development and future macOS UI/launch-agent wiring. It accepts a root path,
paired-secret base64, session UUID, and port, then serves authenticated frames
over Network.framework TCP. Pairing UI, Bonjour publication, sleep/wake policy,
and launch-at-login are intentionally shell responsibilities, not hidden in
the storage actor.

## Threat model and limits

The protocol assumes the IP path, LAN, Tailscale control plane, and any DERP
relay can observe timing, size, and availability but must not learn Vault
content. Client-side encryption protects object bytes, filenames, metadata,
and index artifacts before transport. An attacker who steals the paired Mac
credential or an unlocked Mac can impersonate that pairing; revocation and
re-pairing must be surfaced in the eventual settings UI. A stolen iPhone with
the unlocked synchronizable Keychain item can decrypt the vault, as intended by
the user's iCloud recovery choice.

The current Network.framework listener is a direct authenticated TCP transport
and does not silently claim TLS certificate validation. The pairing transcript's
server binding plus per-frame MAC is the equivalent application-channel binding
for this v1 foundation; production UI should display and confirm the binding
fingerprint during pairing and rotate/revoke secrets. A later release may add
TLS with certificate pinning without changing the request/storage contract.

Neither iOS nor macOS guarantees unlimited background execution. Sync is
opportunistic: foreground transfers, background processing when granted, and
retryable durable jobs are expected. Tailscale being asleep, offline, or
relayed is a normal unavailable state, not a data-loss condition.
